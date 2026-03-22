#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"

if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "error: missing $ENV_EXAMPLE" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

generate_secret() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

prompt_value() {
  key="$1"
  label="$2"
  default_value="$3"
  secret="${4:-0}"

  while true; do
    if [ "$secret" = "1" ]; then
      printf "%s [%s]: " "$label" "$default_value" >&2
      stty -echo
      IFS= read -r value
      stty echo
      printf "\n" >&2
    else
      printf "%s [%s]: " "$label" "$default_value" >&2
      IFS= read -r value
    fi

    if [ -z "$value" ]; then
      value="$default_value"
    fi

    if [ -n "$value" ]; then
      printf "%s" "$value"
      return
    fi
  done
}

set_env_value() {
  key="$1"
  value="$2"
  tmp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"

  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" > "$tmp_file"

  mv "$tmp_file" "$ENV_FILE"
}

read_env_value() {
  key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }' "$ENV_FILE"
}

confirm() {
  prompt="$1"
  default_answer="${2:-y}"

  while true; do
    if [ "$default_answer" = "y" ]; then
      printf "%s [Y/n]: " "$prompt" >&2
    else
      printf "%s [y/N]: " "$prompt" >&2
    fi

    IFS= read -r answer
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"

    if [ -z "$answer" ]; then
      answer="$default_answer"
    fi

    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

require_cmd awk
require_cmd sed
require_cmd docker

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "created $ENV_FILE from .env.example"
else
  echo "using existing $ENV_FILE"
fi

echo
echo "ARR Server initial setup"
echo "Repository: $ROOT_DIR"
echo

duck_subdomain_default="$(read_env_value DUCKDNS_SUBDOMAIN || true)"
duck_domain_default="$(read_env_value DUCKDNS_DOMAIN || true)"
duck_token_default="$(read_env_value DUCKDNS_TOKEN || true)"
timezone_default="$(read_env_value TZ || true)"
qbit_user_default="$(read_env_value QBITTORRENT_USERNAME || true)"
qbit_pass_default="$(read_env_value QBITTORRENT_PASSWORD || true)"
webdav_user_default="$(read_env_value WEBDAV_USERNAME || true)"
webdav_pass_default="$(read_env_value WEBDAV_PASSWORD || true)"
caddy_email_default="$(read_env_value CADDY_EMAIL || true)"

duck_subdomain="$(prompt_value DUCKDNS_SUBDOMAIN "DuckDNS subdomain" "${duck_subdomain_default:-mypi2025}")"
duck_domain="$(prompt_value DUCKDNS_DOMAIN "Public domain" "${duck_domain_default:-$duck_subdomain.duckdns.org}")"
duck_token="$(prompt_value DUCKDNS_TOKEN "DuckDNS token" "${duck_token_default:-}" 1)"
timezone_value="$(prompt_value TZ "Timezone" "${timezone_default:-Asia/Kolkata}")"

if [ -z "$qbit_pass_default" ] || [ "$qbit_pass_default" = "replace-with-a-strong-password" ] || [ "$qbit_pass_default" = "change-me-after-first-boot" ]; then
  qbit_pass_default="$(generate_secret)"
fi

if [ -z "$webdav_pass_default" ] || [ "$webdav_pass_default" = "replace-with-a-strong-password" ] || [ "$webdav_pass_default" = "change-me-after-first-boot" ]; then
  webdav_pass_default="$(generate_secret)"
fi

qbit_user="$(prompt_value QBITTORRENT_USERNAME "qBittorrent username" "${qbit_user_default:-admin}")"
qbit_pass="$(prompt_value QBITTORRENT_PASSWORD "qBittorrent password" "$qbit_pass_default" 1)"
webdav_user="$(prompt_value WEBDAV_USERNAME "WebDAV username" "${webdav_user_default:-admin}")"
webdav_pass="$(prompt_value WEBDAV_PASSWORD "WebDAV password" "$webdav_pass_default" 1)"
caddy_email="$(prompt_value CADDY_EMAIL "Caddy email (optional)" "${caddy_email_default:-}")"

set_env_value "DUCKDNS_SUBDOMAIN" "$duck_subdomain"
set_env_value "DUCKDNS_DOMAIN" "$duck_domain"
set_env_value "DUCKDNS_TOKEN" "$duck_token"
set_env_value "TZ" "$timezone_value"
set_env_value "QBITTORRENT_USERNAME" "$qbit_user"
set_env_value "QBITTORRENT_PASSWORD" "$qbit_pass"
set_env_value "WEBDAV_USERNAME" "$webdav_user"
set_env_value "WEBDAV_PASSWORD" "$webdav_pass"
set_env_value "CADDY_EMAIL" "$caddy_email"

echo
echo ".env updated."
echo

if confirm "Render docker compose config now?" "y"; then
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/compose.yaml" config >/dev/null
  echo "compose config check passed"
fi

if confirm "Pull container images now?" "y"; then
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/compose.yaml" pull
fi

if confirm "Start the stack now?" "y"; then
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/compose.yaml" up -d --build
  echo
  echo "stack started"
  echo "next steps:"
  echo "1. Run ./scripts/configure-base-urls.sh after first boot if needed."
  echo "2. Run ./scripts/update-api-keys.sh after ARR apps generate API keys."
  echo "3. Open https://$duck_domain/ over IPv6."
else
  echo "skipped docker compose up"
fi
