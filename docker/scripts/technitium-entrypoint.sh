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
# Technitium as DNS_SERVER_FORWARDERS for first boot.
#
# After first boot, Technitium loads forwarders from /etc/dns/dns.config and
# ignores DNS_SERVER_FORWARDERS. To avoid stale forwarder IPs when Docker
# reassigns Unbound's container IP, this wrapper now also updates forwarders
# through the Technitium API on every start (when admin credentials are
# available).
###############################################################################

UNBOUND_HOST="${UNBOUND_HOST:-unbound}"
UNBOUND_PORT="${UNBOUND_PORT:-5335}"
WEB_SERVICE_HTTP_PORT="${DNS_SERVER_WEB_SERVICE_HTTP_PORT:-5380}"
WEB_SERVICE_URL="http://127.0.0.1:${WEB_SERVICE_HTTP_PORT}"
FORWARDER_PROTOCOL="${DNS_SERVER_FORWARDER_PROTOCOL:-Udp}"

log() {
  echo "[technitium-entrypoint] $*"
}

log "Resolving ${UNBOUND_HOST}..."
UNBOUND_IP=""
for _ in $(seq 1 30); do
  # Force IPv4 lookup: "getent hosts" can return an AAAA record first if the
  # network has IPv6 assigned, but Unbound only listens on IPv4 (do-ip6: no),
  # so an IPv6 forwarder address would be unreachable.
  UNBOUND_IP="$(getent ahostsv4 "${UNBOUND_HOST}" | awk '{ print $1 }' | head -n1 || true)"
  if [ -n "${UNBOUND_IP}" ]; then
    break
  fi
  sleep 1
done

if [ -z "${UNBOUND_IP}" ]; then
  log "ERROR: could not resolve ${UNBOUND_HOST} after 30 attempts" >&2
  exit 1
fi

log "Resolved ${UNBOUND_HOST} to ${UNBOUND_IP}, forwarding to ${UNBOUND_IP}:${UNBOUND_PORT}"
export DNS_SERVER_FORWARDERS="${UNBOUND_IP}:${UNBOUND_PORT}"

/usr/bin/dotnet /opt/technitium/dns/DnsServerApp.dll /etc/dns &
TECHNITIUM_PID=$!

# shellcheck disable=SC2317
forward_signal() {
  local signal="$1"
  log "Received ${signal}; forwarding to Technitium (pid ${TECHNITIUM_PID})..."
  kill -"${signal}" "${TECHNITIUM_PID}" 2>/dev/null || true
}

trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

if ! command -v curl >/dev/null 2>&1; then
  log "WARNING: curl not found; skipping API forwarder reconciliation."
else
  for _ in $(seq 1 30); do
    if curl --silent --show-error --fail "${WEB_SERVICE_URL}/api/status" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! curl --silent --show-error --fail "${WEB_SERVICE_URL}/api/status" >/dev/null 2>&1; then
    log "WARNING: Technitium API at ${WEB_SERVICE_URL} did not become ready in time; skipping forwarder reconciliation."
  else
    ADMIN_PASSWORD="${DNS_SERVER_ADMIN_PASSWORD:-}"
    if [ -z "${ADMIN_PASSWORD}" ] && [ -n "${DNS_SERVER_ADMIN_PASSWORD_FILE:-}" ]; then
      if [ -r "${DNS_SERVER_ADMIN_PASSWORD_FILE}" ]; then
        ADMIN_PASSWORD="$(head -n1 "${DNS_SERVER_ADMIN_PASSWORD_FILE}" || true)"
      else
        log "WARNING: DNS_SERVER_ADMIN_PASSWORD_FILE is set but unreadable (${DNS_SERVER_ADMIN_PASSWORD_FILE}); skipping forwarder reconciliation."
      fi
    fi

    if [ -z "${ADMIN_PASSWORD}" ]; then
      log "WARNING: DNS_SERVER_ADMIN_PASSWORD(_FILE) not set; skipping forwarder reconciliation via API."
    else
      LOGIN_RESPONSE="$(
        curl --silent --show-error --fail --get \
          --data-urlencode "user=admin" \
          --data-urlencode "pass=${ADMIN_PASSWORD}" \
          --data-urlencode "includeInfo=true" \
          "${WEB_SERVICE_URL}/api/user/login" 2>/dev/null || true
      )"
      TOKEN="$(printf '%s' "${LOGIN_RESPONSE}" | tr -d '\n' | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

      if [ -z "${TOKEN}" ]; then
        log "WARNING: Could not authenticate to Technitium API as admin; skipping forwarder reconciliation."
      else
        SETTINGS_RESPONSE="$(
          curl --silent --show-error --fail --get \
            --data-urlencode "token=${TOKEN}" \
            "${WEB_SERVICE_URL}/api/settings/get" 2>/dev/null || true
        )"
        CURRENT_FORWARDERS="$(printf '%s' "${SETTINGS_RESPONSE}" | tr -d '\n' | sed -n 's/.*"forwarders"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d ' "')" # comma separated
        CURRENT_PROTOCOL="$(printf '%s' "${SETTINGS_RESPONSE}" | tr -d '\n' | sed -n 's/.*"forwarderProtocol"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        DESIRED_FORWARDER="${UNBOUND_IP}:${UNBOUND_PORT}"

        if [ "${CURRENT_FORWARDERS}" = "${DESIRED_FORWARDER}" ] && [ "${CURRENT_PROTOCOL}" = "${FORWARDER_PROTOCOL}" ]; then
          log "Forwarder already up to date (${CURRENT_FORWARDERS}, protocol ${CURRENT_PROTOCOL})."
        else
          SET_RESPONSE="$(
            curl --silent --show-error --fail --get \
              --data-urlencode "token=${TOKEN}" \
              --data-urlencode "forwarders=${DESIRED_FORWARDER}" \
              --data-urlencode "forwarderProtocol=${FORWARDER_PROTOCOL}" \
              "${WEB_SERVICE_URL}/api/settings/set" 2>/dev/null || true
          )"
          if printf '%s' "${SET_RESPONSE}" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            if [ -n "${CURRENT_FORWARDERS}" ]; then
              log "Updated forwarder from ${CURRENT_FORWARDERS} (${CURRENT_PROTOCOL:-unknown}) to ${DESIRED_FORWARDER} (${FORWARDER_PROTOCOL})."
            else
              log "Set forwarder to ${DESIRED_FORWARDER} (${FORWARDER_PROTOCOL})."
            fi
          else
            log "WARNING: Failed to update forwarder via API; Technitium keeps existing settings."
          fi
        fi
      fi
    fi
  fi
fi

set +e
wait "${TECHNITIUM_PID}"
exit_code=$?
set -e
trap - TERM INT
exit "${exit_code}"
