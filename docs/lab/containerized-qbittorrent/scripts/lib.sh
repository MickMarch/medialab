#!/usr/bin/env bash
# Shared helpers for the lab scripts. Source, do not execute.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${LAB_DIR}/.env"
GLUETUN_CONTROL_URL="http://127.0.0.1:8099"
WEBUI_HOST_URL="http://127.0.0.1:8090"
QB_INTERNAL_URL="http://gluetun:8080"
WEBHOOK_NAME_URL="http://webhook:8000/api/v1/webhooks/torrent-complete"
WEBHOOK_IP_URL="http://172.30.77.10:8000/api/v1/webhooks/torrent-complete"
PUBLIC_IP_URL="https://api.ipify.org"
CURL_TIMEOUT_SECONDS=8

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "missing ${ENV_FILE}; copy .env.example and fill it in" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

compose() { docker compose --project-directory "${LAB_DIR}" "$@"; }

# Runs curl inside qBittorrent's (= gluetun's) network namespace.
in_tunnel() { compose exec -T qbittorrent curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "$@"; }

# Runs curl from the probe container, which plays torrent-downloader.
from_probe() { compose exec -T probe curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "$@"; }

control() { curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY}" "$@"; }

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }
