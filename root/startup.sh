#!/bin/bash
set -eu

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

ROOT=/opt/unbound

[ ! -f $ROOT/etc/unbound/unbound.conf ] && \
    cp $ROOT/etc/unbound/unbound.{example,conf}

sed -i"" \
    -e "s/@QUERIES_PER_THREAD@/${QUERIES_PER_THREAD}/" \
    -e "s/@OUTGOING_RANGE@/${OUTGOING_RANGE}/" \
    -e "s/@MSG_CACHE_SIZE@/${MSG_CACHE_SIZE}/" \
    -e "s/@RR_CACHE_SIZE@/${RR_CACHE_SIZE}/" \
    -e "s/@THREADS@/${THREADS}/" \
    -e "s/@SLABS@/${SLABS}/" \
    $ROOT/etc/unbound/unbound.conf

mkdir -p                                $ROOT/etc/unbound/dev
cp -a /dev/{null,stdout,random,urandom} $ROOT/etc/unbound/dev/

mkdir -p -m 700         $ROOT/etc/unbound/var
chown _unbound:_unbound $ROOT/etc/unbound/var

rm -f $ROOT/etc/unbound/unbound.pid

if [[ -z ${VERBOSE+x} || "$VERBOSE" -le 0 ]]; then
    VERBOSE=""
else
    # VERBOSE=3 becomes VERBOSE="-v -v -v"
    VERBOSE=$(printf -- "-v %.0s" $(seq 1 $VERBOSE))
fi

$ROOT/sbin/unbound-anchor -a $ROOT/etc/unbound/root.key
exec $ROOT/sbin/unbound -c $ROOT/etc/unbound/unbound.conf -d $VERBOSE
