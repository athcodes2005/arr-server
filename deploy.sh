#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

log() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

load_env() {
  [ -f "${ENV_FILE}" ] || die "Missing ${ENV_FILE}. Copy .env.example to .env and fill it first."
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a

  : "${PI_SSH_HOST:?PI_SSH_HOST is required in .env}"
  : "${PI_DEPLOY_PATH:?PI_DEPLOY_PATH is required in .env}"
}

sync_repo() {
  log "Ensuring remote path exists on ${PI_SSH_HOST}"
  ssh -6 "${PI_SSH_HOST}" "mkdir -p '${PI_DEPLOY_PATH}'"

  log "Syncing repository to ${PI_SSH_HOST}:${PI_DEPLOY_PATH}"
  # --inplace preserves the inode of files that are already bind-mounted into
  # running containers (e.g. caddy/Caddyfile, webdav/config.yml). Without it
  # rsync replaces the file via rename-over, breaking the bind mount until
  # the container is recreated.
  rsync -az --human-readable --inplace \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    -e "ssh -6" \
    "${ROOT_DIR}/" "${PI_SSH_HOST}:${PI_DEPLOY_PATH}/"
}

deploy_remote() {
  log "Deploying Docker stack on the Pi"
  ssh -6 "${PI_SSH_HOST}" "PI_DEPLOY_PATH='${PI_DEPLOY_PATH}' bash -s" <<'EOF'
set -euo pipefail

cd "${PI_DEPLOY_PATH}"

if docker info >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

${DOCKER} compose pull
chmod +x ./scripts/bootstrap-remote.sh
./scripts/bootstrap-remote.sh

services="$(${DOCKER} compose config --services)"
[ -n "${services}" ] || {
  echo "[remote-error] No services found in docker-compose.yml" >&2
  exit 1
}

for service in ${services}; do
  container_id="$(${DOCKER} compose ps -q "${service}")"
  [ -n "${container_id}" ] || {
    echo "[remote-error] Service ${service} did not create a container" >&2
    exit 1
  }

  status="$(${DOCKER} inspect -f '{{.State.Status}}' "${container_id}")"
  [ "${status}" = "running" ] || {
    echo "[remote-error] Service ${service} is not running (status=${status})" >&2
    exit 1
  }

  health="$(${DOCKER} inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_id}")"
  [ "${health}" != "unhealthy" ] || {
    echo "[remote-error] Service ${service} is unhealthy" >&2
    exit 1
  }
done

${DOCKER} compose ps
EOF
}

commit_and_push() {
  local commit_message
  commit_message="Deploy $(date '+%Y-%m-%d %H:%M:%S %Z')"

  log "Staging local changes"
  git -C "${ROOT_DIR}" add -A

  if git -C "${ROOT_DIR}" diff --cached --quiet; then
    log "No new Git changes to commit"
  else
    log "Creating Git commit"
    git -C "${ROOT_DIR}" commit -m "${commit_message}"
  fi

  log "Pushing to GitHub"
  git -C "${ROOT_DIR}" push origin HEAD
}

main() {
  require_cmd ssh
  require_cmd rsync
  require_cmd git

  load_env
  sync_repo
  deploy_remote
  commit_and_push

  log "Deployment succeeded and changes were pushed."
}

main "$@"
