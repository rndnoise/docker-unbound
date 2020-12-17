#!/bin/bash
set -eu

# Restart with unbuffered stdout
if [ -z ${1+x} ] || [ "$1" != "stdbuf" ]; then
    exec $0 stdbuf "@$"
fi

ROOT=/opt/unbound
CONF="$ROOT/etc/unbound/unbound.conf"

# Remove quotes and leading spaces from given string
function unquote {
    str="$1"
    str="${str%\"}"
    str="${str# }"
    str="${str#\"}"
    echo $str
}

function readconf {
    key="$1"
    val=$(cat "$CONF" | grep "^ *$key:" | cut -d: -f2)
    val=$(unquote "$val")
    echo $val
}

# reown <user|group> [NAME] [NEW ID]
function reown {
    local kind="$1"
    local name="$2"
    local new="$3"
    local old
    local cmd
    local mod

    case "$kind" in
        user)
            old=$(getent passwd "$name" | cut -d: -f3)
            cmd="chown"
            mod="usermod -o -u"
            ;;
        group)
            old=$(getent group "$name" | cut -d: -f3)
            cmd="chgrp"
            mod="groupmod -o -g"
            ;;
        *)
            echo "bad argument" >/dev/stderr
            exit 1
            ;;
    esac

    echo "changing id of $kind $name from $old to $new"
    $mod $new $name

    for path in $(find / "-$kind" "$old" 2>/dev/null); do
        echo "fixing ownership of $path"
        $cmd "$name" "$path"
    done
}

function calculate {
    # in kilobytes
    local RESERVED_MEM=$(( 12 * 1024 )) # 12 MB
    local AVAILABLE_MEM=$((grep MemAvailable /proc/meminfo || grep MemTotal /proc/meminfo) | sed 's/[^0-9]//g')

    if [ $AVAILABLE_MEM -le $((2 * $RESERVED_MEM)) ]; then
        echo "Not enough memory" >&2
        exit 1
    fi

    # in bytes
    AVAILABLE_MEM=$((1024 * ($AVAILABLE_MEM - $RESERVED_MEM)))

    # rrset-cache should be roughly twice msg-cache
    RR_CACHE_SIZE=$(($AVAILABLE_MEM / 3))
    MSG_CACHE_SIZE=$(($RR_CACHE_SIZE / 2))

    NPROC=$(nproc)

    # When compiled with libevent, outgoing-range: 8192 and num_queries_per_thread:
    # 4096 are recommended values. Otherwise, these values should be used:
    OUTGOING_RANGE=$((1024/NPROC - 50))
    QUERIES_PER_THREAD=$((OUTGOING_RANGE / 2))

    if [ "$NPROC" -gt 1 ]; then
        export NPROC
        local LG_NPROC=$(perl -e 'printf "%d\n", int(log($ENV{NPROC})/log(2.0));')

        # Power of 2 that's close to nproc
        SLABS=$(( 2 ** LG_NPROC))
        THREADS=$(($NPROC - 1))
    else
        SLABS=4
        THREADS=1
    fi
}

if [[ -z ${VERBOSE+x} || "$VERBOSE" -le 0 ]]; then
    VERBOSE=""
else
    # VERBOSE=3 becomes VERBOSE="-v -v -v"
    VERBOSE=$(printf -- "-v %.0s" $(seq 1 $VERBOSE))
fi


if [ ! -f "$CONF" ]; then
    # No config file exists yet. This is the "public" location where users can
    # interact on the host with the container via a Docker volume
    cp "$ROOT/etc/unbound.example/*." "$(dirname "$CONF")"
fi

sed -i"" \
    -e "s/@QUERIES_PER_THREAD@/${QUERIES_PER_THREAD}/" \
    -e "s/@OUTGOING_RANGE@/${OUTGOING_RANGE}/" \
    -e "s/@MSG_CACHE_SIZE@/${MSG_CACHE_SIZE}/" \
    -e "s/@RR_CACHE_SIZE@/${RR_CACHE_SIZE}/" \
    -e "s/@THREADS@/${THREADS}/" \
    -e "s/@SLABS@/${SLABS}/" \
    "$ROOT/etc/unbound/unbound.conf"

CHROOT=$(readconf "chroot")
ANCHOR=$(readconf "auto-trust-anchor-file")
LOGFILE=$(readconf "logfile")

# These are assumed to be relative to chroot
ANCHOR="$CHROOT/$ANCHOR"
LOGFILE="$CHROOT/$LOGFILE"

# Ensure anchor file is no older than 24 hours
if [ ! -f "$ANCHOR" ] || find "$ANCHOR" -mmin +1440 &>/dev/null; then
    echo "updating anchor: $ANCHOR"
    mkdir -p -m 755 $(dirname "$ANCHOR")
    chown _unbound:_unbound $(dirname "$ANCHOR")
    "$ROOT/sbin/unbound-anchor" -a "$ANCHOR"
fi

echo "log file: $LOGFILE"
echo "anchor file: $ANCHOR"

# Now copy all the configuration files from the "public" host-writable directory
# to the "private" chroot location. This needs to be a separate location because
# when the host OS is not Linux, we cannot create devices like null, random, and
# urandom on the shared volume.
echo "using chroot: $CHROOT"
rm -rf "$CHROOT/dev" "$CHROOT/etc/unbound"
mkdir -p -m 755 "$CHROOT/dev" "$CHROOT/etc/unbound"
mkdir -p -m 755 "$(dirname "$LOGFILE")"
touch "$LOGFILE"
cp -a /dev/{null,random,urandom}   "$CHROOT/dev"
cp -r "$ROOT/etc/unbound/"*        "$CHROOT/etc/unbound"
cp    "$ROOT/etc/unbound/root.key" "$CHROOT/$ANCHOR"
chown -R _unbound:_unbound "$CHROOT" "$LOGFILE"

[[ -n "${UNBOUND_UID+x}" ]] && reown user  _unbound "$UNBOUND_UID"
[[ -n "${UNBOUND_GID+x}" ]] && reown group _unbound "$UNBOUND_GID"

echo "starting unbound"
exec "$ROOT"/sbin/unbound -c "$CONF" -d $VERBOSE
