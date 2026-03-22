#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${ROOT_DIR}/.arr-server"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"

MASTER_USERNAME="admin"
TRACKER_LIST_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"

info() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

run_root() {
  if [ "${EUID}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

compose_cmd() {
  docker_cmd compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local secret="${3:-0}"
  local value
  local interactive_tty=0

  if [ -t 0 ]; then
    interactive_tty=1
  fi

  while true; do
    if [ "${secret}" = "1" ] && [ "${interactive_tty}" = "1" ]; then
      if [ -n "${default_value}" ]; then
        printf '%s [%s]: ' "${label}" "${default_value}" >&2
      else
        printf '%s: ' "${label}" >&2
      fi
      stty -echo
      IFS= read -r value
      stty echo
      printf '\n' >&2
    else
      if [ -n "${default_value}" ]; then
        printf '%s [%s]: ' "${label}" "${default_value}" >&2
      else
        printf '%s: ' "${label}" >&2
      fi
      IFS= read -r value
    fi

    if [ -z "${value}" ]; then
      value="${default_value}"
    fi

    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
  done
}

prompt_password() {
  local label="$1"
  local first
  local second
  local interactive_tty=0

  if [ -t 0 ]; then
    interactive_tty=1
  fi

  while true; do
    printf '%s: ' "${label}" >&2
    if [ "${interactive_tty}" = "1" ]; then
      stty -echo
    fi
    IFS= read -r first
    if [ "${interactive_tty}" = "1" ]; then
      stty echo
    fi
    printf '\n' >&2

    printf 'Confirm %s: ' "${label}" >&2
    if [ "${interactive_tty}" = "1" ]; then
      stty -echo
    fi
    IFS= read -r second
    if [ "${interactive_tty}" = "1" ]; then
      stty echo
    fi
    printf '\n' >&2

    if [ -z "${first}" ]; then
      warn "Password cannot be empty."
      continue
    fi

    if [ "${first}" != "${second}" ]; then
      warn "Passwords did not match. Please try again."
      continue
    fi

    printf '%s' "${first}"
    return 0
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_timezone() {
  if [ -f /etc/timezone ]; then
    cat /etc/timezone
    return 0
  fi

  timedatectl show --property=Timezone --value 2>/dev/null || printf 'UTC'
}

random_secret() {
  openssl rand -hex 32
}

escape_env_value() {
  printf '%s' "$1" | sed 's/\$/$$/g'
}

ensure_prerequisites() {
  info "Installing prerequisites if needed."

  if ! command_exists sudo && [ "${EUID}" -ne 0 ]; then
    die "sudo is required for installation."
  fi

  if command_exists apt-get; then
    run_root apt-get update -y
    run_root apt-get install -y ca-certificates curl git openssl python3 python3-venv jq
  else
    die "This installer currently supports apt-based Raspberry Pi / Debian systems only."
  fi

  if ! command_exists docker; then
    info "Installing Docker via the official convenience script."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    run_root sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  fi

  run_root systemctl enable --now docker

  if ! id -nG "${USER}" | grep -qw docker; then
    info "Adding ${USER} to the docker group."
    run_root usermod -aG docker "${USER}"
    warn "You were added to the docker group. The installer will continue by using sudo for Docker commands in this session."
  fi

  docker_cmd version >/dev/null
  docker_cmd compose version >/dev/null
}

check_ipv6() {
  info "Checking public IPv6 connectivity."
  local public_ipv6
  public_ipv6="$(curl -fs6 --max-time 15 https://api64.ipify.org || true)"

  if [ -z "${public_ipv6}" ]; then
    die "No working public IPv6 connectivity was detected. This stack expects an IPv6-reachable Pi."
  fi

  info "Detected public IPv6: ${public_ipv6}"
}

hash_qbittorrent_password() {
  local password="$1"
  PASSWORD_INPUT="${password}" python3 - <<'PY'
import base64
import hashlib
import os
import sys

password = os.environ["PASSWORD_INPUT"].encode()
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac("sha512", password, salt, 100000)
print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})')
PY
}

hash_portainer_password() {
  local password="$1"
  docker_cmd run --rm httpd:2.4-alpine htpasswd -nbB admin "${password}" | cut -d ':' -f 2
}

write_env_file() {
  local duck_subdomain="$1"
  local duck_domain="$2"
  local duck_token="$3"
  local caddy_email="$4"
  local timezone_value="$5"
  local portainer_hash="$6"
  local escaped_duck_token
  local escaped_caddy_email
  local escaped_master_password
  local escaped_portainer_hash

  escaped_duck_token="$(escape_env_value "${duck_token}")"
  escaped_caddy_email="$(escape_env_value "${caddy_email}")"
  escaped_master_password="$(escape_env_value "${MASTER_PASSWORD_VALUE}")"
  escaped_portainer_hash="$(escape_env_value "${portainer_hash}")"

  cat > "${ENV_FILE}" <<EOF
PUID=$(id -u)
PGID=$(id -g)
TZ=${timezone_value}
UMASK=002

DUCKDNS_SUBDOMAIN=${duck_subdomain}
DUCKDNS_DOMAIN=${duck_domain}
DUCKDNS_TOKEN=${escaped_duck_token}
DUCKDNS_UPDATE_INTERVAL=300

CADDY_EMAIL=${escaped_caddy_email}

MASTER_USERNAME=${MASTER_USERNAME}
MASTER_PASSWORD=${escaped_master_password}

QBITTORRENT_WEBUI_PORT=8080
QBITTORRENT_TORRENT_PORT=6881
QBITTORRENT_TRACKER_LIST_URL=${TRACKER_LIST_URL}

PORTAINER_ADMIN_PASSWORD_HASH=${escaped_portainer_hash}
PROWLARR_API_KEY=
SONARR_API_KEY=
RADARR_API_KEY=
BAZARR_API_KEY=
EOF
}

write_duckdns_updater() {
  cat > "${STACK_DIR}/scripts/duckdns-update.sh" <<'EOF'
#!/bin/sh
set -eu

log_file="/logs/duckdns-updater.log"
mkdir -p /logs

while true; do
  ipv6="$(curl -fs6 --max-time 15 https://api64.ipify.org || true)"

  if [ -n "${ipv6}" ]; then
    response="$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${ipv6}&clear=true" || true)"
    printf '%s update=%s ipv6=%s response=%s\n' "$(date -Iseconds)" "${DUCKDNS_SUBDOMAIN}" "${ipv6}" "${response}" >> "${log_file}"
  else
    printf '%s update=%s ipv6=unavailable\n' "$(date -Iseconds)" "${DUCKDNS_SUBDOMAIN}" >> "${log_file}"
  fi

  sleep "${DUCKDNS_UPDATE_INTERVAL:-300}"
done
EOF

  chmod +x "${STACK_DIR}/scripts/duckdns-update.sh"
}

