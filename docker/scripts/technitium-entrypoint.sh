#!/bin/bash
set -euo pipefail

###############################################################################
# Technitium resolves the DNS_SERVER_FORWARDERS address using its own
# internal DNS client instead of the container's OS/Docker resolver. Since
# there is only a single forwarder configured, Technitium has no other
# resolver to look up a hostname with, so a plain service name like "unbound"
# can never be resolved by it directly (see the "Domain does not exists"
# errors going to the root servers in the logs).
#
# This wrapper resolves the "unbound" service name via getent, which uses
# the container's normal OS resolver (Docker's embedded DNS at 127.0.0.11)
# and therefore works correctly. The resolved IP address is then passed to
# Technitium as DNS_SERVER_FORWARDERS. This runs on every container start,
# so no IP address has to be hardcoded or manually kept in sync - it always
# reflects whatever IP Docker currently assigned to the "unbound" service.
###############################################################################

UNBOUND_HOST="${UNBOUND_HOST:-unbound}"
UNBOUND_PORT="${UNBOUND_PORT:-5335}"

echo "[technitium-entrypoint] Resolving ${UNBOUND_HOST}..."
UNBOUND_IP=""
for _ in $(seq 1 30); do
  UNBOUND_IP="$(getent hosts "${UNBOUND_HOST}" | awk '{ print $1 }' | head -n1 || true)"
  if [ -n "${UNBOUND_IP}" ]; then
    break
  fi
  sleep 1
done

if [ -z "${UNBOUND_IP}" ]; then
  echo "[technitium-entrypoint] ERROR: could not resolve ${UNBOUND_HOST} after 30 attempts" >&2
  exit 1
fi

echo "[technitium-entrypoint] Resolved ${UNBOUND_HOST} to ${UNBOUND_IP}, forwarding to ${UNBOUND_IP}:${UNBOUND_PORT}"
export DNS_SERVER_FORWARDERS="${UNBOUND_IP}:${UNBOUND_PORT}"

exec /usr/bin/dotnet /opt/technitium/dns/DnsServerApp.dll /etc/dns
