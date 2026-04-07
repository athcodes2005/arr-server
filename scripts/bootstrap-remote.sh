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

  log "Starting containers"
  compose_cmd up -d

  log "Applying path-base configuration"
  set_arr_base_urls

  log "Configuring ARR forms auth"
  set_arr_forms_auth

  log "Syncing generated API keys back into .env"
  sync_api_keys

  log "Bootstrap complete"
}

main "$@"
