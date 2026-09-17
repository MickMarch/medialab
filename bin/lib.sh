#!/usr/bin/env bash
# Shared helpers for bin/ scripts. Source, do not execute.
#
# docker-compose.yml is the single source of truth for which services exist,
# what their images are called, and which *_VERSION variable each interpolates.
# Nothing here hardcodes a service name.

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
export REPO_ROOT

# Every runtime service, one per line, as compose names them.
medialab_services() {
  docker compose --project-directory "${REPO_ROOT}" config --services 2>/dev/null
}

# Image repository (no tag) for a compose service, read from the compose file.
medialab_image() {
  docker compose --project-directory "${REPO_ROOT}" config --format json 2>/dev/null \
    | python -c 'import json,sys; svc=sys.argv[1]; print(json.load(sys.stdin)["services"][svc]["image"].rsplit(":",1)[0])' "$1"
}

# The *_VERSION variable a compose service interpolates: the service name
# upper-cased with hyphens as underscores (medialab-bot -> MEDIALAB_BOT_VERSION).
medialab_version_var() {
  printf '%s_VERSION\n' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Every Python repo in the workspace (services plus non-service packages),
# read from .gitmodules.
medialab_repos() {
  git -C "${REPO_ROOT}" config --file .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'
}
