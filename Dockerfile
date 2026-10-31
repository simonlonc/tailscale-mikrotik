# syntax=docker/dockerfile:1
# Copyright (c) 2020 Fluent Networks Inc & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

############################################################################
#
# WARNING: Tailscale is not yet officially supported in Docker,
# Kubernetes, etc.
#
# It might work, but we don't regularly test it, and it's not as polished as
# our currently supported platforms. This is provided for people who know
# how Tailscale works and what they're doing.
#
# Our tracking bug for officially support container use cases is:
#    https://github.com/tailscale/tailscale/issues/504
#
# Also, see the various bugs tagged "containers":
#    https://github.com/tailscale/tailscale/labels/containers
#
############################################################################
#
# Minimal image (~4.4 MB) for routers with little flash, e.g. hAP ax2.
# Platforms: linux/arm64, linux/arm/v7, linux/arm/v5, linux/amd64
#  - tailscale and tailscaled are ONE binary (tailscale is a symlink), built
#    with every feature a subnet router / exit node doesn't need compiled out
#    (see TS_FEATURES), then packed with UPX (LZMA)
#  - no Alpine, bash, openssh, curl, jq or iproute2: FROM scratch with a small
#    static busybox (sh, ip, sysctl, vi, ping, ...) and a static iptables-legacy
#  - CA roots are embedded in the binary instead of shipping /etc/ssl
#
############################################################################

ARG GO_VERSION=1.27
ARG ALPINE_VERSION=3.22
ARG UBUNTU_VERSION=24.04

# --- 1. tailscale: cross-compiled natively on the build machine -------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS tailscale
RUN apk add --no-cache git upx
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto

ARG TAILSCALE_VERSION=1.104.2
RUN git -c advice.detachedHead=false clone --depth 1 \
      --branch v${TAILSCALE_VERSION} https://github.com/tailscale/tailscale.git /src
WORKDIR /src

# Features to keep; everything else is compiled out.
# List all features with: go run ./cmd/featuretags --list
#   cli               - tailscale CLI inside the tailscaled binary
#   osrouter,iptables - kernel TUN + routes + iptables (RouterOS has no nftables)
#   nattraversal      - direct UDP connections (otherwise everything uses DERP)
#   advertiseroutes, advertiseexitnode, useroutes (--accept-routes)
#   ipnbus            - needed by "tailscale up"
#   oauthkey          - AUTH_KEY may be an OAuth client secret
#   dns, bakedroots
ARG TS_FEATURES=cli,osrouter,iptables,nattraversal,advertiseroutes,advertiseexitnode,useroutes,ipnbus,oauthkey,dns,bakedroots
# Extra features on top of the list above, e.g. "ssh,useexitnode,portmapper".
ARG TS_EXTRA_FEATURES=
# "true" builds with every Tailscale feature instead (the "full" image).
ARG TS_ALL_FEATURES=false

# Embed Mozilla CA roots, used only when the image has no CA bundle (it has none).
RUN printf 'package main\n\nimport _ "golang.org/x/crypto/x509roots/fallback"\n' \
      > cmd/tailscaled/fallbackroots.go

ARG TARGETARCH
ARG TARGETVARIANT
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -e; \
    eval "$(go run ./cmd/mkversion)"; \
    KNOWN="$(go run ./cmd/featuretags --list)"; \
    if [ "$TS_ALL_FEATURES" = true ]; then \
      FEATURES="$(echo "$KNOWN" | sed -n 's/^ *\([a-z0-9_]*\): .*/\1/p' | tr '\n' ',' | sed 's/,$//')"; \
    else \
      FEATURES="${TS_FEATURES}${TS_EXTRA_FEATURES:+,$TS_EXTRA_FEATURES}"; \
    fi; \
    echo "Tailscale features: $FEATURES"; \
    for f in $(echo "$FEATURES" | tr , ' '); do \
      echo "$KNOWN" | grep -q "^ *$f: " || { echo "Unknown Tailscale feature: $f" >&2; exit 1; }; \
    done; \
    TAGS="$(go run ./cmd/featuretags --min --add=$FEATURES)"; \
    if [ "$TARGETARCH" = arm ]; then export GOARM="${TARGETVARIANT#v}"; fi; \
    GOOS=linux GOARCH=$TARGETARCH go build -trimpath -tags="$TAGS" \
      -ldflags="-s -w -buildid= \
        -X tailscale.com/version.longStamp=$VERSION_LONG \
        -X tailscale.com/version.shortStamp=$VERSION_SHORT" \
      -o /out/tailscaled ./cmd/tailscaled; \
    upx --lzma --best /out/tailscaled

