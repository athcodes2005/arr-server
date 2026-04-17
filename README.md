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
- WebDAV (read-only share of the media library for Finder / VLC / Kodi)

Public entrypoint:

- `https://yourhost.duckdns.org/`

The app routes are path-based because DuckDNS gives you a single hostname:

- `https://yourhost.duckdns.org/`
- `https://yourhost.duckdns.org/qbittorrent/`
- `https://yourhost.duckdns.org/prowlarr/`
- `https://yourhost.duckdns.org/sonarr/`
- `https://yourhost.duckdns.org/radarr/`
- `https://yourhost.duckdns.org/bazarr/`
- `https://yourhost.duckdns.org/webdav/`

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
├── sonarr/
│   └── data/
└── webdav/
    └── config.yml
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

## WebDAV media share

The stack exposes `./data/media` (movies + tv) read-only over WebDAV at:

- `https://yourhost.duckdns.org/webdav/`

The server is `hacdias/webdav` (Go, tiny RAM footprint) behind Caddy. Auth is
basic auth; credentials come from `.env`:

- `WEBDAV_USERNAME`
- `WEBDAV_PASSWORD`

If those are left blank, bootstrap falls back to `QBITTORRENT_WEBUI_USERNAME`
/ `QBITTORRENT_WEBUI_PASSWORD` — the same "admin / master password" you use
for the rest of the stack (matching the `ARR_AUTH_*` fallback pattern).

Permissions are fixed at `R` (read-only) in `webdav/config.yml` and the bind
mount in `docker-compose.yml` is also mounted `:ro`, so clients cannot modify
the arr-managed library even if the config is edited.

### Why does `/webdav/` look like raw XML in a browser?

That is WebDAV working correctly, not an error. WebDAV is a protocol for
file-manager clients (Finder, Kodi, VLC, Cyberduck), not web browsers. When a
browser does a plain `GET` on a collection URL, the server responds with the
protocol-native multistatus XML listing. Browsers have no idea how to render
it, so they dump the tree verbatim. Open it in a real WebDAV client instead.

### Connecting clients

**macOS Finder**

- `Cmd + K` → `Server Address: https://yourhost.duckdns.org/webdav/`
- Connect As: Registered User → enter `WEBDAV_USERNAME` / `WEBDAV_PASSWORD`
- The share mounts under `/Volumes/webdav`.

**VLC**

- Open Network → `https://yourhost.duckdns.org/webdav/` → enter credentials

**Kodi**

- Add Video Source → Browse → Add network location → `WebDAV server (HTTPS)`
- Server name: `yourhost.duckdns.org`, Remote path: `webdav`, username +
  password from `.env`

**Command line (testing)**

```bash
curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" https://yourhost.duckdns.org/webdav/
```

A listing of `movies/` and `tv/` should come back.

### Changing permissions

If you later want a writable share (e.g. to upload files from another
machine), edit `webdav/config.yml` and change `permissions: R` to `CRUD`,
then drop the `:ro` flag on the `./data/media:/media` mount in
`docker-compose.yml`. Redeploy with `./deploy.sh`. Be aware that clients
writing into this tree may confuse Sonarr/Radarr if names collide with
managed files.

## Security hardening (manual steps on the Pi)

The following items cannot be fixed via this repo's deploy scripts — they
require direct SSH access to the Pi with root privileges.

### SSH hardening (MEDIUM severity)

Port 22 is publicly reachable from the internet.  Disable password
authentication so only SSH keys work:

```bash
# On the Pi:
sudo grep -E '^(PasswordAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config
# Make sure these are set:
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

Verify your key-based login still works in a second terminal before closing
the current session.  Once confirmed, consider restricting SSH to known source
IPv6 prefixes with `ufw` or `ip6tables` if your home IPv6 prefix is stable.

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
