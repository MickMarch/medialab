#!/usr/bin/env bash
# Plays torrent-downloader: reaches the qBittorrent API over the compose
# network using the Bearer API key and reads the bound interface name, which
# is what is_vpn_bound() checks.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -n "${QB_API_KEY}" ]] || fail "QB_API_KEY empty in .env (generate it in the WebUI first)"

auth=(-H "Authorization: Bearer ${QB_API_KEY}")
version="$(from_probe "${auth[@]}" "${QB_INTERNAL_URL}/api/v2/app/webapiVersion")"
echo "web API version: ${version}"
[[ "${version}" == 2.* ]] && pass "API reachable at ${QB_INTERNAL_URL} with Bearer key" \
  || fail "unexpected response: ${version}"

prefs="$(from_probe "${auth[@]}" "${QB_INTERNAL_URL}/api/v2/app/preferences")"
iface="$(printf '%s' "${prefs}" | sed -n 's/.*"current_interface_name":"\([^"]*\)".*/\1/p')"
addr="$(printf '%s' "${prefs}" | sed -n 's/.*"current_interface_address":"\([^"]*\)".*/\1/p')"
echo "current_interface_name:    '${iface}'"
echo "current_interface_address: '${addr}'"
[[ -n "${iface}" ]] && pass "qBittorrent bound to interface '${iface}'" \
  || fail "qBittorrent not bound to any interface (set Preferences > Advanced > Network interface)"

echo "interfaces visible to qBittorrent:"
from_probe "${auth[@]}" "${QB_INTERNAL_URL}/api/v2/app/networkInterfaceList"; echo
