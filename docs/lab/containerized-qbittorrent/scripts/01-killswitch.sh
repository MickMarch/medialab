#!/usr/bin/env bash
# Verifies the tunnel carries qBittorrent's traffic and that dropping the
# tunnel stops all egress instead of falling back to the host connection.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

host_ip="$(curl -sS --max-time "${CURL_TIMEOUT_SECONDS}" "${PUBLIC_IP_URL}")"
tunnel_ip="$(in_tunnel "${PUBLIC_IP_URL}")"
gluetun_ip="$(control "${GLUETUN_CONTROL_URL}/v1/publicip/ip")"
echo "host public IP:    ${host_ip}"
echo "tunnel public IP:  ${tunnel_ip}"
echo "gluetun reports:   ${gluetun_ip}"
[[ -n "${tunnel_ip}" && "${tunnel_ip}" != "${host_ip}" ]] \
  && pass "qBittorrent egress differs from host" \
  || fail "qBittorrent egress equals host IP or is empty"

echo "stopping tunnel via control server"
control -X PUT -d '{"status":"stopped"}' "${GLUETUN_CONTROL_URL}/v1/vpn/status"
sleep 2
if in_tunnel "${PUBLIC_IP_URL}" >/dev/null 2>&1; then
  control -X PUT -d '{"status":"running"}' "${GLUETUN_CONTROL_URL}/v1/vpn/status"
  fail "egress still possible with tunnel down (LEAK)"
fi
pass "no egress with tunnel down"

echo "restoring tunnel"
control -X PUT -d '{"status":"running"}' "${GLUETUN_CONTROL_URL}/v1/vpn/status"
sleep 15
restored_ip="$(in_tunnel "${PUBLIC_IP_URL}")"
[[ -n "${restored_ip}" && "${restored_ip}" != "${host_ip}" ]] \
  && pass "tunnel restored (${restored_ip})" \
  || fail "tunnel did not come back"
