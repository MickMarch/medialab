#!/usr/bin/env bash
# Version skew table: for each service compare
#   local   - git describe in the submodule working tree (the code on disk)
#   pinned  - the SHA this root repo pins the submodule at
#   built   - OCI image.version label on the local image (what was last built)
#   running - image.version label on the running container (what is live)
#   latest  - newest tag on the submodule's origin (is a release available)
#
# A clean stack has local == built == running and local == the newest tag.
# Divergence flags: code changed but not rebuilt, an old image still running,
# or an unreleased/unpulled tag upstream.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

LABEL=org.opencontainers.image.version

# Load the generated version tags if present, so built_ver knows which tagged
# image to look for. Absent, it falls back to :latest.
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/.versions.env" ] && . "${REPO_ROOT}/.versions.env"

declare -A SERVICES=(
  [torrent-downloader]=medialab/torrent-downloader
  [medialab-jellyfin]=medialab/medialab-jellyfin
  [medialab-orchestrator]=medialab/medialab-orchestrator
  [medialab-bot]=medialab/medialab-bot
)

# submodule path -> the *_VERSION var name generated into .versions.env
declare -A VERVAR=(
  [torrent-downloader]=TORRENT_DOWNLOADER_VERSION
  [medialab-jellyfin]=MEDIALAB_JELLYFIN_VERSION
  [medialab-orchestrator]=MEDIALAB_ORCHESTRATOR_VERSION
  [medialab-bot]=MEDIALAB_BOT_VERSION
)

na() { [ -n "$1" ] && echo "$1" || echo "-"; }

local_ver() { git -C "$1" describe --tags --always --dirty 2>/dev/null || true; }

pinned_sha() { git rev-parse --short "HEAD:$1" 2>/dev/null || true; }

# image.version label off the local image. Distinguishes three states:
#   no such image        -> "" (renders '-')
#   image, no label      -> "unlabeled" (built before version stamping)
#   image with label     -> the version
label_of() {
  local ref="$1" out
  out="$(docker inspect --format "{{ index .Config.Labels \"${LABEL}\" }}" "${ref}" 2>/dev/null)" || return 0
  [ -z "${out}" ] && echo "unlabeled" || echo "${out}"
}

# Prefer the version-tagged image; fall back to :latest so the current
# (pre-labeling) stack still shows up as built.
built_ver() {
  local image="$1" tagged="$2"
  if docker image inspect "${image}:${tagged}" >/dev/null 2>&1; then
    label_of "${image}:${tagged}"
  else
    label_of "${image}:latest"
  fi
}

# Label off the container currently running (by compose service name).
running_ver() {
  local cid
  cid="$(docker ps --filter "label=com.docker.compose.service=$1" \
    --format '{{.ID}}' 2>/dev/null | head -n1)"
  [ -z "${cid}" ] && return 0
  label_of "${cid}"
}

latest_tag() {
  git -C "$1" ls-remote --tags --sort=-v:refname origin 2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true
}

printf '%-24s %-20s %-9s %-14s %-14s %-10s\n' \
  SERVICE LOCAL PINNED BUILT RUNNING LATEST-TAG
printf '%-24s %-20s %-9s %-14s %-14s %-10s\n' \
  ------- ----- ------ ----- ------- ----------

for path in torrent-downloader medialab-jellyfin medialab-orchestrator medialab-bot; do
  image="${SERVICES[$path]}"
  tagged="${!VERVAR[$path]:-dev}"
  printf '%-24s %-20s %-9s %-14s %-14s %-10s\n' \
    "$path" \
    "$(na "$(local_ver "$path")")" \
    "$(na "$(pinned_sha "$path")")" \
    "$(na "$(built_ver "$image" "$tagged")")" \
    "$(na "$(running_ver "$path")")" \
    "$(na "$(latest_tag "$path")")"
done
