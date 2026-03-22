#!/bin/sh
set -eu

LOG_FILE="/logs/duckdns-updater/duckdns.log"
mkdir -p "$(dirname "$LOG_FILE")"

log_line() {
  if ! printf '%s\n' "$1" >> "$LOG_FILE" 2>/dev/null; then
    printf '%s\n' "$1"
  fi
}

while true; do
  TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  IPV6="$(curl -6 -fsS https://ipv6.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"

  if [ -n "$IPV6" ]; then
    RESPONSE="$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${IPV6}" 2>/dev/null || true)"
    log_line "$TIMESTAMP | ipv6=$IPV6 | status=${RESPONSE:-failed}"
  else
    log_line "$TIMESTAMP | ipv6 lookup failed"
  fi

  sleep "${DUCKDNS_UPDATE_INTERVAL:-300}"
done
