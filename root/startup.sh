#!/bin/bash
set -eu

# in kilobytes
reservedMemory=$(( 12 * 1024 )) # 12 MB
availableMemory=$((grep MemAvailable /proc/meminfo || grep MemTotal /proc/meminfo) | sed 's/[^0-9]//g')

if [ $availableMemory -le $((2 * $reservedMemory)) ]; then
    echo "Not enough memory" >&2
    exit 1
fi

# in bytes
availableMemory=$((1024 * ($availableMemory - $reservedMemory)))

rr_cache_size=$(($availableMemory / 3))
msg_cache_size=$(($rr_cache_size / 2))

nproc=$(nproc)

if [ "$nproc" -gt 1 ]; then
    export nproc
    lg_nproc=$(perl -e 'printf "%d\n", int(log($ENV{nproc})/log(2.0));')
    slabs=$(( 2 ** lg_nproc))
    threads=$(($nproc - 1))
else
    slabs=4
    threads=1
fi

[ ! -f /opt/unbound/etc/unbound/unbound.conf ] && \
    cp /opt/unbound/etc/unbound/unbound.{example,conf}

sed -i.xyz \
    -e "s/@MSG_CACHE_SIZE@/${msg_cache_size}/" \
    -e "s/@RR_CACHE_SIZE@/${rr_cache_size}/" \
    -e "s/@THREADS@/${threads}/" \
    -e "s/@SLABS@/${slabs}/" \
    /opt/unbound/etc/unbound/unbound.conf

mkdir -p                         /opt/unbound/etc/unbound/dev
cp -a /dev/{null,random,urandom} /opt/unbound/etc/unbound/dev/

mkdir -p -m 700         /opt/unbound/etc/unbound/var
chown _unbound:_unbound /opt/unbound/etc/unbound/var

/opt/unbound/sbin/unbound-anchor -a /opt/unbound/etc/unbound/var/root.key

exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf
