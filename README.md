# ARR Server

Docker-native Raspberry Pi media stack for an IPv6-only home server. This repo is designed to be edited on your Mac, synced to the Pi over SSH, and deployed with a single `docker compose up -d` run on the Raspberry Pi.

The stack currently includes:

- Caddy for HTTPS reverse proxy
- Homepage as the landing dashboard
- qBittorrent
- Prowlarr
- Sonarr
- Radarr
- Bazarr
- Byparr (FlareSolverr-compatible indexer proxy, lighter on RAM)

Public entrypoint:

- `https://yourhost.duckdns.org/`

The app routes are path-based because DuckDNS gives you a single hostname:

- `https://yourhost.duckdns.org/`
- `https://yourhost.duckdns.org/qbittorrent/`
- `https://yourhost.duckdns.org/prowlarr/`
- `https://yourhost.duckdns.org/sonarr/`
- `https://yourhost.duckdns.org/radarr/`
- `https://yourhost.duckdns.org/bazarr/`

## Directory layout

```text
arr-server/
├── .env.example
├── .gitignore
├── README.md
├── deploy.sh
├── docker-compose.yml
├── bazarr/
│   └── data/
├── caddy/
│   ├── Caddyfile
│   ├── config/
│   └── data/
├── homepage/
│   └── config/
│       ├── bookmarks.yaml
│       ├── custom.css
│       ├── docker.yaml
│       ├── services.yaml
│       ├── settings.yaml
│       └── widgets.yaml
├── data/
│   ├── media/
│   │   ├── movies/
│   │   └── tv/
│   └── torrents/
├── prowlarr/
│   └── data/
├── qbittorrent/
│   └── config/
├── radarr/
│   └── data/
└── sonarr/
    └── data/
```

## Architecture

- `docker-compose.yml` is the single orchestration file.
- `.env` stores secrets, Pi deployment settings, and shared runtime values.
- Each app has its own bind-mount directory.
- App state is kept out of Git with `.gitignore`.
- `deploy.sh` runs from your Mac, syncs the repo to the Pi, deploys the stack remotely, verifies the containers are running, and only then commits and pushes to GitHub.

## One-time Raspberry Pi prerequisites

Install Docker and Compose on the Pi first if you have not already:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
docker compose version
```

Because the Pi is IPv6-only, enable IPv6 in Docker once on the Pi:

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "fd42:4242:4242::/64",
  "ip6tables": true
}
EOF
sudo systemctl restart docker
```

Your router also needs:

- IPv6 enabled end-to-end
- inbound TCP `80` and `443` allowed to the Pi for Let's Encrypt HTTP-01
- DuckDNS publishing the Pi's public `AAAA` record (the stack keeps this
  fresh automatically; see "DuckDNS auto-updater" below)

## First-time setup on your Mac

Clone the repo and prepare the environment file:

```bash
git clone https://github.com/athcodes2005/arr-server.git
cd arr-server
cp .env.example .env
chmod +x deploy.sh
```

Edit `.env` and fill in:

