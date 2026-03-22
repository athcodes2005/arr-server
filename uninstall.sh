#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${ROOT_DIR}/.arr-server"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
DUCKDNS_CRON_TAG="# arr-server-duckdns"

info() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
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

confirm() {
  local answer
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r answer
  answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
  [ "${answer}" = "y" ] || [ "${answer}" = "yes" ]
}

main() {
  if [ ! -d "${STACK_DIR}" ]; then
    warn "No generated runtime directory found at ${STACK_DIR}."
    exit 0
  fi

  if ! confirm "This will stop the ARR stack and delete all generated configs, logs, and media data under ${STACK_DIR}. Continue?"; then
    info "Uninstall cancelled."
    exit 0
  fi

  if [ -f "${COMPOSE_FILE}" ] && [ -f "${ENV_FILE}" ]; then
    info "Stopping and removing containers."
    compose_cmd down --remove-orphans --rmi local || warn "docker compose down reported a warning."
  fi

  info "Removing DuckDNS cron job."
  tmp_file="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'arr-server-duckdns' > "${tmp_file}" || true
  crontab "${tmp_file}" 2>/dev/null || true
  rm -f "${tmp_file}"

  info "Removing generated runtime files."
  rm -rf "${STACK_DIR}"

  info "ARR server files removed."
}

main "$@"
