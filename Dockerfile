FROM debian:buster-slim as openssl

ENV OPENSSL_VERSION=openssl-1.1.1g \
    OPENSSL_SHA256=ddb04774f1e32f0c49751e21b67216ac87852ceb056b75209af2443400636d46 \
    OPENSSL_SOURCE=https://www.openssl.org/source/ \
    OPENSSL_OPGP=8657ABB260F056B1E5190839D9C4D26D0E604491

WORKDIR /tmp/src

ENV build_deps="build-essential ca-certificates curl dirmngr gnupg libidn2-0-dev libssl-dev"
RUN set -eux && \
    DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends $build_deps && \
    c_rehash && \
    curl -L "${OPENSSL_SOURCE}${OPENSSL_VERSION}.tar.gz" -o openssl.tar.gz && \
    echo "${OPENSSL_SHA256} ./openssl.tar.gz" | sha256sum -c - && \
    curl -L "${OPENSSL_SOURCE}${OPENSSL_VERSION}".tar.gz.asc -o openssl.tar.gz.asc && \
    GNUPGHOME="$(mktemp -d)" && \
    export GNUPGHOME && \
    ( gpg --no-tty --keyserver ipv4.pool.sks-keyservers.net --recv-keys "$OPENSSL_OPGP" \
      || gpg --no-tty --keyserver ha.pool.sks-keyservers.net --recv-keys "$OPENSSL_OPGP" ) && \
    gpg --batch --verify openssl.tar.gz.asc openssl.tar.gz
    # && \

ENV CFLAGS="-march=armv6zk -mcpu=arm1176jzf-s"
#-mfloat-abi=hard -mfpu=vfp"
RUN tar xzf openssl.tar.gz && \
    cd "${OPENSSL_VERSION}" && \
    ./Configure linux-armv4 && \
    ./config \
      --prefix=/opt/openssl \
      --openssldir=/opt/openssl \
      no-weak-ssl-ciphers \
      no-ssl3 \
      no-shared \
      -DOPENSSL_NO_HEARTBEATS \
      -fstack-protector-strong && \
    make depend && \
    make && \
    make install_sw && \
    apt-get purge -y --auto-remove $build_deps && \
    rm -rf \
        /tmp/* \
        /var/tmp/* \
        /var/lib/apt/lists/*

###############################################################################

FROM debian:buster-slim as unbound

ENV NAME=unbound \
    UNBOUND_VERSION=1.11.0 \
    UNBOUND_SHA256=9f2f0798f76eb8f30feaeda7e442ceed479bc54db0e3ac19c052d68685e51ef7 \
    UNBOUND_SOURCE=https://nlnetlabs.nl/downloads/unbound/unbound-1.11.0.tar.gz

WORKDIR /tmp/src

COPY --from=openssl /opt/openssl /opt/openssl

ENV CFLAGS="-march=armv6zk -mcpu=arm1176jzf-s"
RUN build_deps="curl gcc libc-dev libevent-dev libexpat1-dev make" && \
    set -eux && \
    DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      $build_deps \
      bsdmainutils \
      ca-certificates \
      ldnsutils \
      libevent-2.1-6 \
      libexpat1 && \
    c_rehash && \
    curl -sSL "${UNBOUND_SOURCE}" -o unbound.tar.gz && \
    echo "${UNBOUND_SHA256} *unbound.tar.gz" | sha256sum -c - && \
    tar xzf unbound.tar.gz && \
    rm -f unbound.tar.gz && \
    cd "unbound-${UNBOUND_VERSION}" && \
    groupadd _unbound && \
    useradd -g _unbound -s /etc -d /dev/null _unbound && \
    ./configure \
        --disable-dependency-tracking \
        --prefix=/opt/unbound \
        --with-pthreads \
        --with-username=_unbound \
        --with-ssl=/opt/openssl \
        --with-libevent \
        --enable-tfo-server \
        --enable-tfo-client \
        --enable-event-api && \
    make install && \
    mv /opt/unbound/etc/unbound/unbound.conf /opt/unbound/etc/unbound/unbound.example && \
    apt-get purge -y --auto-remove $build_deps && \
    rm -rf \
        /opt/unbound/share/man \
        /tmp/* \
        /var/tmp/* \
        /var/lib/apt/lists/*

FROM debian:buster-slim

COPY --from=unbound /opt /opt

RUN set -eux && \
    DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      bsdmainutils \
      ca-certificates \
      ldnsutils \
      libevent-2.1-6\
      libexpat1 && \
    c_rehash && \
    groupadd _unbound && \
    useradd -g _unbound -s /etc -d /dev/null _unbound && \
    apt-get purge -y --auto-remove && \
    rm -rf \
        /opt/unbound/share/man \
        /tmp/* \
        /var/tmp/* \
        /var/lib/apt/lists/*

COPY root/opt/unbound/etc/unbound/* /opt/unbound/etc/unbound/
COPY root/startup.sh                /
RUN chmod +x                        /startup.sh

WORKDIR /opt/unbound/
ENV PATH /opt/unbound/sbin:"$PATH"

EXPOSE 53/tcp
EXPOSE 53/udp

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s CMD drill @127.0.0.1 localhost || exit 1

CMD ["/startup.sh"]
