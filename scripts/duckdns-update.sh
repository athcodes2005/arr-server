#!/usr/bin/env bash
#
# Pushes the Pi's current public IPv6 address to DuckDNS.
# Reads DOMAIN and DUCKDNS_TOKEN from ../.env and posts to the DuckDNS
# update API. Intended to be installed as a cron job by bootstrap-remote.sh
# so the AAAA record stays fresh when the ISP rotates the IPv6 prefix.
#
# Exit codes:
#   0  update accepted by DuckDNS
#   1  configuration or network error (will be retried by cron)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  printf '[duckdns] Missing %s\n' "${ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
. "${ENV_FILE}"
set +a

: "${DOMAIN:?[duckdns] DOMAIN not set in .env}"

if [ -z "${DUCKDNS_TOKEN:-}" ]; then
  printf '[duckdns] DUCKDNS_TOKEN not set; skipping update\n' >&2
  exit 0
fi

SUBDOMAIN="${DOMAIN%.duckdns.org}"
if [ "${SUBDOMAIN}" = "${DOMAIN}" ]; then
  printf '[duckdns] DOMAIN=%s does not end in .duckdns.org\n' "${DOMAIN}" >&2
  exit 1
fi

IFACE="${DUCKDNS_IFACE:-eth0}"

# Pick the first global-scope IPv6 that is not a ULA (fc00::/7).
# The Pi's Docker daemon adds a ULA prefix for internal networking which
# we must skip. Only the ISP-assigned GUA is routable.
IPV6="$(ip -6 -o addr show dev "${IFACE}" scope global 2>/dev/null \
  | awk '{print $4}' \
  | cut -d/ -f1 \
  | grep -vE '^(fc|fd)' \
  | head -n1)"

if [ -z "${IPV6}" ]; then
  printf '[duckdns] No public IPv6 found on %s\n' "${IFACE}" >&2
  exit 1
fi

RESPONSE="$(curl -fsS -m 15 --retry 3 --retry-delay 2 \
  "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${IPV6}" \
  || true)"

if [ "${RESPONSE}" = "OK" ]; then
  printf '[duckdns] %s OK %s\n' "$(date -Is)" "${IPV6}"
  exit 0
fi

printf '[duckdns] %s FAIL response=%q ip=%s\n' "$(date -Is)" "${RESPONSE}" "${IPV6}" >&2
exit 1
