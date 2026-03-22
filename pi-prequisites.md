# Pi Prerequisites

Checklist and baseline setup for preparing the Raspberry Pi to act as a home server for this ARR stack.

## System Setup

Use `sudo raspi-config` and confirm:

- hostname is set to something stable
- locale and timezone are correct
- filesystem is expanded
- logging is persistent
- SSH is enabled

## Base Packages

Install a small admin toolkit:

```bash
sudo apt update
sudo apt install -y git curl wget ca-certificates neovim tmux btop tree jq unzip
```

## Time Sync

Reliable time is important for TLS and logs.

```bash
sudo apt update
sudo apt install -y chrony
```

Suggested `chrony` servers:

```conf
server time.cloudflare.com iburst minpoll 4 maxpoll 4
server time.google.com iburst minpoll 4 maxpoll 4
server 0.in.pool.ntp.org iburst
server 1.in.pool.ntp.org iburst
makestep 1.0 3
rtcsync
```

Then restart and verify:

```bash
sudo systemctl restart chrony
chronyc sources -v
chronyc tracking
timedatectl
```

## Automatic Security Updates

```bash
sudo apt update
sudo apt install -y unattended-upgrades apt-listchanges
sudo dpkg-reconfigure -plow unattended-upgrades
```

Recommended follow-up:

- enable automatic reboot during an off-hour window
- enable cleanup of unused dependencies
- keep logging enabled for unattended upgrades

## Networking

Before deploying the stack, confirm:

- the Pi has a static DHCP lease or reserved IP on the LAN
- IPv6 is enabled on the router and available on the Pi
- inbound `80/tcp` and `443/tcp` are forwarded to the Pi
- local firewall rules do not block `80/tcp` and `443/tcp`
- the DuckDNS hostname resolves to the Pi's current public IP

Useful checks:

```bash
ip addr
ip -6 addr show scope global
curl -4 ifconfig.me
curl -6 ifconfig.me
```

## Docker

Install Docker Engine and the Compose plugin:

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh
sudo usermod -aG docker "$USER"
newgrp docker
docker --version
docker compose version
```

## Storage Layout

This project expects all stack state to live inside the repo, but the Pi should still have:

- enough free disk for torrents, media, logs, and Docker images
- a filesystem that supports large media files
- a plan for backups of `.env`, app configs, and important media metadata

Optional check:

```bash
df -h
lsblk
```

## DNS and HTTPS Requirements

This stack uses:

- DuckDNS for dynamic DNS updates
- Caddy for automatic HTTPS with `HTTP-01`
- Unbound as the internal DNS resolver for containers

That means:

- port `80` must be reachable from the public internet for certificate issuance
- port `443` must be reachable for normal HTTPS access
- public DNS for the DuckDNS hostname must point at the Pi's current public IP

## Deployment Prep

Before running `docker compose up -d`, confirm:

1. the repo is cloned on the Pi
2. `.env` has real secrets and domain values
3. Docker is installed and usable without `sudo`
4. router port forwarding is in place
5. IPv6 connectivity is working
6. no other service is already bound to ports `80` or `443`

Useful checks:

```bash
ss -tulpn | grep ':80\|:443'
docker compose config
```

## First-Boot App Tasks

After the stack starts for the first time:

1. set Prowlarr base URL to `/prowlarr`
2. set Sonarr base URL to `/sonarr`
3. set Radarr base URL to `/radarr`
4. set Bazarr base URL to `/bazarr`
5. change qBittorrent Web UI credentials and keep `.env` aligned with the final values
6. add Homepage API keys if you want widget status and metrics
