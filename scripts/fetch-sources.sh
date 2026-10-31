#!/bin/sh
# Download the musl, BusyBox and iptables source code into <dir>.
# Each file is tried from its own website first (with retries), then from the
# identical copies in Ubuntu's and Debian's archives, and is always checked
# against its SHA-256, so one slow server can't fail a build.
#
# Usage: fetch-sources.sh <dir>
set -eu
mkdir -p "$1"
cd "$1"

fetch() { # <file> <sha256> <url>...
  file=$1; sum=$2; shift 2
  for url in "$@"; do
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 \
         --speed-limit 1024 --speed-time 60 -o "$file" "$url" \
       && echo "$sum  $file" | sha256sum -c - >/dev/null 2>&1; then
      echo "$file: OK from $url"
      return 0
    fi
    echo "$file: $url failed or had a wrong checksum, trying the next source" >&2
    rm -f "$file"
  done
  echo "$file: could not be downloaded from any source" >&2
  return 1
}

fetch musl-1.2.5.tar.gz a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4 \
  https://musl.libc.org/releases/musl-1.2.5.tar.gz \
  http://archive.ubuntu.com/ubuntu/pool/universe/m/musl/musl_1.2.5.orig.tar.gz \
  http://deb.debian.org/debian/pool/main/m/musl/musl_1.2.5.orig.tar.gz

fetch busybox-1.37.0.tar.bz2 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
  https://busybox.net/downloads/busybox-1.37.0.tar.bz2 \
  http://archive.ubuntu.com/ubuntu/pool/main/b/busybox/busybox_1.37.0.orig.tar.bz2 \
  http://deb.debian.org/debian/pool/main/b/busybox/busybox_1.37.0.orig.tar.bz2

fetch iptables-1.8.11.tar.xz d87303d55ef8c92bcad4dd3f978b26d272013642b029425775f5bad1009fe7b2 \
  https://www.netfilter.org/pub/iptables/iptables-1.8.11.tar.xz \
  http://archive.ubuntu.com/ubuntu/pool/main/i/iptables/iptables_1.8.11.orig.tar.xz \
  http://deb.debian.org/debian/pool/main/i/iptables/iptables_1.8.11.orig.tar.xz
