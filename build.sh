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
#
PLATFORM="linux/arm64"
VERSION=0.1.40

# Tailscale version to build. "latest" picks the newest stable release
# (stable releases have an even minor number, e.g. 1.104.x; odd ones are
# unstable). To pin a version: TAILSCALE_VERSION=1.104.2 ./build.sh
TAILSCALE_VERSION=${TAILSCALE_VERSION:-latest}

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
echo "Building Tailscale $TAILSCALE_VERSION"

rm -f tailscale.tar

docker buildx build \
  --no-cache \
  --build-arg TAILSCALE_VERSION=$TAILSCALE_VERSION \
  --platform $PLATFORM \
  --builder arm64-builder \
  --load -t ghcr.io/fluent-networks/tailscale-mikrotik:$VERSION .

skopeo copy docker-daemon:ghcr.io/fluent-networks/tailscale-mikrotik:$VERSION docker-archive:tailscale.tar
