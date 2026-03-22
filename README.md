# ARR Server

Docker Compose project for the Raspberry Pi ARR stack, prepared on macOS but intended to be run later on the Pi.

## What Changed From The Previous Project

- Replaced ad-hoc `docker run` commands with a single `compose.yaml`.
- Replaced manual TXT-record certbot flow with `Caddy` and automatic `HTTP-01`.
- Kept `DuckDNS` for dynamic DNS updates.
- Added a dedicated `Unbound` container so the stack has one internal DNS resolver.
- Switched the stack network to a Compose-managed IPv4 + IPv6 network.
- Standardized repo-local folders for config, logs, and media data.

## Important Constraint

Do not start this stack on the Mac.

This repository is intentionally being prepared locally and should only be cloned, started, and debugged on the Raspberry Pi once SSH access is available.

## Project Layout

```text
.
├── compose.yaml
├── .env.example
├── configs/
├── data/
├── logs/
└── scripts/
```

- `configs/`: bind-mounted config for each service
- `data/`: torrents and media paths shared across ARR apps
- `logs/`: app and proxy log files
- `scripts/`: helper scripts used by containers or Pi-side operations
- `pi-prequisites.md`: Raspberry Pi server prep checklist

## Services

- `caddy`: reverse proxy and automatic HTTPS
- `unbound`: internal DNS resolver for the stack
- `duckdns-updater`: updates the DuckDNS record with the Pi's public IPv6
- `homepage`: root dashboard
- `portainer`: container management UI
- `qbittorrent`: torrent client
- `prowlarr`: indexer manager
- `sonarr`: TV automation
- `radarr`: movie automation
- `bazarr`: subtitles
- `flaresolverr`: Cloudflare challenge solver
- `webdav`: file browsing and streaming

## Public URL Layout

Homepage is the root route:

- `https://<your-duckdns-domain>/`

Services are exposed under path prefixes:

- `https://<your-duckdns-domain>/portainer/`
- `https://<your-duckdns-domain>/qbittorrent/`
- `https://<your-duckdns-domain>/prowlarr/`
- `https://<your-duckdns-domain>/sonarr/`
- `https://<your-duckdns-domain>/radarr/`
- `https://<your-duckdns-domain>/bazarr/`
- `https://<your-duckdns-domain>/webdav/`

Homepage tiles point at these same paths.

## Prerequisites On The Raspberry Pi

Before deployment on the Pi:

1. Install Docker Engine and Docker Compose plugin.
2. Ensure the Pi has working IPv6 connectivity.
3. Forward ports `80` and `443` from the router to the Pi.
4. Make sure local firewalls allow inbound `80/tcp` and `443/tcp`.
5. Clone this repo onto the Pi.
6. Copy `.env.example` to `.env` and fill in the real values.

`HTTP-01` only works if Let's Encrypt can reach the Pi on port `80`.

## Environment Variables

Edit `.env` before deployment.

Required values:

- `DUCKDNS_SUBDOMAIN`
- `DUCKDNS_DOMAIN`
- `DUCKDNS_TOKEN`
- `QBITTORRENT_PASSWORD`
- `WEBDAV_PASSWORD`

Optional values you can fill later after the first boot:

- `PORTAINER_API_KEY`
- `PROWLARR_API_KEY`
- `SONARR_API_KEY`
- `RADARR_API_KEY`
- `BAZARR_API_KEY`

These optional API keys are only used by Homepage widgets.

## Networking Design

The stack uses one shared Docker network named `arr_net`.

- IPv4 subnet: `172.28.0.0/24`
- IPv6 subnet: `fd42:4242:4242::/64`
- Unbound static IP: `172.28.0.53`
- Unbound static IPv6: `fd42:4242:4242::53`

All application containers use Unbound as their DNS server.

This keeps DNS resolution centralized and allows the stack to use IPv6-capable upstream connectivity when the Pi has it.

The Unbound service is built from the repo so it stays portable across Raspberry Pi architectures.

## Logging

Logs are organized under `logs/`.

- `logs/caddy/`: reverse proxy access logs
- `logs/unbound/`: DNS resolver logs
- `logs/qbittorrent/`: qBittorrent internal logs
- `logs/prowlarr/`, `logs/sonarr/`, `logs/radarr/`, `logs/bazarr/`: ARR app logs
- `logs/duckdns-updater/`: DuckDNS updater loop log

Docker JSON logs are also rotated with per-container limits so runaway stdout logging is capped.

## App Compatibility Notes

Path-prefix routing is more fragile than subdomains, so a few apps need special handling.

- `qBittorrent` is proxied with upstream header overrides.
- `webdav` is started with `--path-prefix /webdav`.
- `portainer` is started with `--base-url /portainer`.

The ARR apps also need their own base URLs set after first boot on the Pi:

- Prowlarr: `/prowlarr`
- Sonarr: `/sonarr`
- Radarr: `/radarr`
- Bazarr: `/bazarr`

These values are usually set from each app's web UI after its first startup because the exact config files are version-sensitive.

qBittorrent also needs its final Web UI credentials set after first boot.
Use the password shown by qBittorrent on its first launch, then change it in the qBittorrent UI and keep `.env` in sync so the Homepage widget can authenticate.

## DuckDNS Behavior

The project keeps DuckDNS for dynamic DNS only.

- `duckdns-updater` updates the DuckDNS record every 5 minutes
- it only pushes the current public IPv6 address
- certificate issuance is handled by Caddy over `HTTP-01`

There is no TXT-record challenge workflow in this repository.

## Bring Up On The Pi Later

After the repo is cloned on the Pi and `.env` is filled:

```bash
docker compose pull
docker compose up -d
```

## Validation Checklist On The Pi

After deployment:

1. `docker compose ps`
2. Confirm DuckDNS resolves to the Pi's current public IP.
3. Confirm `https://<your-duckdns-domain>/` loads Homepage.
4. Confirm each service path opens correctly through Caddy.
5. Set ARR app base URLs in their UIs.
6. Add Homepage API keys if you want widgets populated.
7. Confirm Unbound resolves external domains from another container.
8. Confirm Caddy obtained certificates successfully.

## Static Validation On The Mac

This repo can be validated locally without starting containers:

```bash
docker compose --env-file .env.example config
```

That checks the Compose rendering only. Do not run `docker compose up` on the Mac.
