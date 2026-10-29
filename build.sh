#!/usr/bin/env sh
# Copyright (c) 2024 Fluent Networks Pty Ltd & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
#
# Runs `docker buildx build` and exports the image as tailscale.tar for
# uploading to the router. The tailscale source is cloned inside the build.
#
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
# Set PLATFORM as required for your router model. See:
# https://mikrotik.com/products/matrix
#   linux/arm64   - hAP ax2, hAP ax3, RB5009, ...
#   linux/arm/v7  - 32-bit ARM: hAP ac2, hAP ac3, RB4011, ...
#   linux/arm/v5  - ARMv5 (EN7562 CPU): hEX refresh, ...
#   linux/amd64   - CHR, x86
# Everything is cross-compiled, so no emulation or special builder is needed.
#
PLATFORM="${PLATFORM:-linux/arm64}"
VERSION=0.1.40

# Tailscale version to build. "latest" picks the newest stable release
# (stable releases have an even minor number, e.g. 1.104.x; odd ones are
# unstable). To pin a version: TAILSCALE_VERSION=1.104.2 ./build.sh
TAILSCALE_VERSION=${TAILSCALE_VERSION:-latest}

# Optional extra Tailscale features, e.g.: TS_EXTRA_FEATURES=ssh,useexitnode ./build.sh
TS_EXTRA_FEATURES=${TS_EXTRA_FEATURES:-}

# Build with every Tailscale feature (the "full" image): TS_ALL_FEATURES=true ./build.sh
TS_ALL_FEATURES=${TS_ALL_FEATURES:-false}

set -eu

if [ "$TAILSCALE_VERSION" = "latest" ]; then
  TAILSCALE_VERSION=$(git ls-remote --tags --refs https://github.com/tailscale/tailscale.git 'v1.*' \
    | sed -n 's#.*refs/tags/v\(1\.[0-9]*[02468]\.[0-9]*\)$#\1#p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  if [ -z "$TAILSCALE_VERSION" ]; then
    echo "Could not determine the latest Tailscale version" >&2
    exit 1
  fi
fi
echo "Building Tailscale $TAILSCALE_VERSION${TS_EXTRA_FEATURES:+ with extra features: $TS_EXTRA_FEATURES}$( [ "$TS_ALL_FEATURES" = true ] && echo ' with all features')"

rm -f tailscale.tar

docker buildx build \
  --no-cache \
  --build-arg TAILSCALE_VERSION=$TAILSCALE_VERSION \
  --build-arg TS_EXTRA_FEATURES=$TS_EXTRA_FEATURES \
  --build-arg TS_ALL_FEATURES=$TS_ALL_FEATURES \
  --platform $PLATFORM \
  --load -t ghcr.io/fluent-networks/tailscale-mikrotik:$VERSION .

skopeo copy docker-daemon:ghcr.io/fluent-networks/tailscale-mikrotik:$VERSION docker-archive:tailscale.tar