- `LETSENCRYPT_EMAIL`
- `PI_SSH_HOST`
- `PI_DEPLOY_PATH`
- `DUCKDNS_TOKEN` (from https://www.duckdns.org after signing in)
- qBittorrent credentials
- `ARR_AUTH_USERNAME` and `ARR_AUTH_PASSWORD` if you want Servarr auth to differ from qBittorrent
- Homepage API keys after first boot

Validate the compose file locally:

```bash
docker compose --env-file .env config
```

## Deploying from your Mac

Run:

```bash
./deploy.sh
```

The deploy flow is:

1. SSH to the Pi over IPv6
2. Sync the repo to `PI_DEPLOY_PATH` with `rsync`
3. Run `docker compose pull`
4. Run `docker compose up -d`
5. Check that every service container is running and not unhealthy
6. Commit and push the local repo only if the remote deployment succeeded

If deployment fails, the script stops before the Git push so you can debug safely.

## First boot tasks inside the apps

After the stack is up the first time, open the apps and finish the app-level configuration.

### qBittorrent

Set qBittorrent Web UI credentials so they match:

- `QBITTORRENT_WEBUI_USERNAME`
- `QBITTORRENT_WEBUI_PASSWORD`

The Homepage qBittorrent widget uses those values.

Recommended qBittorrent categories and paths:

- `radarr` -> `/data/torrents/radarr`
- `sonarr` -> `/data/torrents/sonarr`

### Prowlarr / Sonarr / Radarr / Bazarr

Set the public base URL in each app so path-based reverse proxying works:

- Prowlarr: `/prowlarr`
- Sonarr: `/sonarr`
- Radarr: `/radarr`
- Bazarr: `/bazarr`

Prowlarr, Sonarr, and Radarr forms auth is also bootstrapped automatically from `.env` during deploy:

- `ARR_AUTH_USERNAME`
- `ARR_AUTH_PASSWORD`

If those are left blank, the bootstrap falls back to:

- `QBITTORRENT_WEBUI_USERNAME`
- `QBITTORRENT_WEBUI_PASSWORD`

Then update Homepage widget API keys in `.env`:

- `PROWLARR_API_KEY`
- `SONARR_API_KEY`
- `RADARR_API_KEY`
- `BAZARR_API_KEY`

Deploy again with:

```bash
./deploy.sh
```

### Prowlarr integration

The bootstrap script wires these up automatically on every deploy:

- Byparr indexer proxy pointed at `http://byparr:8191/` (tagged `proxy`)
- Sonarr application at `http://sonarr:8989/sonarr`
- Radarr application at `http://radarr:7878/radarr`

### Routing indexers through Byparr

Some indexers fail direct HTTP requests from Prowlarr — either because they
are IPv6-only (which exposes a .NET HttpClient quirk on Alpine), or because
they sit behind Cloudflare. For those, add the `proxy` tag when configuring
the indexer in Prowlarr:

1. Prowlarr → Indexers → Add Indexer → pick the indexer
2. In the **Tags** field, select `proxy`
3. Save

Prowlarr will then route that indexer's traffic through Byparr. The `proxy`
tag is created automatically during deploy and attached to the Byparr
indexer proxy, so you only need to tag the indexer itself.

### Sonarr / Radarr media management

Use shared paths so imports and hardlinks work correctly:

- Sonarr root folder: `/data/media/tv`
- Radarr root folder: `/data/media/movies`
- qBittorrent downloads: `/data/torrents`

All four app containers mount the same `./data` directory as `/data`, which keeps paths consistent.

## DuckDNS auto-updater

ISPs rotate the IPv6 prefix on residential lines every so often. When that
happens the Pi gets a new public IPv6 and the DuckDNS `AAAA` record goes
stale, breaking SSH and HTTPS from the outside.

`scripts/duckdns-update.sh` pushes the Pi's current global IPv6 to DuckDNS.
`scripts/bootstrap-remote.sh` installs it as a cron job during every deploy:

- runs every 5 minutes
- reads `DOMAIN` and `DUCKDNS_TOKEN` from `.env`
- picks the first non-ULA global IPv6 on `eth0` (override with `DUCKDNS_IFACE`)
- logs to journald with tag `duckdns`

Tail updater logs on the Pi:

```bash
ssh -6 youruser@yourhost.duckdns.org "journalctl -t duckdns -n 20 --no-pager"
```

If `DUCKDNS_TOKEN` is left blank the updater is skipped and any previously
installed cron entry is removed.

## Useful commands

Deploy:

```bash
./deploy.sh
```

Check services on the Pi:

```bash
ssh -6 youruser@yourhost.duckdns.org "cd /home/youruser/arr-server && docker compose ps"
```

Tail logs on the Pi:

```bash
ssh -6 youruser@yourhost.duckdns.org "cd /home/youruser/arr-server && docker compose logs -f caddy homepage"
```
