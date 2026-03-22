#!/bin/sh
set -eu

LOG_FILE="/logs/duckdns-updater/duckdns.log"
mkdir -p "$(dirname "$LOG_FILE")"

while true; do
  TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  IPV6="$(curl -6 -fsS https://ipv6.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"

  if [ -n "$IPV6" ]; then
    RESPONSE="$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${IPV6}" 2>/dev/null || true)"
    printf '%s | ipv6=%s | status=%s\n' "$TIMESTAMP" "$IPV6" "${RESPONSE:-failed}" >> "$LOG_FILE"
  else
    printf '%s | ipv6 lookup failed\n' "$TIMESTAMP" >> "$LOG_FILE"
  fi

  sleep "${DUCKDNS_UPDATE_INTERVAL:-300}"
done
