#!/usr/bin/env bash
# What qBittorrent persisted after first-boot setup. Tells us which keys the
# real compose must seed into qBittorrent.conf so the user never clicks.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

conf="${LAB_DIR}/qbittorrent-config/qBittorrent/qBittorrent.conf"
[[ -f "${conf}" ]] || fail "no ${conf}; start the lab and finish first-boot setup"

echo "relevant qBittorrent.conf keys (values redacted):"
grep -a -E '^(WebUI|Connection|AutoRun|Session|Preferences)[\]' "${conf}" \
  | sed -E 's/^(WebUI[\](APIKey|Password_PBKDF2))=.*/\1=<redacted>/'

echo
echo "search plugins installed:"
ls "${LAB_DIR}/qbittorrent-config/qBittorrent/nova3/engines/" 2>/dev/null | grep -v '__' || echo "(none)"

# Host vs container on the keys the stack depends on. Needs the host snapshot
# (scripts/00) and QB_API_KEY for the container.
host_raw="${LAB_DIR}/secrets/host-preferences.json"
if [[ -f "${host_raw}" && -n "${QB_API_KEY}" ]]; then
  container_raw="${LAB_DIR}/secrets/container-preferences.json"
  from_probe -H "Authorization: Bearer ${QB_API_KEY}" "${QB_INTERNAL_URL}/api/v2/app/preferences" > "${container_raw}"
  echo
  echo "host vs container (differences only):"
  python - "${host_raw}" "${container_raw}" <<'PY'
import json, sys
host, container = (json.load(open(p)) for p in sys.argv[1:3])
keys = [
    "save_path", "temp_path", "temp_path_enabled",
    "current_interface_name", "current_interface_address",
    "listen_port", "upnp", "random_port",
    "web_ui_address", "web_ui_port", "web_ui_host_header_validation_enabled",
    "web_ui_csrf_protection_enabled", "bypass_local_auth",
    "autorun_enabled", "autorun_program",
    "max_ratio_enabled", "max_seeding_time_enabled",
    "dht", "pex", "lsd", "encryption", "anonymous_mode",
    "queueing_enabled", "dl_limit", "up_limit",
]
for key in keys:
    h, c = host.get(key, "<absent>"), container.get(key, "<absent>")
    if h != c:
        print(f"{key:44} host={json.dumps(h)}  container={json.dumps(c)}")
PY
fi
