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

    if [ $old -eq $new ]; then
        echo "not changing id of $kind $name, it already matches host"
        return
    fi

    echo "changing id of $kind $name from $old to $new"
    $mod $new $name

    for path in $(find / "-$kind" "$old" 2>/dev/null); do
        echo "fixing ownership of $path"
        $cmd "$name" "$path"
    done
}

function writeconf {
    local RESERVED_MEM AVAILABLE_MEM RR_CACHE_SIZE MSG_CACHE_SIZE NPROC \
          LG_NPROC OUTGOING_RANGE QUERIES_PER_THREAD SLABS THREADS

    # in kilobytes
    RESERVED_MEM=$(( 12 * 1024 )) # 12 MB
    AVAILABLE_MEM=$((grep MemAvailable /proc/meminfo || grep MemTotal /proc/meminfo) | sed 's/[^0-9]//g')

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
        LG_NPROC=$(perl -e 'printf "%d\n", int(log($ENV{NPROC})/log(2.0));')

        # Power of 2 that's close to nproc
        SLABS=$(( 2 ** LG_NPROC))
        THREADS=$(($NPROC - 1))
    else
        SLABS=4
        THREADS=1
    fi

    sed -i"" \
        -e "s/@QUERIES_PER_THREAD@/${QUERIES_PER_THREAD}/" \
        -e "s/@OUTGOING_RANGE@/${OUTGOING_RANGE}/" \
        -e "s/@MSG_CACHE_SIZE@/${MSG_CACHE_SIZE}/" \
        -e "s/@RR_CACHE_SIZE@/${RR_CACHE_SIZE}/" \
        -e "s/@THREADS@/${THREADS}/" \
        -e "s/@SLABS@/${SLABS}/" \
        "$ROOT/etc/unbound/unbound.conf"
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

writeconf

CHROOT=$(readconf "chroot")
ANCHOR=$(readconf "auto-trust-anchor-file")
LOGFILE=$(readconf "logfile")

# These are assumed to be relative to chroot
ANCHOR="$CHROOT/$ANCHOR"
LOGFILE="$CHROOT/$LOGFILE"

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
chown -R _unbound:_unbound "$CHROOT" "$LOGFILE"

# Do we have an anchor file from the host OS volume?
if [ -f "$ROOT/etc/unbound/root.key" ]; then
    # Use whichever is newest between the two
    if [ ! -f "$ANCHOR" ] || [ "$ROOT/etc/unbound/root.key" -nt "$ANCHOR" ]; then
        cp -f "$ROOT/etc/unbound/root.key" "$ANCHOR"
    fi
fi

if [ ! -f "$ANCHOR" ] || [ -n "$(find "$ANCHOR" -mmin +1440)" ]; then
    echo "updating anchor: $ANCHOR"

    # unbound-anchor exits with code 1 if an update was performed, so we must
    # use `|| true` to prevent our script from terminating
    "$ROOT/sbin/unbound-anchor" -v -a "$ROOT/etc/unbound/root.key" -b 0.0.0.0 || true#-r "$ROOT/etc/unbound/root.hints" || true

    mkdir -p -m 755 $(dirname "$ANCHOR")
    cp -f "$ROOT/etc/unbound/root.key" "$ANCHOR"
    chown -R _unbound:_unbound "$(dirname "$ANCHOR")"
fi

[[ -n "${UNBOUND_UID+x}" ]] && reown user  _unbound "$UNBOUND_UID"
[[ -n "${UNBOUND_GID+x}" ]] && reown group _unbound "$UNBOUND_GID"

echo "starting unbound"
exec "$ROOT"/sbin/unbound -c "$CONF" -d -d -p $VERBOSE
