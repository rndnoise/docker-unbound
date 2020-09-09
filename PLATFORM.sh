#!/bin/sh

case "$TARGETPLATFORM" in
  *arm/*)
    echo linux-armv4
    ;;
  *arm64)
    echo linux-aarch64 # linux-arm64ilp32
    ;;
  *amd64)
    echo linux-x86_64
    ;;
  *)
    ;;
esac
