# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM debian:trixie-slim AS bifrost-build

ARG TARGETARCH

RUN apt update -qq					\
    && apt install -y --no-install-recommends		\
	ca-certificates curl dpkg-dev rustup

COPY --chmod=755 build/configure-chapeltech-apt \
	/usr/local/bin/configure-chapeltech-apt

RUN    set -eu;							\
	configure-chapeltech-apt;				\
    build_arch=$(dpkg --print-architecture);			\
    set -- build-essential;					\
    if [ "$TARGETARCH" != "$build_arch" ]; then			\
	dpkg --add-architecture "$TARGETARCH";			\
	set -- "$@" "crossbuild-essential-$TARGETARCH";		\
    fi;								\
    apt-get update -qq;						\
    apt-get install -y --no-install-recommends			\
	"$@"							\
	"asgard-heimdal-devel:$TARGETARCH"			\
	"libsqlite3-dev:$TARGETARCH";				\
    rm -rf /var/lib/apt/lists/*

RUN    /usr/bin/rustup toolchain install 1.86.0 --profile minimal

COPY --from=bifrost . /bifrost

RUN    set -eu;							\
    case "$TARGETARCH" in					\
    amd64)							\
	rust_target=x86_64-unknown-linux-gnu;			\
	gnu_target=x86_64-linux-gnu;				\
	;;								\
    arm64)							\
	rust_target=aarch64-unknown-linux-gnu;			\
	gnu_target=aarch64-linux-gnu;				\
	;;								\
    *)								\
	echo "unsupported target architecture: $TARGETARCH" >&2;	\
	exit 1;							\
	;;								\
    esac;							\
    multiarch=$(dpkg-architecture -a"$TARGETARCH"		\
	-qDEB_HOST_MULTIARCH);					\
    rustup target add --toolchain 1.86.0 "$rust_target";		\
    cc_var=$(printf 'CC_%s' "$rust_target" | tr '-' '_');	\
    linker_var=$(printf 'CARGO_TARGET_%s_LINKER' "$rust_target"	\
	| tr '[:lower:]-' '[:upper:]_');				\
    rustflags_var=$(printf 'CARGO_TARGET_%s_RUSTFLAGS' "$rust_target"\
	| tr '[:lower:]-' '[:upper:]_');				\
    export "$cc_var=$gnu_target-gcc";				\
    export "$linker_var=$gnu_target-gcc";			\
    cd /bifrost;						\
    private_libdir="/usr/lib/$multiarch/asgard/lib";		\
    export "$rustflags_var=-C link-arg=-Wl,-rpath,$private_libdir";\
    HEIMDAL_INCLUDE_DIR=/usr/include/asgard/heimdal		\
    HEIMDAL_LIB_DIR="$private_libdir"				\
    SQLITE3_LIB="/usr/lib/$multiarch/libsqlite3.so.0"		\
	rustup run 1.86.0 cargo build				\
	    --release --target "$rust_target";			\
    install -D -m 755						\
	"target/$rust_target/release/bifrost"			\
	/bifrost/target/release/bifrost

FROM bifrost-build AS krb5-admin-test-packages

ARG TARGETARCH

COPY --chmod=755 build/build-deb /usr/local/bin/asgard-build-deb

RUN    apt-get update -qq					\
    && apt-get install -y --no-install-recommends		\
	debhelper dh-autoreconf					\
	perl swig sqlite3 libdbi-perl libdbd-sqlite3-perl	\
	"libperl-dev:$TARGETARCH" "perl-xs-dev:$TARGETARCH"	\
    && mkdir /repo-packages					\
    && cd /repo-packages					\
    && apt-get download "libkharon-perl:$TARGETARCH"		\
    && dpkg --unpack libkharon-perl_*.deb			\
    && rm -rf /var/lib/apt/lists/*

COPY --from=krb5_admin . /krb5_admin

RUN    cd /krb5_admin						\
    && ASGARD_BUILD_ARCH_ALL=yes asgard-build-deb "$TARGETARCH"

RUN    mkdir /test-pkgs-common /test-pkgs-kdc		\
	/test-pkgs-client					\
    && cp /libkrb5admin-perl_*.deb /test-pkgs-common/	\
    && cp /libkrb5admin-perl-kdc_*.deb			\
	/krb5-prestash_*.deb /test-pkgs-kdc/			\
    && cp /krb5-hostd_*.deb /krb5-prestash_*.deb		\
	/krb5-prestash-refresh_*.deb /test-pkgs-client/

FROM debian:trixie-slim AS kdc

ENV BIFROST_IPROP_ACL=/run/asgard/iprop-acl
ENV PATH=/usr/lib/asgard/bin:/usr/lib/asgard/sbin:/usr/lib/asgard/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=bifrost-build /bifrost/target/release/bifrost /usr/bin/bifrost
COPY --chmod=755 build/configure-chapeltech-apt \
	/usr/local/bin/configure-chapeltech-apt

RUN apt update -qq					\
    && apt install -y --no-install-recommends		\
	ca-certificates curl				\
    && configure-chapeltech-apt				\
    && apt update -qq					\
    && apt install -y --no-install-recommends		\
	coreutils cron mksh nvi				\
	supervisor tini					\
	openbsd-inetd					\
	inetutils-syslogd				\
	nsd dnsutils					\
	jq sqlite3 rsync				\
	knc lnetd prefork libkharon-perl krb5keytab	\
	asgard-heimdal-clients asgard-heimdal-kdc	\
	libkrb5admin-perl libkrb5admin-perl-kdc		\
	krb5-prestash						\
    && rm -rf /var/lib/apt/lists/*

## XXXrcd: maybe this is a good idea, but we'll have to see about it...
#RUN useradd -m -s /bin/sh kdc

COPY etc /etc
COPY scripts /scripts
COPY scripts/cmd /cmd

RUN    ln -sf /var/heimdal/master /etc/krb5		\
    && ln -sf ../../var/heimdal/ca-pub.pem /etc/krb5/ca-pub.pem \
    && ln -sf heimdal /var/kerberos			\
    && mkdir -p /etc/bifrost				\
    && ln -sf /var/heimdal/bifrost-priv.pem		\
	/var/heimdal/ca-pub.pem /etc/bifrost/		\
    && echo bifrost 3666/tcp >> /etc/services

RUN    chmod 700 /scripts/asgard-rsync			\
    && echo krb5_admin_sync 4666/tcp >> /etc/services

ENTRYPOINT ["/cmd"]

FROM kdc AS asgard

FROM kdc AS kdc-test

COPY --from=krb5-admin-test-packages /test-pkgs-common /test-pkgs
COPY --from=krb5-admin-test-packages /test-pkgs-kdc /test-pkgs
COPY tests /tests

RUN    dpkg -i /test-pkgs/*.deb				\
    && rm -rf /test-pkgs

FROM debian:trixie-slim AS client

ENV PATH=/usr/lib/asgard/bin:/usr/lib/asgard/sbin:/usr/lib/asgard/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=krb5-admin-test-packages /test-pkgs-common /test-pkgs
COPY --from=krb5-admin-test-packages /test-pkgs-client /test-pkgs
COPY --from=bifrost-build /bifrost/target/release/bifrost /usr/bin/bifrost
COPY --chmod=755 build/configure-chapeltech-apt \
	/usr/local/bin/configure-chapeltech-apt

RUN apt update -qq					\
    && apt install -y --no-install-recommends		\
	ca-certificates curl				\
    && configure-chapeltech-apt				\
    && apt update -qq					\
    && apt install -y --no-install-recommends		\
	coreutils mksh nvi procps			\
	supervisor tini					\
	openbsd-inetd					\
	inetutils-syslogd				\
	jq						\
	dnsutils					\
	nginx libnginx-mod-http-auth-spnego		\
	openssh-server openssh-client			\
	knc lnetd prefork libkharon-perl krb5keytab	\
	asgard-heimdal-clients				\
	/test-pkgs/*.deb					\
    && rm -rf /test-pkgs /var/lib/apt/lists/*

COPY etc /etc
COPY tests /tests
COPY scripts /scripts
COPY scripts/cmd /cmd

RUN echo bifrost 3666/tcp >> /etc/services

ENTRYPOINT ["/cmd"]
