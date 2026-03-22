#!/bin/sh
set -eu

ROOT_DIR="${1:-$(pwd)}"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: .env not found at $ENV_FILE" >&2
  exit 1
fi

extract_xml_key() {
  file="$1"
  if [ ! -f "$file" ]; then
    return 0
  fi

  sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$file" | head -n 1
}

extract_bazarr_key() {
  file="$1"
  if [ ! -f "$file" ]; then
    return 0
  fi

  awk '
    $1 == "auth:" { in_auth=1; next }
    in_auth && $1 ~ /^[^[:space:]]/ { exit }
    in_auth && $1 == "apikey:" {
      gsub(/'\''/, "", $2)
      print $2
      exit
    }
  ' "$file"
}

set_env_value() {
  key="$1"
  value="$2"

  if [ -z "$value" ]; then
    echo "skip: $key not found"
    return
  fi

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
  echo "updated: $key"
}

PROWLARR_API_KEY="$(extract_xml_key "$ROOT_DIR/configs/prowlarr/config.xml")"
SONARR_API_KEY="$(extract_xml_key "$ROOT_DIR/configs/sonarr/config.xml")"
RADARR_API_KEY="$(extract_xml_key "$ROOT_DIR/configs/radarr/config.xml")"
BAZARR_API_KEY="$(extract_bazarr_key "$ROOT_DIR/configs/bazarr/config/config.yaml")"

set_env_value "PROWLARR_API_KEY" "$PROWLARR_API_KEY"
set_env_value "SONARR_API_KEY" "$SONARR_API_KEY"
set_env_value "RADARR_API_KEY" "$RADARR_API_KEY"
set_env_value "BAZARR_API_KEY" "$BAZARR_API_KEY"
