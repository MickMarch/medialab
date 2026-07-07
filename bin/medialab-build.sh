#!/usr/bin/env bash
# Regenerate .versions.env, then build. Pass service names to build a subset;
# with no args, builds all.
#
#   bin/medialab-build.sh                      # regen versions, build everything
#   bin/medialab-build.sh medialab-bot         # regen versions, build just the bot
#
# Docker layer caching already skips unchanged layers, so a full build is cheap
# when nothing moved. Name a service to scope the rebuild to the one whose
# submodule pin you just advanced.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

"${REPO_ROOT}/bin/medialab-versions.sh"

# --env-file loads the generated versions so both the image tag and the
# APP_VERSION build arg resolve to the real git version.
docker compose \
  --project-directory "${REPO_ROOT}" \
  --env-file "${REPO_ROOT}/.versions.env" \
  build "$@"
