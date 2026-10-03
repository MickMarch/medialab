#!/usr/bin/env bash
# Snapshots the host qBittorrent's preferences through its API so the
# container can be seeded with the same settings. Reads the host API key from
# torrent-downloader/.env; never prints it. The raw dump lands in secrets/
# (gitignored) because it carries paths and the autorun command line.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "${LAB_DIR}/../../.." && pwd)"
DOWNLOADER_ENV="${WORKSPACE_DIR}/torrent-downloader/.env"
OUT_RAW="${LAB_DIR}/secrets/host-preferences.json"
OUT_SUMMARY="${LAB_DIR}/secrets/host-preferences-summary.txt"
CURL_TIMEOUT_SECONDS=8

[[ -f "${DOWNLOADER_ENV}" ]] || { echo "missing ${DOWNLOADER_ENV}" >&2; exit 1; }
read_env() { sed -n "s/^$1=//p" "${DOWNLOADER_ENV}" | tail -n1 | tr -d '\r'; }
QB_HOST="$(read_env QB_HOST)"; QB_HOST="${QB_HOST:-127.0.0.1}"
QB_PORT="$(read_env QB_PORT)"; QB_PORT="${QB_PORT:-8080}"
QB_API_KEY="$(read_env QB_API_KEY)"
[[ -n "${QB_API_KEY}" ]] || { echo "QB_API_KEY empty in torrent-downloader/.env" >&2; exit 1; }
[[ "${QB_HOST}" == "host.docker.internal" ]] && QB_HOST="127.0.0.1"

base="http://${QB_HOST}:${QB_PORT}/api/v2"
auth=(-H "Authorization: Bearer ${QB_API_KEY}")
curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "${auth[@]}" "${base}/app/preferences" > "${OUT_RAW}"
version="$(curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "${auth[@]}" "${base}/app/version")"
api_version="$(curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "${auth[@]}" "${base}/app/webapiVersion")"

# Keys that shape how the stack talks to qBittorrent. Everything else is user
# taste (speeds, queueing) and is kept in the raw dump for completeness.
keys=(
  save_path temp_path temp_path_enabled
  current_interface_name current_interface_address
  listen_port upnp random_port
  web_ui_address web_ui_port web_ui_username
  web_ui_host_header_validation_enabled web_ui_csrf_protection_enabled
  bypass_local_auth bypass_auth_subnet_whitelist_enabled bypass_auth_subnet_whitelist
  autorun_enabled autorun_program autorun_on_torrent_added_enabled
  max_ratio_enabled max_ratio max_ratio_act max_seeding_time_enabled max_seeding_time
  dht pex lsd encryption anonymous_mode
  proxy_type proxy_ip proxy_port
  queueing_enabled max_active_downloads max_active_uploads max_active_torrents
  dl_limit up_limit
)
{
  echo "qBittorrent ${version}, web API ${api_version}"
  echo
  for key in "${keys[@]}"; do
    value="$(python -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2], "<absent>")))' "${OUT_RAW}" "${key}")"
    printf '%-44s %s\n' "${key}" "${value}"
  done
} | tee "${OUT_SUMMARY}"
echo
echo "raw dump: ${OUT_RAW} (gitignored)"
