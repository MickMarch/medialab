#!/usr/bin/env bash
# Provision the containerized qBittorrent so nobody has to click through its UI.
#
#   bin/medialab-qbt-provision.sh [--dry-run]
#
# Idempotent: run it after a fresh clone, after wiping qbittorrent/config, or
# any time to re-apply the settings. Steps:
#   1. API key. Reads QB_API_KEY from torrent-downloader/.env; generates one if
#      empty and writes it back. Seeds the same key into
#      qbittorrent/config/qBittorrent/qBittorrent.conf before first start, so
#      the WebUI accepts Bearer calls from boot and the downloader's key always
#      matches.
#   2. Starts gluetun and qbittorrent, waits for the tunnel to be healthy and
#      the WebUI to answer.
#   3. setPreferences over the API: interface bound to the tunnel (tun0), UPnP
#      and local discovery off, queueing off, staging save path, the curl
#      completion hook carrying the gateway key, and once, a random admin
#      password written to qbittorrent/admin-password for the operator.
#   4. Installs the search plugins named in QBT_SEARCH_PLUGINS (root .env).
#
# Inputs: root .env (MEDIA_HOST_DIR, QBT_WEBUI_PORT, QBT_SEARCH_PLUGINS),
# torrent-downloader/.env (QB_API_KEY, API_KEY is untouched),
# medialab-orchestrator/.env (API_KEY, for the hook). Nothing is printed that
# would reveal a key.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${REPO_ROOT}"

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY=1

ROOT_ENV="${REPO_ROOT}/.env"
DOWNLOADER_ENV="${REPO_ROOT}/torrent-downloader/.env"
ORCHESTRATOR_ENV="${REPO_ROOT}/medialab-orchestrator/.env"
QBT_DIR="${REPO_ROOT}/qbittorrent"
QBT_CONF_DIR="${QBT_DIR}/config/qBittorrent"
QBT_CONF="${QBT_CONF_DIR}/qBittorrent.conf"
ADMIN_PASSWORD_FILE="${QBT_DIR}/admin-password"

# Inside the namespace qBittorrent always listens on 8080; the published host
# port may differ, and qBittorrent's host header validation rejects a port
# mismatch, so every call carries the internal Host.
QBT_INTERNAL_HOST_HEADER="Host: localhost:8080"
WEBUI_PORT_DEFAULT=8090
PLUGINS_DEFAULT="eztv,limetorrents,piratebay,solidtorrents,torlock,torrentproject,torrentscsv"
PLUGIN_SOURCE_BASE="https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines"
TUNNEL_INTERFACE="tun0"
MEDIA_MOUNT="/media"
STAGING_SUBDIR="_incoming"
ORCHESTRATOR_INTERNAL_URL="http://medialab-orchestrator:8000"
WEBHOOK_PATH="/api/v1/webhooks/torrent-complete"
API_KEY_PREFIX="qbt_"
API_KEY_RANDOM_LENGTH=28
WAIT_ATTEMPTS=60
WAIT_SECONDS=3
CURL_TIMEOUT_SECONDS=8

env_value() { # file key -> value (empty when absent)
  { grep -E "^$2=" "$1" 2>/dev/null || true; } | tail -n1 | cut -d= -f2- | tr -d '\r"'
}

set_env_value() { # file key value (replace or append)
  if grep -qE "^$2=" "$1"; then
    python - "$1" "$2" "$3" <<'PY'
import pathlib, re, sys
path, key, value = sys.argv[1:4]
text = pathlib.Path(path).read_text()
text = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={value}", text, count=1, flags=re.M)
pathlib.Path(path).write_text(text)
PY
  else
    printf '\n%s=%s\n' "$2" "$3" >> "$1"
  fi
}

say() { printf '%-6s %s\n' "$1" "$2"; }
run() { if [ -n "${DRY}" ]; then echo "+ $*"; else "$@"; fi; }

for f in "${ROOT_ENV}" "${DOWNLOADER_ENV}" "${ORCHESTRATOR_ENV}"; do
  [ -f "${f}" ] || { echo "missing ${f}; copy its .env.example first" >&2; exit 1; }
done
[ -f "${REPO_ROOT}/gluetun/vpn.env" ] || { echo "missing gluetun/vpn.env; copy gluetun/vpn.env.example and fill in your provider" >&2; exit 1; }

webui_port="$(env_value "${ROOT_ENV}" QBT_WEBUI_PORT)"; webui_port="${webui_port:-${WEBUI_PORT_DEFAULT}}"
plugins="$(env_value "${ROOT_ENV}" QBT_SEARCH_PLUGINS)"; plugins="${plugins:-${PLUGINS_DEFAULT}}"
gateway_key="$(env_value "${ORCHESTRATOR_ENV}" API_KEY)"
[ -n "${gateway_key}" ] || { echo "medialab-orchestrator/.env has no API_KEY" >&2; exit 1; }
WEBUI_URL="http://127.0.0.1:${webui_port}"

# 1. API key: downloader .env is the source; the conf is seeded to match.
qb_key="$(env_value "${DOWNLOADER_ENV}" QB_API_KEY)"
if [ -z "${qb_key}" ]; then
  qb_key="${API_KEY_PREFIX}$(python -c "import secrets, string; a = string.ascii_letters + string.digits; print(''.join(secrets.choice(a) for _ in range(${API_KEY_RANDOM_LENGTH})))")"
  run set_env_value "${DOWNLOADER_ENV}" QB_API_KEY "${qb_key}"
  say ok "QB_API_KEY generated into torrent-downloader/.env"
