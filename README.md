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
- Jellyfin (media server with native Infuse / Kodi / browser support)

Public entrypoint:

- `https://yourhost.duckdns.org/`

The app routes are path-based because DuckDNS gives you a single hostname:

- `https://yourhost.duckdns.org/`
- `https://yourhost.duckdns.org/qbittorrent/`
- `https://yourhost.duckdns.org/prowlarr/`
- `https://yourhost.duckdns.org/sonarr/`
- `https://yourhost.duckdns.org/radarr/`
- `https://yourhost.duckdns.org/bazarr/`
- `https://yourhost.duckdns.org/jellyfin/`

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
├── jellyfin/
│   └── config/
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
- `WEBDAV_USERNAME` and `WEBDAV_PASSWORD` for the read-only media share
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
- `JELLYFIN_API_KEY` (see Jellyfin section below)

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

## Unattended security upgrades

`scripts/install-unattended-upgrades.sh` is run by `bootstrap-remote.sh` on
every deploy. It configures the Pi to apply OS security patches and stable
kernel updates without manual intervention:

- Allowed sources: Debian `stable-security`, Debian `stable-updates`, and the
  Raspberry Pi Foundation `stable` channel only. Bleeding-edge `rpi-update`
  GitHub kernel builds are never pulled.
- Schedule (avoids the 03:00 home-router reboot window):
  - `04:00 ± 15 min` — `apt-daily` refreshes package lists
  - `04:30 ± 10 min` — `apt-daily-upgrade` applies updates
  - `05:00`           — automatic reboot if a kernel/libc/dbus update needs one
- Third-party repos (Docker CE, etc.) are NOT auto-upgraded; you stay in
  control of those via manual `apt upgrade`.

Inspect what would apply on the next run:

```bash
ssh -6 youruser@yourhost.duckdns.org \
  "sudo unattended-upgrade --dry-run -d 2>&1 | grep 'pkgs that look'"
```

History of what was applied while you were away:

```bash
ssh -6 youruser@yourhost.duckdns.org \
  "sudo journalctl -u unattended-upgrades --since '7 days ago' --no-pager"
```

## Jellyfin media server

Jellyfin is available at:

- `https://yourhost.duckdns.org/jellyfin/`

It reads the same `./data/media` tree that Sonarr and Radarr manage, mounted
read-only. Jellyfin handles its own authentication and serves metadata, posters,
and subtitles automatically.

### First boot setup

1. Open `https://yourhost.duckdns.org/jellyfin/` and complete the setup wizard.
2. **Set the base URL** so path-based proxying works:
   - Dashboard → Networking → Base URL → `/jellyfin`
   - Save and restart Jellyfin when prompted.
3. **Add media libraries** during setup (or after via Dashboard → Libraries):
   - Movies → `/data/media/movies`
   - TV Shows → `/data/media/tv`
4. **Copy the API key** for the Homepage widget:
   - Dashboard → API Keys → + → name it `homepage`
   - Add `JELLYFIN_API_KEY=<key>` to `.env` and redeploy.

### Connecting Infuse

Infuse has native Jellyfin support — no WebDAV needed:

1. Infuse → Settings → Add Library → Jellyfin (or Emby)
2. Host: `yourhost.duckdns.org`
3. Port: `443`, Path: `/jellyfin`
4. Sign in with your Jellyfin username and password

Infuse will pull metadata, posters, and watched state directly from Jellyfin
and use direct play for content that fits within your upload bandwidth.

### Connecting Kodi

- Add-ons → Jellyfin for Kodi → configure with `https://yourhost.duckdns.org/jellyfin`

### Browser

Full web player available at `https://yourhost.duckdns.org/jellyfin/`.

## Security hardening (manual steps on the Pi)

The following items cannot be fixed via this repo's deploy scripts — they
require direct SSH access to the Pi with root privileges.

### SSH password authentication (MEDIUM — accepted risk)

Port 22 is publicly reachable from the internet. Password authentication is
intentionally kept enabled as a backup login method. UFW already limits the
attack surface to only the ports the stack needs (22, 80, 443, the torrent
port). Brute-force risk is mitigated by using a strong, unique password.

If you ever want to tighten this further, you can restrict SSH to known source
IPv6 prefixes with `ufw` (e.g. `ufw allow from 2001:db8::/32 to any port 22`)
once your home IPv6 prefix is stable — but this is not required.

### Docker socket on Homepage container (MEDIUM — accepted trade-off)

`docker-compose.yml` mounts `/var/run/docker.sock:ro` into the Homepage
container so it can display live container status widgets.  The `:ro` flag
prevents the container from starting/stopping services, but a compromised
Homepage instance could still read other containers' environment variables
(which may contain API keys and passwords) via the Docker API.

If the Dashboard container widgets are not needed, remove the volume mount
from the `homepage:` service in `docker-compose.yml` to eliminate this surface
entirely.

### Homepage service-list API (MEDIUM — accepted risk)

`GET /api/services` is publicly accessible without authentication and returns
the full internal service topology (all Docker container names, descriptions,
and paths).  gethomepage does not offer request-level auth for its API
endpoints; the only mitigation is to put the homepage itself behind auth.
For now this is accepted risk — the information is architectural, not
credential-bearing.

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
