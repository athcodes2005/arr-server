#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DEFAULT_TRACKER_LIST_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"

log() {
  printf '[bootstrap] %s\n' "$*"
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

compose_cmd() {
  docker_cmd compose --env-file "${ENV_FILE}" "$@"
}

wait_for_file() {
  local path="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-2}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if [ -f "${path}" ]; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done

  printf '[bootstrap-error] Timed out waiting for %s\n' "${path}" >&2
  return 1
}

hash_qbittorrent_password() {
  PASSWORD_INPUT="${QBITTORRENT_WEBUI_PASSWORD}" python3 - <<'PY'
import base64
import hashlib
import os

password = os.environ["PASSWORD_INPUT"].encode()
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac("sha512", password, salt, 100000)
print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})')
PY
}

write_qbittorrent_config() {
  local password_hash
  password_hash="$(hash_qbittorrent_password)"

  mkdir -p "${ROOT_DIR}/qbittorrent/config/qBittorrent"

  cat > "${ROOT_DIR}/qbittorrent/config/qBittorrent/qBittorrent.conf" <<EOF
[Application]
FileLogger\\Age=1
FileLogger\\AgeType=1
FileLogger\\Backup=true
FileLogger\\DeleteOld=true
FileLogger\\Enabled=true
FileLogger\\MaxSizeBytes=10485760
FileLogger\\Path=/config/qBittorrent/logs

[AutoRun]
enabled=false
program=

[BitTorrent]
Session\\AddTorrentStopped=false
Session\\AddTrackersFromURLEnabled=true
Session\\AdditionalTrackersURL=${QBITTORRENT_TRACKER_LIST_URL}
Session\\DefaultSavePath=/data/torrents/
Session\\Encryption=1
Session\\Port=${QBITTORRENT_TORRENT_PORT}
Session\\QueueingSystemEnabled=true
Session\\ShareLimitAction=Stop
Session\\TempPath=/data/torrents/incomplete/

[Core]
AutoDeleteAddedTorrentFile=IfAdded

[LegalNotice]
Accepted=true

[Meta]
MigrationVersion=8

[Network]
PortForwardingEnabled=false
Proxy\\HostnameLookupEnabled=false
Proxy\\Profiles\\BitTorrent=true
Proxy\\Profiles\\Misc=true
Proxy\\Profiles\\RSS=true

[Preferences]
Connection\\PortRangeMin=${QBITTORRENT_TORRENT_PORT}
Connection\\UPnP=false
Downloads\\SavePath=/data/torrents/
Downloads\\TempPath=/data/torrents/incomplete/
General\\DeleteTorrentsFilesAsDefault=true
General\\Locale=en
WebUI\\Address=*
WebUI\\AuthSubnetWhitelist=@Invalid()
WebUI\\CSRFProtection=false
WebUI\\ClickjackingProtection=false
WebUI\\HostHeaderValidation=false
WebUI\\LocalHostAuth=false
WebUI\\MaxAuthenticationFailCount=300
WebUI\\Password_PBKDF2="${password_hash}"
WebUI\\Port=${QBITTORRENT_WEBUI_PORT}
WebUI\\SecureCookie=true
WebUI\\ServerDomains=*
WebUI\\Username=${QBITTORRENT_WEBUI_USERNAME}

[RSS]
AutoDownloader\\DownloadRepacks=true
EOF
}

