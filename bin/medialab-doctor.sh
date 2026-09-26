#!/usr/bin/env bash
# Is the stack up? One read-only table covering every layer:
#   Docker engine, each compose service, the two host apps, the gateway's
#   aggregated health, and whether the bot is logged in. Exits non-zero if any
#   row fails. Starts nothing; that is what autostart is for.
#
# Host endpoints default to the published ports; override with env vars when
# the host layout differs:
#   QB_URL (default http://127.0.0.1:8080)   JELLYFIN_URL (default http://127.0.0.1:8096)
#   GATEWAY_URL (default http://127.0.0.1:8000)   WEB_URL (default http://127.0.0.1:8081)
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QB_URL="${QB_URL:-http://127.0.0.1:8080}"
JELLYFIN_URL="${JELLYFIN_URL:-http://127.0.0.1:8096}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8000}"
WEB_URL="${WEB_URL:-http://127.0.0.1:8081}"
BOT_SERVICE="medialab-bot"
CURL_TIMEOUT_SECONDS=5
# qBittorrent answers 403 to unauthenticated API calls; that still proves it is up.
QB_UP_STATUSES="200 401 403"

status=0
row() { # ok|FAIL name detail
  printf '%-4s %-28s %s\n' "$1" "$2" "$3"
  [ "$1" = "FAIL" ] && status=1
}
http_code() { curl -s -o /dev/null -m "${CURL_TIMEOUT_SECONDS}" -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
http_body() { curl -s -m "${CURL_TIMEOUT_SECONDS}" "$1" 2>/dev/null; }

printf '%-4s %-28s %s\n' "" CHECK DETAIL
printf '%-4s %-28s %s\n' "" ----- ------

# 1. Docker engine
if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  row ok "docker engine" "$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
else
  row FAIL "docker engine" "docker info failed; is Docker Desktop running?"
fi

# 2. Compose services
compose_json="$(docker compose --project-directory "${REPO_ROOT}" ps --all --format json 2>/dev/null || true)"
while IFS= read -r svc; do
  state="$(printf '%s\n' "${compose_json}" | python -c '
import json, sys
svc = sys.argv[1]
rows = [json.loads(l) for l in sys.stdin if l.strip()]
for r in rows:
    if r.get("Service") == svc:
        print(r.get("State", "?") + " " + r.get("Status", ""))
        break
else:
    print("absent")
' "${svc}" 2>/dev/null)"
  case "${state}" in
    running*) row ok "container ${svc}" "${state}" ;;
    *)        row FAIL "container ${svc}" "${state}" ;;
  esac
done < <(medialab_services)

# 2b. Staging folders: qBittorrent saves here, the pipeline moves into the
# library. Missing folders are created by qBittorrent on first use, but a
# warning beats a surprise; MEDIA_HOST_DIR comes from the root .env.
media_host_dir="$(grep -E '^MEDIA_HOST_DIR=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')"
if [ -n "${media_host_dir}" ]; then
  for sub in Movies Shows; do
    if [ -d "${media_host_dir}/_incoming/${sub}" ]; then
      row ok "staging ${sub}" "${media_host_dir}/_incoming/${sub}"
    else
      row WARN "staging ${sub}" "${media_host_dir}/_incoming/${sub} missing"
    fi
  done
fi

# 3. Host apps
code="$(http_code "${QB_URL}/api/v2/app/version")"
case " ${QB_UP_STATUSES} " in
  *" ${code} "*) row ok "qBittorrent web ui" "${QB_URL} -> ${code}" ;;
  *)             row FAIL "qBittorrent web ui" "${QB_URL} -> ${code}" ;;
esac

body="$(http_body "${JELLYFIN_URL}/health")"
if [ "${body}" = "Healthy" ]; then
  row ok "jellyfin" "${JELLYFIN_URL}/health -> ${body}"
else
  row FAIL "jellyfin" "${JELLYFIN_URL}/health -> ${body:-no response}"
fi

# 4. Gateway health, both downstream workers true
health="$(http_body "${GATEWAY_URL}/api/v1/health")"
gateway_ok="$(printf '%s' "${health}" | python -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); sys.exit()
down = d.get("downstream", {})
print("yes" if d.get("status") == "online" and all(down.values()) and down else "no")
' 2>/dev/null)"
if [ "${gateway_ok}" = "yes" ]; then
  row ok "gateway health" "${health}"
else
  row FAIL "gateway health" "${health:-no response}"
fi

# Jobs parked by the health poll. A warning, not a failure: the stack is up, a
# job wants a human (see /jobs NEEDS_ATTENTION in Discord).
needs_attention="$(printf '%s' "${health}" | python -c '
import json, sys
try:
    print(int(json.load(sys.stdin).get("needs_attention", 0)))
except Exception:
    print(0)
' 2>/dev/null)"
if [ "${needs_attention:-0}" -gt 0 ]; then
  row WARN "jobs need attention" "${needs_attention} job(s); run /jobs NEEDS_ATTENTION in Discord"
else
  row ok "jobs need attention" "none"
fi

# 5. Web UI answering
body="$(http_body "${WEB_URL}/health")"
if printf '%s' "${body}" | grep -q '"online"'; then
  row ok "web ui" "${WEB_URL}/health -> ${body}"
else
  row FAIL "web ui" "${WEB_URL}/health -> ${body:-no response}"
fi

# 6. Bot logged in since its container last started
cid="$(docker ps --filter "label=com.docker.compose.service=${BOT_SERVICE}" --format '{{.ID}}' 2>/dev/null | head -n1)"
if [ -z "${cid}" ]; then
  row FAIL "bot logged in" "no running ${BOT_SERVICE} container"
else
  started="$(docker inspect --format '{{.State.StartedAt}}' "${cid}" 2>/dev/null)"
  login_line="$(docker logs --since "${started}" "${cid}" 2>&1 | grep -E 'Logged in as' | tail -n1)"
  if [ -n "${login_line}" ]; then
    row ok "bot logged in" "${login_line#*INFO:medialab_bot.main:}"
  else
    row FAIL "bot logged in" "no 'Logged in as' since container start ${started}"
  fi
fi

exit "${status}"
