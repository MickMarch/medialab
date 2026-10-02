#!/usr/bin/env bash
# Can the completion hook, running inside qBittorrent's namespace, reach the
# webhook receiver on the compose network? Tests by IP and by service name
# separately: gluetun's firewall gates the IP, its DNS gates the name.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

body='{"hash":"0000000000000000000000000000000000000000","name":"lab","content_path":"/media/lab"}'

if in_tunnel -X POST -H 'Content-Type: application/json' -d "${body}" "${WEBHOOK_IP_URL}" >/dev/null; then
  pass "hook reaches webhook by IP (FIREWALL_OUTBOUND_SUBNETS works)"
else
  fail "hook cannot reach webhook by IP"
fi

if in_tunnel -X POST -H 'Content-Type: application/json' -d "${body}" "${WEBHOOK_NAME_URL}" >/dev/null; then
  pass "hook reaches webhook by service name (compose DNS survives gluetun)"
else
  echo "FAIL  hook cannot reach webhook by service name; resolv.conf inside namespace:"
  compose exec -T qbittorrent cat /etc/resolv.conf
  echo "Hook must use the IP, or gluetun DNS needs DNS_REBINDING_PROTECTION_EXEMPT_HOSTNAMES / fixed addresses."
  exit 1
fi

echo "tools available for the hook inside the qBittorrent image:"
compose exec -T qbittorrent sh -c 'command -v curl; command -v python3; python3 --version'
