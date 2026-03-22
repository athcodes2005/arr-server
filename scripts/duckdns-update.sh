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
  IPV4="$(curl -4 -fsS https://ifconfig.me 2>/dev/null | tr -d '\r\n' || true)"
  IPV6="$(curl -6 -fsS https://ipv6.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"

  if [ -n "$IPV4" ] || [ -n "$IPV6" ]; then
    URL="https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}"

    if [ -n "$IPV4" ]; then
      URL="${URL}&ip=${IPV4}"
    fi

    if [ -n "$IPV6" ]; then
      URL="${URL}&ipv6=${IPV6}"
    fi

    RESPONSE="$(curl -fsS "$URL" 2>/dev/null || true)"
    log_line "$TIMESTAMP | ipv4=${IPV4:-none} | ipv6=${IPV6:-none} | status=${RESPONSE:-failed}"
  else
    log_line "$TIMESTAMP | ip lookup failed"
  fi

  sleep "${DUCKDNS_UPDATE_INTERVAL:-300}"
done
