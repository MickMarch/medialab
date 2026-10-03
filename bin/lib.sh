#!/usr/bin/env bash
# Shared helpers for bin/ scripts. Source, do not execute.
#
# docker-compose.yml is the single source of truth for which services exist,
# what their images are called, and which *_VERSION variable each interpolates.
# Nothing here hardcodes a service name.
#
# Services come in two kinds. Built services have a `build:` key, live in a
# submodule, and carry a git tag that becomes their image version. Third-party
# services (a VPN client, a torrent client) are pulled images with no
# submodule and no tag of ours; version and build tooling must skip them.
#
# MEDIALAB_COMPOSE_FILE overrides the compose file read, for tests.

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
export REPO_ROOT

MEDIALAB_COMPOSE_FILE="${MEDIALAB_COMPOSE_FILE:-${REPO_ROOT}/docker-compose.yml}"
export MEDIALAB_COMPOSE_FILE

# The resolved compose model as JSON.
medialab_compose_json() {
  docker compose --project-directory "$(dirname "${MEDIALAB_COMPOSE_FILE}")" \
    -f "${MEDIALAB_COMPOSE_FILE}" config --format json 2>/dev/null
}

# Python on Windows writes CRLF to a pipe; strip the CR so names compare clean.
_medialab_lf() {
  tr -d '\r'
}

# Service names filtered by the presence of a `build` key: "built" or "image".
_medialab_services_of_kind() {
  medialab_compose_json | python -c '
import json, sys
kind = sys.argv[1]
services = json.load(sys.stdin)["services"]
for name in sorted(services):
    built = "build" in services[name]
    if (kind == "built") == built:
        print(name)
' "$1" | _medialab_lf
}

# Every service this workspace builds from a submodule, one per line.
medialab_services() {
  _medialab_services_of_kind built
}

# Every pulled third-party image service, one per line.
medialab_third_party_services() {
  _medialab_services_of_kind image
}

# Image repository (no tag) for any compose service.
medialab_image() {
  medialab_compose_json \
    | python -c 'import json,sys; svc=sys.argv[1]; print(json.load(sys.stdin)["services"][svc]["image"].rsplit(":",1)[0])' "$1" \
    | _medialab_lf
}

# Full image reference (with tag) for any compose service.
medialab_image_ref() {
  medialab_compose_json \
    | python -c 'import json,sys; svc=sys.argv[1]; print(json.load(sys.stdin)["services"][svc]["image"])' "$1" \
    | _medialab_lf
}

# The *_VERSION variable a built service interpolates: the service name
# upper-cased with hyphens as underscores (medialab-bot -> MEDIALAB_BOT_VERSION).
medialab_version_var() {
  printf '%s_VERSION\n' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Every Python repo in the workspace (services plus non-service packages),
# read from .gitmodules.
medialab_repos() {
  git -C "${REPO_ROOT}" config --file .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'
}