set_env_value() {
  local key="$1"
  local value="$2"

  python3 - "${ENV_FILE}" "${key}" "${value}" <<'PY'
from pathlib import Path
import re
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = env_path.read_text()
pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
line = f"{key}={value}"
if pattern.search(text):
    text = pattern.sub(line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += line + "\n"
env_path.write_text(text)
PY
}

set_arr_base_urls() {
  wait_for_file "${ROOT_DIR}/prowlarr/data/config.xml"
  wait_for_file "${ROOT_DIR}/sonarr/data/config.xml"
  wait_for_file "${ROOT_DIR}/radarr/data/config.xml"
  wait_for_file "${ROOT_DIR}/bazarr/data/config/config.yaml"

  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/prowlarr</UrlBase>|' "${ROOT_DIR}/prowlarr/data/config.xml"
  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/sonarr</UrlBase>|' "${ROOT_DIR}/sonarr/data/config.xml"
  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/radarr</UrlBase>|' "${ROOT_DIR}/radarr/data/config.xml"

  python3 - "${ROOT_DIR}/bazarr/data/config/config.yaml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
found_general = False
updated = False

for index, line in enumerate(lines):
    if line.strip() == "general:":
        found_general = True
        continue
    if found_general and line.startswith("  base_url:"):
        lines[index] = "  base_url: /bazarr"
        updated = True
        break
    if found_general and line and not line.startswith("  "):
        break

if not updated:
    if found_general:
        insert_at = next((i for i, line in enumerate(lines) if line.strip() == "general:"), len(lines))
        lines.insert(insert_at + 1, "  base_url: /bazarr")
    else:
        lines.append("general:")
        lines.append("  base_url: /bazarr")

path.write_text("\n".join(lines) + "\n")
PY

  compose_cmd restart prowlarr sonarr radarr bazarr
}

set_arr_forms_auth() {
  local arr_username arr_password compose_project network_name

  arr_username="${ARR_AUTH_USERNAME:-${QBITTORRENT_WEBUI_USERNAME:-admin}}"
  arr_password="${ARR_AUTH_PASSWORD:-${QBITTORRENT_WEBUI_PASSWORD:-}}"

  if [ -z "${arr_password}" ]; then
    log "Skipping ARR auth bootstrap because no password is configured"
    return 0
  fi

  compose_project="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}"
  network_name="${compose_project}_arr_net"

  python3 - "${ROOT_DIR}" "${network_name}" "${arr_username}" "${arr_password}" <<'PY'
from pathlib import Path
import json
import re
import subprocess
import sys
import time

root_dir = Path(sys.argv[1])
network_name = sys.argv[2]
arr_username = sys.argv[3]
arr_password = sys.argv[4]

docker_prefix = ["docker"]
if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    docker_prefix = ["sudo", "docker"]

def extract_xml_api_key(path: Path) -> str:
    match = re.search(r"<ApiKey>([^<]+)</ApiKey>", path.read_text())
    if not match:
        raise SystemExit(f"[bootstrap-error] Missing ApiKey in {path}")
    return match.group(1)

targets = [
    ("prowlarr", "http://prowlarr:9696/prowlarr/api/v1/config/host", extract_xml_api_key(root_dir / "prowlarr" / "data" / "config.xml")),
    ("sonarr", "http://sonarr:8989/sonarr/api/v3/config/host", extract_xml_api_key(root_dir / "sonarr" / "data" / "config.xml")),
    ("radarr", "http://radarr:7878/radarr/api/v3/config/host", extract_xml_api_key(root_dir / "radarr" / "data" / "config.xml")),
]

for service, url, api_key in targets:
    get_cmd = docker_prefix + [
        "run", "--rm", "--network", network_name,
        "curlimages/curl:8.12.1",
        "-fsS",
        "-H", f"X-Api-Key: {api_key}",
        url,
    ]

    current = None
    last_error = None
    for _ in range(30):
        try:
            current = json.loads(subprocess.check_output(get_cmd, text=True, stderr=subprocess.STDOUT))
            break
        except subprocess.CalledProcessError as exc:
            last_error = exc.output.strip()
            time.sleep(2)

    if current is None:
        raise SystemExit(f"[bootstrap-error] {service} did not become ready for auth bootstrap: {last_error}")

    current["authenticationMethod"] = "forms"
    current["authenticationRequired"] = "enabled"
    current["username"] = arr_username
    current["password"] = arr_password
    current["passwordConfirmation"] = arr_password

    put_cmd = docker_prefix + [
        "run", "--rm", "--network", network_name,
        "curlimages/curl:8.12.1",
        "-fsS",
        "-X", "PUT",
        "-H", f"X-Api-Key: {api_key}",
        "-H", "Content-Type: application/json",
        "--data", json.dumps(current),
        url,
    ]
    subprocess.check_call(put_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"[bootstrap] Enabled forms auth for {service}")
PY
}

configure_prowlarr_integrations() {
  local compose_project network_name

  compose_project="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}"
  network_name="${compose_project}_arr_net"

  python3 - "${ROOT_DIR}" "${network_name}" <<'PY'
from pathlib import Path
import copy
import json
import re
import subprocess
import sys
import time

root_dir = Path(sys.argv[1])
network_name = sys.argv[2]

docker_prefix = ["docker"]
if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    docker_prefix = ["sudo", "docker"]

def extract_xml_api_key(path: Path) -> str:
    match = re.search(r"<ApiKey>([^<]+)</ApiKey>", path.read_text())
    if not match:
        raise SystemExit(f"[bootstrap-error] Missing ApiKey in {path}")
    return match.group(1)

def run_request(method: str, url: str, api_key: str, payload=None) -> str:
    cmd = docker_prefix + [
        "run", "--rm", "--network", network_name,
        "curlimages/curl:8.12.1",
        "-fsS",
        "-X", method,
        "-H", f"X-Api-Key: {api_key}",
    ]
    if payload is not None:
        cmd += ["-H", "Content-Type: application/json", "--data", json.dumps(payload)]
    cmd.append(url)
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)

def request_json(method: str, url: str, api_key: str, payload=None):
    return json.loads(run_request(method, url, api_key, payload))

def wait_for_json(url: str, api_key: str, attempts: int = 30, sleep_seconds: int = 2):
    last_error = None
    for _ in range(attempts):
        try:
            return request_json("GET", url, api_key)
        except subprocess.CalledProcessError as exc:
            last_error = exc.output.strip()
            time.sleep(sleep_seconds)
    raise SystemExit(f"[bootstrap-error] Prowlarr did not become ready: {last_error}")

def schema_for(schemas, implementation: str):
    for item in schemas:
        if item.get("implementation") == implementation:
            return copy.deepcopy(item)
    raise SystemExit(f"[bootstrap-error] Missing Prowlarr schema for {implementation}")

def set_field(payload, field_name: str, value):
    for field in payload.get("fields", []):
        if field.get("name") == field_name:
            field["value"] = value
            return
    raise SystemExit(f"[bootstrap-error] Missing field {field_name} in payload for {payload.get('implementation')}")

def ensure_tag(label: str, api_key: str) -> int:
    """Return the Prowlarr tag id for label, creating it if missing."""
    tags = request_json("GET", "http://prowlarr:9696/prowlarr/api/v1/tag", api_key)
    for tag in tags:
        if tag.get("label") == label:
            return tag["id"]
    created = request_json(
        "POST",
        "http://prowlarr:9696/prowlarr/api/v1/tag",
        api_key,
        {"label": label},
    )
    return created["id"]

def upsert_indexer_proxy(name: str, implementation: str, field_values: dict, api_key: str, schemas, existing_items, tag_ids=None):
    existing = next(
        (
            item for item in existing_items
            if item.get("implementation") == implementation or item.get("name") == name
        ),
        None,
    )

    payload = copy.deepcopy(existing) if existing else schema_for(schemas, implementation)
    payload["name"] = name
    payload["implementation"] = implementation
    payload["implementationName"] = payload.get("implementationName", implementation)
    payload["tags"] = list(tag_ids or [])

    for field_name, value in field_values.items():
        set_field(payload, field_name, value)

    if existing:
        run_request("PUT", f"http://prowlarr:9696/prowlarr/api/v1/indexerproxy/{existing['id']}", api_key, payload)
        print(f"[bootstrap] Updated Prowlarr indexer proxy: {name}")
    else:
        created = request_json("POST", "http://prowlarr:9696/prowlarr/api/v1/indexerproxy", api_key, payload)
        existing_items.append(created)
        print(f"[bootstrap] Created Prowlarr indexer proxy: {name}")

def upsert_application(name: str, implementation: str, field_values: dict, api_key: str, schemas, existing_items):
    existing = next(
        (
            item for item in existing_items
            if item.get("implementation") == implementation or item.get("name") == name
        ),
        None,
    )

    payload = copy.deepcopy(existing) if existing else schema_for(schemas, implementation)
    payload["name"] = name
    payload["implementation"] = implementation
    payload["implementationName"] = payload.get("implementationName", implementation)
    payload["enable"] = True
    payload["syncLevel"] = payload.get("syncLevel", "fullSync")
    payload.setdefault("tags", [])

    for field_name, value in field_values.items():
        set_field(payload, field_name, value)

    if existing:
        run_request("PUT", f"http://prowlarr:9696/prowlarr/api/v1/applications/{existing['id']}", api_key, payload)
        print(f"[bootstrap] Updated Prowlarr application: {name}")
    else:
        created = request_json("POST", "http://prowlarr:9696/prowlarr/api/v1/applications", api_key, payload)
        existing_items.append(created)
        print(f"[bootstrap] Created Prowlarr application: {name}")

prowlarr_api_key = extract_xml_api_key(root_dir / "prowlarr" / "data" / "config.xml")
sonarr_api_key = extract_xml_api_key(root_dir / "sonarr" / "data" / "config.xml")
radarr_api_key = extract_xml_api_key(root_dir / "radarr" / "data" / "config.xml")

indexer_proxy_schemas = wait_for_json("http://prowlarr:9696/prowlarr/api/v1/indexerproxy/schema", prowlarr_api_key)
application_schemas = wait_for_json("http://prowlarr:9696/prowlarr/api/v1/applications/schema", prowlarr_api_key)
indexer_proxies = wait_for_json("http://prowlarr:9696/prowlarr/api/v1/indexerproxy", prowlarr_api_key)
applications = wait_for_json("http://prowlarr:9696/prowlarr/api/v1/applications", prowlarr_api_key)

proxy_tag_id = ensure_tag("proxy", prowlarr_api_key)

upsert_indexer_proxy(
    name="Byparr",
    implementation="FlareSolverr",
    field_values={
        "host": "http://byparr:8191/",
        "requestTimeout": 60,
    },
    api_key=prowlarr_api_key,
    schemas=indexer_proxy_schemas,
    existing_items=indexer_proxies,
    tag_ids=[proxy_tag_id],
)

upsert_application(
    name="Sonarr",
    implementation="Sonarr",
    field_values={
        "prowlarrUrl": "http://prowlarr:9696/prowlarr",
        "baseUrl": "http://sonarr:8989/sonarr",
        "apiKey": sonarr_api_key,
    },
    api_key=prowlarr_api_key,
    schemas=application_schemas,
    existing_items=applications,
)

upsert_application(
    name="Radarr",
    implementation="Radarr",
    field_values={
        "prowlarrUrl": "http://prowlarr:9696/prowlarr",
        "baseUrl": "http://radarr:7878/radarr",
        "apiKey": radarr_api_key,
    },
    api_key=prowlarr_api_key,
    schemas=application_schemas,
    existing_items=applications,
)
PY
}

