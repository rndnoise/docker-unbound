#!/bin/sh -eux

case $TARGETPLATFORM in
  linux/arm/v*)
    # We can't use -mfpu=vfp -mfloat-abi=hard
    export CFLAGS="-march=armv6zk -mcpu=arm1176jzf-s"
    ;;
  *)
    ;;
esac

exec "$@"