# --- 2. static busybox + iptables-legacy, cross-compiled with musl ---------
# Cross-compiling (instead of building on an emulated target) is faster and
# also covers ARMv5, for which there is no Alpine image.
FROM --platform=$BUILDPLATFORM ubuntu:${UBUNTU_VERSION} AS tools
ARG TARGETARCH
ARG TARGETVARIANT
RUN set -e; \
    case "$TARGETARCH$TARGETVARIANT" in \
      amd64*) T=x86_64-linux-gnu;    D=amd64; F="" ;; \
      arm64*) T=aarch64-linux-gnu;   D=arm64; F="" ;; \
      armv7)  T=arm-linux-gnueabihf; D=armhf; F="" ;; \
      armv5)  T=arm-linux-gnueabi;   D=armel; F="-march=armv5t -marm -mfloat-abi=soft" ;; \
      *) echo "Unsupported platform: $TARGETARCH/$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    printf 'T=%s\nF="%s"\n' "$T" "$F" > /target.env; \
    apt-get update -q; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      gcc libc6-dev make bzip2 xz-utils pkgconf \
      "gcc-$(echo "$T" | tr _ -)" "linux-libc-dev-$D-cross"; \
    rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4 \
    https://musl.libc.org/releases/musl-1.2.5.tar.gz /src/
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /src/
ADD --checksum=sha256:d87303d55ef8c92bcad4dd3f978b26d272013642b029425775f5bad1009fe7b2 \
    https://www.netfilter.org/pub/iptables/iptables-1.8.11.tar.xz /src/
COPY busybox.fragment /src/
WORKDIR /src

# musl for the target, plus a "target-cc" compiler wrapper
RUN set -e; . /target.env; \
    tar xzf musl-1.2.5.tar.gz; cd musl-1.2.5; \
    ./configure --target="$T" CROSS_COMPILE="$T-" CFLAGS="-Os $F" \
      --prefix=/opt/musl --disable-shared --enable-wrapper=gcc >/dev/null; \
    make -j"$(nproc)" >/dev/null; make install >/dev/null; \
    test -x /opt/musl/bin/musl-gcc || { echo "musl-gcc wrapper was not built" >&2; exit 1; }; \
    cp -r "/usr/$T/include/linux" "/usr/$T/include/asm" "/usr/$T/include/asm-generic" \
      /opt/musl/include/; \
    printf '#!/bin/sh\nexec /opt/musl/bin/musl-gcc %s "$@"\n' "$F" > /usr/local/bin/target-cc; \
    chmod 755 /usr/local/bin/target-cc

RUN set -e; . /target.env; \
    tar xjf busybox-1.37.0.tar.bz2; cd busybox-1.37.0; \
    make allnoconfig >/dev/null; \
    grep -E '^(# )?CONFIG_' ../busybox.fragment | while IFS= read -r line; do \
      k=$(echo "$line" | grep -o 'CONFIG_[A-Z0-9_]*'); \
      sed -i "/^# $k is not set\$/d; /^$k=/d" .config; \
      echo "$line" >> .config; \
    done; \
    yes '' | make oldconfig >/dev/null; \
    make -j"$(nproc)" CROSS_COMPILE="$T-" CC=target-cc busybox busybox.links; \
    install -D -m 755 busybox /out/bin/busybox; \
    cp busybox.links /out/busybox.links

RUN set -e; . /target.env; \
    tar xJf iptables-1.8.11.tar.xz; cd iptables-1.8.11; \
    ./configure --host="$T" CC=target-cc CFLAGS="-Os -ffunction-sections -fdata-sections" \
      --prefix=/usr --sysconfdir=/etc --enable-static --disable-shared \
      --disable-nftables --disable-libipq --disable-bpf-compiler \
      --disable-nfsynproxy --disable-connlabel --disable-libnfnetlink \
      --disable-devel --disable-largefile; \
    make -j"$(nproc)" LDFLAGS="-all-static -Wl,--gc-sections"; \
    mkdir -p /out/usr/sbin; \
    "$T-strip" -o /out/usr/sbin/xtables-legacy-multi iptables/xtables-legacy-multi

# --- 3. assemble the root filesystem ----------------------------------------
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS assemble
RUN apk add --no-cache upx
COPY --from=tools /out/ /rootfs/
COPY --from=tailscale /out/tailscaled /rootfs/usr/local/bin/tailscaled
COPY tailscale.sh /rootfs/usr/local/bin/tailscale.sh
WORKDIR /rootfs
RUN set -e; \
    upx --lzma --best bin/busybox usr/sbin/xtables-legacy-multi; \
    for l in $(cat busybox.links); do \
      mkdir -p ".${l%/*}"; ln -s /bin/busybox ".$l"; \
    done; \
    rm busybox.links; \
    for a in iptables iptables-save iptables-restore \
             ip6tables ip6tables-save ip6tables-restore \
             iptables-legacy iptables-legacy-save iptables-legacy-restore \
             ip6tables-legacy ip6tables-legacy-save ip6tables-legacy-restore; do \
      ln -s xtables-legacy-multi usr/sbin/$a; \
    done; \
    ln -s tailscaled usr/local/bin/tailscale; \
    chmod 755 usr/local/bin/tailscale.sh; \
    mkdir -p etc root tmp run var/lib/tailscale proc sys dev; \
    chmod 700 root; chmod 1777 tmp; ln -s ../run var/run; \
    printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\n' > etc/passwd; \
    printf 'root:x:0:root\nnobody:x:65534:\n' > etc/group; \
    printf 'hosts: files dns\n' > etc/nsswitch.conf; \
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > etc/hosts

# --- 4. final image -----------------------------------------------------------
FROM scratch
COPY --from=assemble /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD ["/usr/local/bin/tailscale.sh"]
