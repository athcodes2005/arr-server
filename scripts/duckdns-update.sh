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

# Extract only the variables this script needs via grep rather than sourcing
# the entire .env file. Sourcing with `set -a; . .env; set +a` is unsafe when
# .env contains values with bare $ signs — e.g. WEBDAV_PASSWORD_HASH contains
# a bcrypt hash starting with $2a$ which bash interprets as positional params,
# causing `set -euo pipefail` to abort on the unbound variable error.
_env_get() {
  grep -m1 "^${1}=" "${ENV_FILE}" | cut -d= -f2-
}

DOMAIN="${DOMAIN:-$(_env_get DOMAIN)}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-$(_env_get DUCKDNS_TOKEN)}"
DUCKDNS_IFACE="${DUCKDNS_IFACE:-$(_env_get DUCKDNS_IFACE)}"

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

# Pick the first global-scope, non-deprecated, non-ULA (fc00::/7) IPv6.
# When the ISP rotates the prefix the old GUA lingers on the interface marked
# "deprecated" until its valid lifetime expires.  Without the grep -v filter
# head -n1 picks the stale deprecated address so DuckDNS never learns the new
# prefix, causing an outage until the old address finally disappears.
IPV6="$(ip -6 -o addr show dev "${IFACE}" scope global 2>/dev/null \
  | grep -v deprecated \
  | awk '{print $4}' \
  | cut -d/ -f1 \
  | grep -vE '^(fc|fd)' \
  | head -n1)"

if [ -z "${IPV6}" ]; then
  printf '[duckdns] No public IPv6 found on %s\n' "${IFACE}" >&2
  exit 1
fi

RESPONSE="$(curl -fsS -m 15 --retry 3 --retry-delay 2 \
  "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${IPV6}&ip=" \
  || true)"
# &ip= is intentionally empty. When omitted, DuckDNS auto-detects the caller's
# IPv4 and sets an A record, which is wrong for this stack — the Pi is only
# reachable over IPv6. An empty ip parameter prevents the A record from being
# touched on every update.

if [ "${RESPONSE}" = "OK" ]; then
  printf '[duckdns] %s OK %s\n' "$(date -Is)" "${IPV6}"
  exit 0
fi

printf '[duckdns] %s FAIL response=%q ip=%s\n' "$(date -Is)" "${RESPONSE}" "${IPV6}" >&2
exit 1