extract_xml_key() {
  local file="$1"
  python3 - "${file}" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(r"<ApiKey>([^<]+)</ApiKey>", text)
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
}

extract_bazarr_key() {
  local file="$1"
  python3 - "${file}" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(r"^  apikey: (.+)$", text, re.MULTILINE)
if not match:
    raise SystemExit(1)
print(match.group(1).strip())
PY
}

install_duckdns_updater() {
  local updater marker entry current

  updater="${ROOT_DIR}/scripts/duckdns-update.sh"
  if [ ! -x "${updater}" ]; then
    chmod +x "${updater}"
  fi

  if [ -z "${DUCKDNS_TOKEN:-}" ]; then
    log "Skipping DuckDNS updater install (DUCKDNS_TOKEN not set)"
    # Still remove any stale cron entry from a prior install.
    current="$(crontab -l 2>/dev/null || true)"
    if printf '%s\n' "${current}" | grep -qF '# arr-server-duckdns'; then
      printf '%s\n' "${current}" | grep -vF '# arr-server-duckdns' | crontab -
      log "Removed stale DuckDNS cron entry"
    fi
    return 0
  fi

  # Run once immediately so the AAAA record is refreshed on every deploy.
  if "${updater}"; then
    log "Pushed current IPv6 to DuckDNS"
  else
    log "Initial DuckDNS update failed (cron will retry)"
  fi

  marker="# arr-server-duckdns"
  entry="*/5 * * * * ${updater} 2>&1 | logger -t duckdns ${marker}"

  current="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "${current}" | grep -qF "${entry}"; then
    log "DuckDNS cron entry already present"
    return 0
  fi

  { printf '%s\n' "${current}" | grep -vF "${marker}"; printf '%s\n' "${entry}"; } | crontab -
  log "Installed DuckDNS updater cron (every 5 min, logs via journald tag=duckdns)"
}

