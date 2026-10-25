#!/bin/sh
# Copyright (c) 2024 Fluent Networks Pty Ltd & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
#
# Entrypoint for the minimal image (busybox ash, no bash/sshd).

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null || echo "warning: could not enable IPv4 forwarding"
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || echo "warning: could not enable IPv6 forwarding"

mkdir -p /var/run/tailscale /var/lib/tailscale

if [ -n "${PASSWORD}" ]; then
  echo "note: PASSWORD is ignored, this image has no SSH server; use '/container/shell' on the router"
fi
if [ -n "${UPDATE_TAILSCALE+x}" ]; then
  echo "note: UPDATE_TAILSCALE is ignored, update by pulling/importing a newer image"
fi

# Install routes
for s in $(echo "${ADVERTISE_ROUTES}" | tr ',' ' '); do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done

# Set login server for tailscale
if [ -z "${LOGIN_SERVER}" ]; then
  LOGIN_SERVER=https://controlplane.tailscale.com
fi

# Execute startup script if it exists
if [ -n "${STARTUP_SCRIPT}" ] && [ -f "${STARTUP_SCRIPT}" ]; then
  sh "${STARTUP_SCRIPT}" || exit $?
fi

# Start tailscaled. The shell stays PID 1 and forwards stop signals so that
# tailscaled can clean up its routes and iptables rules. Long-running steps run
# in the background + `wait`, because traps only fire between commands.
/usr/local/bin/tailscaled ${TAILSCALED_ARGS} &
TSD_PID=$!
UP_PID=
STOP=
on_stop() {
  STOP=1
  kill -TERM $UP_PID $TSD_PID 2>/dev/null
}
trap on_stop TERM INT HUP

# Bring tailscale up
while [ -z "$STOP" ]; do
  /usr/local/bin/tailscale up \
    --reset --authkey="${AUTH_KEY}" \
    --login-server "${LOGIN_SERVER}" \
    --advertise-routes="${ADVERTISE_ROUTES}" \
    ${TAILSCALE_ARGS} &
  UP_PID=$!
  wait $UP_PID && break
  [ -z "$STOP" ] && kill -0 $TSD_PID 2>/dev/null || break
  sleep 1
done

if [ -z "$STOP" ] && kill -0 $TSD_PID 2>/dev/null; then
  echo Tailscale started

  # Check that a route exists for 100.64.0.0/10; if not, add
  if [ -z "$(ip route show 100.64.0.0/10)" ]; then
    ip route add 100.64.0.0/10 dev tailscale0
  fi

  # Check that a route exists for fd7a:115c:a1e0::/48; if not, add
  if [ -z "$(ip -6 route show fd7a:115c:a1e0::/48)" ]; then
    ip -6 route add fd7a:115c:a1e0::/48 dev tailscale0
  fi

  # Execute running script if it exists
  if [ -n "${RUNNING_SCRIPT}" ] && [ -f "${RUNNING_SCRIPT}" ]; then
    sh "${RUNNING_SCRIPT}" || on_stop
  fi
fi

# Stay in the foreground for as long as tailscaled runs
RC=0
while kill -0 $TSD_PID 2>/dev/null; do
  wait $TSD_PID; RC=$?
done
echo "tailscaled exited ($RC)"
exit $RC