else
  say ok "QB_API_KEY present in torrent-downloader/.env"
fi

run mkdir -p "${QBT_CONF_DIR}"
if [ -z "${DRY}" ]; then
  python - "${QBT_CONF}" "${qb_key}" <<'PY'
import pathlib, re, sys
conf, key = pathlib.Path(sys.argv[1]), sys.argv[2]
text = conf.read_text() if conf.exists() else ""
line = f"WebUI\\APIKey={key}"
if re.search(r"^WebUI\\APIKey=", text, re.M):
    text = re.sub(r"^WebUI\\APIKey=.*$", line, text, count=1, flags=re.M)
elif "[Preferences]" in text:
    text = text.replace("[Preferences]", f"[Preferences]\n{line}", 1)
else:
    text = (text.rstrip("\n") + "\n\n" if text else "") + f"[Preferences]\n{line}\n"
conf.write_text(text)
PY
fi
say ok "WebUI API key seeded in qbittorrent/config"

# 2. Bring the namespace up and wait.
compose_args=(--project-directory "${REPO_ROOT}" --env-file "${ROOT_ENV}")
[ -f "${REPO_ROOT}/.versions.env" ] && compose_args+=(--env-file "${REPO_ROOT}/.versions.env")
run docker compose "${compose_args[@]}" up -d gluetun qbittorrent
[ -n "${DRY}" ] && { say ok "dry run complete"; exit 0; }

qb() { # path [curl args...]
  curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" -H "${QBT_INTERNAL_HOST_HEADER}" \
    -H "Authorization: Bearer ${qb_key}" "${@:2}" "${WEBUI_URL}/api/v2$1"
}

for _ in $(seq 1 "${WAIT_ATTEMPTS}"); do
  if version="$(qb /app/webapiVersion 2>/dev/null)" && [[ "${version}" == 2.* ]]; then
    break
  fi
  sleep "${WAIT_SECONDS}"
done
[[ "${version:-}" == 2.* ]] || { echo "qBittorrent WebUI did not answer with the seeded key at ${WEBUI_URL}" >&2; exit 1; }
say ok "qBittorrent web API ${version} answering with the seeded key"

# 3. Preferences. The hook is one curl inside the namespace; the gateway key
# is the same one the bot and web use. web_ui_password is set once.
hook="curl -s -X POST ${ORCHESTRATOR_INTERNAL_URL}${WEBHOOK_PATH} -H \"Content-Type: application/json\" -H \"X-API-Key: ${gateway_key}\" -d \"{\\\"hash\\\":\\\"%I\\\",\\\"name\\\":\\\"%N\\\",\\\"content_path\\\":\\\"%F\\\"}\""
admin_password=""
if [ ! -f "${ADMIN_PASSWORD_FILE}" ]; then
  admin_password="$(python -c "import secrets; print(secrets.token_urlsafe(18))")"
fi
prefs_json="$(python - "${TUNNEL_INTERFACE}" "${MEDIA_MOUNT}/${STAGING_SUBDIR}" "${hook}" "${admin_password}" <<'PY'
import json, sys
iface, save_path, hook, admin_password = sys.argv[1:5]
prefs = {
    "current_network_interface": iface,
    "upnp": False,
    "lsd": False,
    "queueing_enabled": False,
    "save_path": save_path,
    "temp_path_enabled": False,
    "autorun_enabled": True,
    "autorun_program": hook,
    "autorun_on_torrent_added_enabled": False,
}
if admin_password:
    prefs["web_ui_password"] = admin_password
print(json.dumps(prefs))
PY
)"
code="$(qb /app/setPreferences -o /dev/null -w '%{http_code}' --data-urlencode "json=${prefs_json}")"
[ "${code}" = "200" ] || { echo "setPreferences returned ${code}" >&2; exit 1; }
say ok "preferences applied (interface ${TUNNEL_INTERFACE}, hook, staging path)"
if [ -n "${admin_password}" ]; then
  umask 077
  printf '%s\n' "${admin_password}" > "${ADMIN_PASSWORD_FILE}"
  say ok "admin password set once; stored in qbittorrent/admin-password (gitignored)"
fi

bound="$(qb /app/preferences | python -c 'import json, sys; print(json.load(sys.stdin).get("current_interface_name", ""))')"
[ "${bound}" = "${TUNNEL_INTERFACE}" ] || { echo "qBittorrent reports interface '${bound}', expected ${TUNNEL_INTERFACE}" >&2; exit 1; }
say ok "qBittorrent bound to ${bound}"

# 4. Search plugins.
sources=""
IFS=',' read -ra names <<< "${plugins}"
for name in "${names[@]}"; do
  name="${name// /}"
  [ -n "${name}" ] || continue
  sources="${sources:+${sources}|}${PLUGIN_SOURCE_BASE}/${name}.py"
done
if [ -n "${sources}" ]; then
  qb /search/installPlugin -o /dev/null --data-urlencode "sources=${sources}"
  sleep "${WAIT_SECONDS}"
  installed="$(qb /search/plugins | python -c 'import json, sys; print(", ".join(sorted(p["name"] for p in json.load(sys.stdin))))')"
  say ok "search plugins: ${installed:-none}"
fi

say "done" "qBittorrent provisioned; bring the rest up with docker compose ${compose_args[*]} up -d"
