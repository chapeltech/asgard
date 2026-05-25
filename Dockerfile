FROM debian:trixie-slim AS packages

# Install build dependencies
RUN apt update -qq && \
    apt install -y --no-install-recommends	\
        build-essential				\
	debhelper				\
	dpkg-dev				\
        autoconf				\
        automake				\
        libtool					\
        pkg-config				\
        flex					\
        bison					\
	libedit-dev				\
	libmicrohttpd-dev			\
        libssl-dev				\
        libsqlite3-dev				\
        libncurses-dev				\
        libdb-dev				\
	netbase					\
	python3					\
	perl libjson-perl			\
        curl					\
        ca-certificates				\
	rustup					\
        git					\
        wget					\
        gnupg					\
        lsb-release				\
	unzip

RUN    git clone https://github.com/chapeltech/heimdal	\
    && cd heimdal					\
    && git checkout deb-pkg

COPY heimdal /heimdal

RUN    cd /heimdal && dpkg-buildpackage

RUN dpkg -i heimdal_7.99.1_amd64.deb

RUN    /usr/bin/rustup toolchain install 1.86.0 --profile minimal

RUN    git clone https://github.com/elric1/prefork	\
    && cd prefork					\
    && dpkg-buildpackage

RUN    git clone https://github.com/elric1/lnetd	\
    && cd lnetd						\
    && dpkg-buildpackage

RUN    git clone https://github.com/elric1/knc		\
    && cd knc						\
    && git checkout experiment				\
    && dpkg-buildpackage

RUN    git clone https://github.com/elric1/kharon	\
    && cd kharon					\
    && dpkg-buildpackage

RUN dpkg -i libkharon*.deb

RUN    apt-get update -qq				\
    && apt-get install -y --no-install-recommends	\
	swig sqlite3 libdbi-perl libdbd-sqlite3-perl

RUN dpkg -i knc*deb

RUN apt -y --no-install-recommends install mksh

RUN    git clone https://github.com/elric1/krb5_admin	\
    && echo krb5_admin 3666/tcp >> /etc/services	\
    && cd krb5_admin					\
    && git checkout experiment				\
    && dpkg-buildpackage

RUN dpkg -i libkrb5ad*.deb

RUN    git clone https://github.com/elric1/krb5_keytab	\
    && cd krb5_keytab					\
    && dpkg-buildpackage

COPY --from=bifrost . /bifrost

RUN    cd /bifrost					\
    && /usr/bin/rustup run 1.86.0 cargo build --release

RUN    mkdir pkgs					\
    && mv *.deb pkgs

ENTRYPOINT ["/bin/ksh"]

FROM debian:trixie-slim AS kdc

COPY --from=packages /pkgs /pkgs
COPY --from=packages /bifrost/target/release/bifrost /usr/bin/bifrost

RUN apt update -qq					\
    && apt install -y --no-install-recommends		\
	coreutils mksh nvi				\
	supervisor tini					\
	openbsd-inetd					\
	inetutils-syslogd				\
    && cd /pkgs						\
    && for i in *.deb; do dpkg -i $i; done		\
    && apt --fix-broken -y install

## XXXrcd: maybe this is a good idea, but we'll have to see about it...
#RUN useradd -m -s /bin/sh kdc

COPY etc /etc
COPY scripts /scripts
COPY scripts/cmd /cmd

RUN    ln -sf /var/heimdal/master /etc/krb5		\
    && ln -sf heimdal /var/kerberos			\
    && echo bifrost 2666/tcp >> /etc/services		\
    && echo krb5_admin 3666/tcp >> /etc/services

ENTRYPOINT ["/cmd"]

FROM debian:trixie-slim AS client

COPY --from=packages /pkgs /pkgs
COPY --from=packages /bifrost/target/release/bifrost /usr/bin/bifrost

RUN apt update -qq					\
    && apt install -y --no-install-recommends		\
	coreutils mksh nvi procps			\
	supervisor tini					\
	openbsd-inetd					\
	inetutils-syslogd				\
	jq						\
	nginx libnginx-mod-http-auth-spnego		\
	curl openssh-server openssh-client		\
    && cd /pkgs						\
    && for i in *.deb; do dpkg -i $i; done		\
    && apt --fix-broken -y install

COPY etc /etc
COPY tests /tests
COPY scripts /scripts
COPY scripts/cmd /cmd

RUN echo bifrost 2666/tcp >> /etc/services
RUN echo krb5_admin 3666/tcp >> /etc/services

ENTRYPOINT ["/cmd"]