sync_api_keys() {
  local prowlarr_key sonarr_key radarr_key bazarr_key

  prowlarr_key="$(extract_xml_key "${ROOT_DIR}/prowlarr/data/config.xml")"
  sonarr_key="$(extract_xml_key "${ROOT_DIR}/sonarr/data/config.xml")"
  radarr_key="$(extract_xml_key "${ROOT_DIR}/radarr/data/config.xml")"
  bazarr_key="$(extract_bazarr_key "${ROOT_DIR}/bazarr/data/config/config.yaml")"

  set_env_value "PROWLARR_API_KEY" "${prowlarr_key}"
  set_env_value "SONARR_API_KEY" "${sonarr_key}"
  set_env_value "RADARR_API_KEY" "${radarr_key}"
  set_env_value "BAZARR_API_KEY" "${bazarr_key}"

  export PROWLARR_API_KEY="${prowlarr_key}"
  export SONARR_API_KEY="${sonarr_key}"
  export RADARR_API_KEY="${radarr_key}"
  export BAZARR_API_KEY="${bazarr_key}"

  compose_cmd up -d --force-recreate homepage
}

main() {
  [ -f "${ENV_FILE}" ] || {
    printf '[bootstrap-error] Missing %s\n' "${ENV_FILE}" >&2
    exit 1
  }

  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a

  : "${QBITTORRENT_TRACKER_LIST_URL:=${DEFAULT_TRACKER_LIST_URL}}"

  write_qbittorrent_config
  mkdir -p \
    "${ROOT_DIR}/data/torrents/incomplete" \
    "${ROOT_DIR}/data/media/movies" \
    "${ROOT_DIR}/data/media/tv"

  # Match the ARR pattern: if WEBDAV_* are blank in .env, fall back to the
  # qBittorrent web-UI credentials so the user only has to manage one
  # "admin / master password" for the whole stack. Export so docker compose
  # picks them up for the webdav container's environment.
  WEBDAV_USERNAME="${WEBDAV_USERNAME:-${QBITTORRENT_WEBUI_USERNAME:-admin}}"
  WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-${QBITTORRENT_WEBUI_PASSWORD:-}}"
  export WEBDAV_USERNAME WEBDAV_PASSWORD

  log "Starting containers"
  compose_cmd up -d --remove-orphans

  log "Applying path-base configuration"
  set_arr_base_urls

  log "Configuring ARR forms auth"
  set_arr_forms_auth

  log "Linking Byparr, Sonarr, and Radarr in Prowlarr"
  configure_prowlarr_integrations

  log "Syncing generated API keys back into .env"
  sync_api_keys

  log "Installing DuckDNS auto-updater"
  install_duckdns_updater

  # rsync --inplace (see deploy.sh) keeps the Caddyfile inode stable so the
  # container's bind mount stays live across deploys, but Caddy still needs
  # to be told to re-read the file. Ignore the reload error if caddy happens
  # to be absent or restarting — the config is validated by the image at
  # next container start regardless.
  log "Reloading Caddy configuration"
  if docker_cmd ps --format '{{.Names}}' | grep -qx 'arr-server-caddy-1'; then
    docker_cmd exec arr-server-caddy-1 caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
      || log "Caddy reload skipped (container not ready)"
  fi

  log "Bootstrap complete"
}

main "$@"