write_unbound_files() {
  cat > "${STACK_DIR}/configs/unbound/Dockerfile" <<'EOF'
FROM alpine:3.20

RUN apk add --no-cache ca-certificates unbound && update-ca-certificates

CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
EOF

  cat > "${STACK_DIR}/configs/unbound/unbound.conf" <<'EOF'
server:
  interface: 0.0.0.0
  interface: ::0
  port: 53
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes
  access-control: 0.0.0.0/0 allow
  access-control: ::0/0 allow
  hide-identity: yes
  hide-version: yes
  verbosity: 1
  logfile: "/var/log/unbound/unbound.log"
  use-syslog: no
  prefetch: yes
  rrset-roundrobin: yes
  tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

forward-zone:
  name: "."
  forward-tls-upstream: yes
  forward-addr: 1.1.1.1@853#cloudflare-dns.com
  forward-addr: 1.0.0.1@853#cloudflare-dns.com
  forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
  forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
EOF
}

write_caddyfile() {
  cat > "${STACK_DIR}/configs/caddy/Caddyfile" <<EOF
{
	admin off
$(if [ -n "${CADDY_EMAIL_VALUE}" ]; then printf '\temail %s\n' "${CADDY_EMAIL_VALUE}"; fi)
}

{\$DUCKDNS_DOMAIN} {
	encode zstd gzip

	log {
		output file /var/log/caddy/access.log {
			roll_size 10MiB
			roll_keep 10
			roll_keep_for 720h
		}
		format json
	}

	redir /portainer /portainer/ 308
	handle_path /portainer/* {
		reverse_proxy portainer:9000
	}

	redir /qbittorrent /qbittorrent/ 308
	handle_path /qbittorrent/* {
		reverse_proxy qbittorrent:8080 {
			header_up Host qbittorrent:8080
			header_up Origin http://qbittorrent:8080
			header_up Referer http://qbittorrent:8080
			header_up X-Forwarded-Host {host}
			header_up X-Forwarded-Proto {scheme}
		}
	}

	@prowlarr path /prowlarr /prowlarr/*
	handle @prowlarr {
		reverse_proxy prowlarr:9696
	}

	@sonarr path /sonarr /sonarr/*
	handle @sonarr {
		reverse_proxy sonarr:8989
	}

	@radarr path /radarr /radarr/*
	handle @radarr {
		reverse_proxy radarr:7878
	}

	@bazarr path /bazarr /bazarr/*
	handle @bazarr {
		reverse_proxy bazarr:6767
	}

	@webdav path /webdav /webdav/*
	handle @webdav {
		reverse_proxy webdav:5000
	}

	handle {
		reverse_proxy homepage:3000
	}
}
EOF
}

write_homepage_files() {
  cat > "${STACK_DIR}/configs/homepage/settings.yaml" <<'EOF'
title: ARR Server
description: Media, automation, and infrastructure dashboard
headerStyle: clean
layout:
  Infrastructure:
    style: row
    columns: 3
  Media:
    style: row
    columns: 4
EOF

  cat > "${STACK_DIR}/configs/homepage/services.yaml" <<'EOF'
- Infrastructure:
    - Homepage:
        icon: homepage.png
        href: /
        description: Main dashboard
        siteMonitor: http://homepage:3000
    - Portainer:
        icon: portainer.png
        href: /portainer/
        description: Container manager
        container: portainer
    - WebDAV:
        icon: filebrowser.png
        href: /webdav/
        description: Media browser
        container: webdav
        ping: http://webdav:5000/webdav/

- Media:
    - qBittorrent:
        icon: qbittorrent.png
        href: /qbittorrent/
        description: Torrent client
        container: qbittorrent
        widget:
          type: qbittorrent
          url: http://qbittorrent:8080
          username: "{{HOMEPAGE_VAR_MASTER_USERNAME}}"
          password: "{{HOMEPAGE_VAR_MASTER_PASSWORD}}"
    - Prowlarr:
        icon: prowlarr.png
        href: /prowlarr/
        description: Indexer manager
        container: prowlarr
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_API_KEY}}"
    - Sonarr:
        icon: sonarr.png
        href: /sonarr/
        description: TV manager
        container: sonarr
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: "{{HOMEPAGE_VAR_SONARR_API_KEY}}"
    - Radarr:
        icon: radarr.png
        href: /radarr/
        description: Movie manager
        container: radarr
        widget:
          type: radarr
          url: http://radarr:7878
          key: "{{HOMEPAGE_VAR_RADARR_API_KEY}}"
    - Bazarr:
        icon: bazarr.png
        href: /bazarr/
        description: Subtitle manager
        container: bazarr
        widget:
          type: bazarr
          url: http://bazarr:6767
          key: "{{HOMEPAGE_VAR_BAZARR_API_KEY}}"
    - FlareSolverr:
        icon: flaresolverr.png
        description: Cloudflare challenge solver
        container: flaresolverr
        ping: http://flaresolverr:8191/
EOF

  cat > "${STACK_DIR}/configs/homepage/widgets.yaml" <<'EOF'
- resources:
    cpu: true
    memory: true
    disk: /
EOF

  cat > "${STACK_DIR}/configs/homepage/docker.yaml" <<'EOF'
- arr-server:
    socket: /var/run/docker.sock
EOF

  cat > "${STACK_DIR}/configs/homepage/custom.css" <<'EOF'
footer {
  display: none !important;
}
EOF
}

write_qbittorrent_config() {
  local password_hash="$1"

  cat > "${STACK_DIR}/configs/qbittorrent/qBittorrent/qBittorrent.conf" <<EOF
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
Session\\AdditionalTrackersURL=${TRACKER_LIST_URL}
Session\\DefaultSavePath=/data/torrents/
Session\\Encryption=1
Session\\Port=6881
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
Connection\\PortRangeMin=6881
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
WebUI\\Port=8080
WebUI\\SecureCookie=true
WebUI\\ServerDomains=*
WebUI\\Username=${MASTER_USERNAME}

[RSS]
AutoDownloader\\DownloadRepacks=true
EOF
}

write_compose_file() {
  cat > "${COMPOSE_FILE}" <<'EOF'
name: arr-server

x-common-environment: &common-environment
  PUID: ${PUID}
  PGID: ${PGID}
  TZ: ${TZ}
  UMASK: ${UMASK}

x-common-logging: &common-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

x-common-dns: &common-dns
  dns:
    - 172.28.0.53
    - fd42:4242:4242::53

x-common-network: &common-network
  arr_net: {}

services:
  caddy:
    image: caddy:2.8-alpine
    container_name: caddy
    restart: unless-stopped
    depends_on:
      - homepage
      - portainer
      - qbittorrent
      - prowlarr
      - sonarr
      - radarr
      - bazarr
      - webdav
    environment:
      DUCKDNS_DOMAIN: ${DUCKDNS_DOMAIN}
      CADDY_EMAIL: ${CADDY_EMAIL}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./configs/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./configs/caddy/data:/data
      - ./configs/caddy/config:/config
      - ./logs/caddy:/var/log/caddy
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  unbound:
    build:
      context: ./configs/unbound
      dockerfile: Dockerfile
    container_name: unbound
    restart: unless-stopped
    volumes:
      - ./configs/unbound/unbound.conf:/etc/unbound/unbound.conf:ro
      - ./logs/unbound:/var/log/unbound
    logging: *common-logging
    networks:
      arr_net:
        ipv4_address: 172.28.0.53
        ipv6_address: fd42:4242:4242::53

  duckdns-updater:
    image: curlimages/curl:8.12.1
    container_name: duckdns-updater
    restart: unless-stopped
    user: "0:0"
    depends_on:
      - unbound
    entrypoint: ["/bin/sh", "/scripts/duckdns-update.sh"]
    environment:
      DUCKDNS_SUBDOMAIN: ${DUCKDNS_SUBDOMAIN}
      DUCKDNS_TOKEN: ${DUCKDNS_TOKEN}
      DUCKDNS_UPDATE_INTERVAL: ${DUCKDNS_UPDATE_INTERVAL}
      TZ: ${TZ}
    volumes:
      - ./scripts/duckdns-update.sh:/scripts/duckdns-update.sh:ro
      - ./logs/duckdns-updater:/logs
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    depends_on:
      - portainer
      - qbittorrent
      - prowlarr
      - sonarr
      - radarr
      - bazarr
      - webdav
    environment:
      HOMEPAGE_ALLOWED_HOSTS: ${DUCKDNS_DOMAIN}
      HOMEPAGE_VAR_MASTER_USERNAME: ${MASTER_USERNAME}
      HOMEPAGE_VAR_MASTER_PASSWORD: ${MASTER_PASSWORD}
      HOMEPAGE_VAR_PROWLARR_API_KEY: ${PROWLARR_API_KEY}
      HOMEPAGE_VAR_SONARR_API_KEY: ${SONARR_API_KEY}
      HOMEPAGE_VAR_RADARR_API_KEY: ${RADARR_API_KEY}
      HOMEPAGE_VAR_BAZARR_API_KEY: ${BAZARR_API_KEY}
    volumes:
      - ./configs/homepage:/app/config
      - ./logs/homepage:/app/config/logs
      - /var/run/docker.sock:/var/run/docker.sock:ro
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    command:
      - --http-enabled
      - --admin-password
      - ${PORTAINER_ADMIN_PASSWORD_HASH}
    volumes:
      - ./configs/portainer:/data
      - /var/run/docker.sock:/var/run/docker.sock
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      <<: *common-environment
      WEBUI_PORT: ${QBITTORRENT_WEBUI_PORT}
      TORRENTING_PORT: ${QBITTORRENT_TORRENT_PORT}
    ports:
      - "${QBITTORRENT_TORRENT_PORT}:${QBITTORRENT_TORRENT_PORT}"
      - "${QBITTORRENT_TORRENT_PORT}:${QBITTORRENT_TORRENT_PORT}/udp"
    volumes:
      - ./configs/qbittorrent:/config
      - ./logs/qbittorrent:/config/qBittorrent/logs
      - ./data:/data
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment:
      <<: *common-environment
    volumes:
      - ./configs/prowlarr:/config
      - ./logs/prowlarr:/config/logs
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      <<: *common-environment
    volumes:
      - ./configs/sonarr:/config
      - ./logs/sonarr:/config/logs
      - ./data:/data
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      <<: *common-environment
    volumes:
      - ./configs/radarr:/config
      - ./logs/radarr:/config/logs
      - ./data:/data
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    environment:
      <<: *common-environment
    volumes:
      - ./configs/bazarr:/config
      - ./logs/bazarr:/config/logs
      - ./data:/data
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    restart: unless-stopped
    environment:
      LOG_LEVEL: info
      TZ: ${TZ}
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

  webdav:
    image: sigoden/dufs:latest
    container_name: webdav
    restart: unless-stopped
    command:
      - /data
      - -p
      - "5000"
      - -a
      - ${MASTER_USERNAME}:${MASTER_PASSWORD}@/:rw
      - --allow-search
      - --path-prefix
      - /webdav
    volumes:
      - ./data/media:/data
      - ./logs/webdav:/logs
    logging: *common-logging
    <<: *common-dns
    networks: *common-network

networks:
  arr_net:
    name: arr_net
    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.28.0.0/24
        - subnet: fd42:4242:4242::/64
EOF
}

prepare_directories() {
  mkdir -p \
    "${STACK_DIR}/configs/caddy/data" \
    "${STACK_DIR}/configs/caddy/config" \
    "${STACK_DIR}/configs/homepage" \
    "${STACK_DIR}/configs/portainer" \
    "${STACK_DIR}/configs/qbittorrent/qBittorrent" \
    "${STACK_DIR}/configs/prowlarr" \
    "${STACK_DIR}/configs/sonarr" \
    "${STACK_DIR}/configs/radarr" \
    "${STACK_DIR}/configs/bazarr/config" \
    "${STACK_DIR}/configs/unbound" \
    "${STACK_DIR}/logs/caddy" \
    "${STACK_DIR}/logs/unbound" \
    "${STACK_DIR}/logs/homepage" \
    "${STACK_DIR}/logs/qbittorrent" \
    "${STACK_DIR}/logs/prowlarr" \
    "${STACK_DIR}/logs/sonarr" \
    "${STACK_DIR}/logs/radarr" \
    "${STACK_DIR}/logs/bazarr" \
    "${STACK_DIR}/logs/webdav" \
    "${STACK_DIR}/logs/duckdns-updater" \
    "${STACK_DIR}/logs/portainer" \
    "${STACK_DIR}/logs/flaresolverr" \
    "${STACK_DIR}/data/torrents/incomplete" \
    "${STACK_DIR}/data/media/movies" \
    "${STACK_DIR}/data/media/tv" \
    "${STACK_DIR}/scripts"
}

wait_for_file() {
  local file="$1"
  local timeout="${2:-180}"
  local elapsed=0

  until [ -f "${file}" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "${elapsed}" -ge "${timeout}" ]; then
      die "Timed out waiting for ${file}"
    fi
  done
}

set_arr_base_urls() {
  info "Configuring ARR base URLs."

  wait_for_file "${STACK_DIR}/configs/prowlarr/config.xml"
  wait_for_file "${STACK_DIR}/configs/sonarr/config.xml"
  wait_for_file "${STACK_DIR}/configs/radarr/config.xml"
  wait_for_file "${STACK_DIR}/configs/bazarr/config/config.yaml"

  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/prowlarr</UrlBase>|' "${STACK_DIR}/configs/prowlarr/config.xml"
  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/sonarr</UrlBase>|' "${STACK_DIR}/configs/sonarr/config.xml"
  sed -i 's|<UrlBase>.*</UrlBase>|<UrlBase>/radarr</UrlBase>|' "${STACK_DIR}/configs/radarr/config.xml"
  if grep -q '^  base_url:' "${STACK_DIR}/configs/bazarr/config/config.yaml"; then
    sed -i "s|^  base_url:.*$|  base_url: '/bazarr'|" "${STACK_DIR}/configs/bazarr/config/config.yaml"
  else
    printf "\ngeneral:\n  base_url: '/bazarr'\n" >> "${STACK_DIR}/configs/bazarr/config/config.yaml"
  fi

  compose_cmd restart prowlarr sonarr radarr bazarr
}

extract_xml_key() {
  sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" | head -n 1
}

extract_bazarr_key() {
  sed -n "/^auth:/,/^[^[:space:]]/ s/^[[:space:]]*apikey:[[:space:]]*//p" "$1" | head -n 1 | sed "s/'//g"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"

  awk -v key="${key}" -v value="${value}" '
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
  ' "${ENV_FILE}" > "${tmp_file}"

  mv "${tmp_file}" "${ENV_FILE}"
}

sync_api_keys() {
  info "Syncing ARR API keys into the generated .env file."

  local prowlarr_key
  local sonarr_key
  local radarr_key
  local bazarr_key

  prowlarr_key="$(extract_xml_key "${STACK_DIR}/configs/prowlarr/config.xml" || true)"
  sonarr_key="$(extract_xml_key "${STACK_DIR}/configs/sonarr/config.xml" || true)"
  radarr_key="$(extract_xml_key "${STACK_DIR}/configs/radarr/config.xml" || true)"
  bazarr_key="$(extract_bazarr_key "${STACK_DIR}/configs/bazarr/config/config.yaml" || true)"

  set_env_value "PROWLARR_API_KEY" "${prowlarr_key}"
  set_env_value "SONARR_API_KEY" "${sonarr_key}"
  set_env_value "RADARR_API_KEY" "${radarr_key}"
  set_env_value "BAZARR_API_KEY" "${bazarr_key}"

  compose_cmd up -d homepage
}

print_manual_steps() {
  cat <<EOF

Server setup is complete.

Public entrypoint:
  https://${DUCKDNS_DOMAIN_VALUE}/

Manual app-auth steps still required:
  1. Open https://${DUCKDNS_DOMAIN_VALUE}/prowlarr/ and configure its built-in login manually.
  2. Open https://${DUCKDNS_DOMAIN_VALUE}/sonarr/ and configure its built-in login manually.
  3. Open https://${DUCKDNS_DOMAIN_VALUE}/radarr/ and configure its built-in login manually.
  4. Open https://${DUCKDNS_DOMAIN_VALUE}/bazarr/ and configure its built-in login manually.

Already configured by this installer:
  - qBittorrent username: ${MASTER_USERNAME}
  - qBittorrent password: the master password you entered
  - qBittorrent tracker list: ${TRACKER_LIST_URL}
  - WebDAV username: ${MASTER_USERNAME}
  - WebDAV password: the master password you entered
  - Portainer admin username: ${MASTER_USERNAME}
  - Portainer admin password: the master password you entered

Generated runtime files live in:
  ${STACK_DIR}

To remove everything later, run:
  ./uninstall.sh
EOF
}

main() {
  info "ARR server bootstrap"
  info "This installer will generate the runtime stack under ${STACK_DIR}"

  ensure_prerequisites
  check_ipv6

  local timezone_default
  local duck_subdomain
  local duck_domain
  local duck_token
  local caddy_email
  local qbit_hash
  local portainer_hash

  timezone_default="$(detect_timezone)"

  duck_subdomain="$(prompt_value "DuckDNS subdomain" "")"
  duck_domain="${duck_subdomain}.duckdns.org"
  duck_token="$(prompt_value "DuckDNS token" "" 1)"
  caddy_email="$(prompt_value "Caddy email (optional)" "")"
  TZ_VALUE="$(prompt_value "Timezone" "${timezone_default}")"
  MASTER_PASSWORD_VALUE="$(prompt_password "Master password for admin")"

  if [ "${MASTER_PASSWORD_VALUE}" = "" ]; then
    die "Master password cannot be empty."
  fi

  if [ "${MASTER_PASSWORD_VALUE}" = "admin" ]; then
    warn "Using a trivial password is unsafe."
  fi

  DUCKDNS_DOMAIN_VALUE="${duck_domain}"
  CADDY_EMAIL_VALUE="${caddy_email}"

  info "Using public domain: ${DUCKDNS_DOMAIN_VALUE}"

  info "Preparing runtime directories."
  prepare_directories

  info "Generating qBittorrent and Portainer password hashes."
  qbit_hash="$(hash_qbittorrent_password "${MASTER_PASSWORD_VALUE}")"
  portainer_hash="$(hash_portainer_password "${MASTER_PASSWORD_VALUE}")"

  info "Writing stack configuration."
  write_env_file "${duck_subdomain}" "${duck_domain}" "${duck_token}" "${caddy_email}" "${TZ_VALUE}" "${portainer_hash}"
  write_duckdns_updater
  write_unbound_files
  write_caddyfile
  write_homepage_files
  write_qbittorrent_config "${qbit_hash}"
  write_compose_file

  info "Rendering docker compose config."
  compose_cmd config >/dev/null

  info "Starting the stack."
  compose_cmd up -d --build

  set_arr_base_urls
  sync_api_keys

  print_manual_steps
}

main "$@"
