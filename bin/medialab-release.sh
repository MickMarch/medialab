#!/usr/bin/env bash
# Cut a release for one submodule and advance the root pin.
#
#   bin/medialab-release.sh <repo> <major|minor|patch> [--dry-run]
#
# The version is computed here, at release time, from the repo's last tag plus
# the bump kind; nothing else in the workspace predicts it. Steps:
#   1. refuse unless the submodule is on main, clean, and in sync with origin
#   2. refuse unless CHANGELOG.md has entries under [Unreleased]
#   3. move those entries under a dated "## [X.Y.Z] - YYYY-MM-DD" heading
#   4. commit "docs: release vX.Y.Z", create the annotated tag, push both
#      (the repo's release.yml then publishes the GitHub Release)
#   5. bump the root submodule pin, regenerate .versions.env, commit the root
#
# Root commit is left unpushed for review.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "usage: $0 <repo> <major|minor|patch> [--dry-run]" >&2; exit 2; }

REPO="${1:-}"; KIND="${2:-}"; DRY="${3:-}"
[ -n "${REPO}" ] && [ -n "${KIND}" ] || usage
case "${KIND}" in major|minor|patch) ;; *) usage ;; esac
[ -z "${DRY}" ] || [ "${DRY}" = "--dry-run" ] || usage
DIR="${REPO_ROOT}/${REPO}"
[ -d "${DIR}/.git" ] || [ -f "${DIR}/.git" ] || { echo "not a submodule: ${REPO}" >&2; exit 1; }

run() { if [ -n "${DRY}" ]; then echo "+ $*"; else "$@"; fi; }

g() { git -C "${DIR}" "$@"; }

# 1. preconditions
branch="$(g rev-parse --abbrev-ref HEAD)"
[ "${branch}" = "main" ] || { echo "${REPO} is on ${branch}, not main" >&2; exit 1; }
[ -z "$(g status --porcelain)" ] || { echo "${REPO} has uncommitted changes" >&2; exit 1; }
g fetch --quiet origin main --tags
[ "$(g rev-parse HEAD)" = "$(g rev-parse origin/main)" ] || { echo "${REPO} main is not in sync with origin" >&2; exit 1; }

# 2. compute version
last="$(g describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)"
IFS=. read -r MA MI PA <<< "${last#v}"
case "${KIND}" in
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
esac
VERSION="${MA}.${MI}.${PA}"
TAG="v${VERSION}"
TODAY="$(date +%Y-%m-%d)"

# 3. changelog
CHANGELOG="${DIR}/CHANGELOG.md"
unreleased="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "${CHANGELOG}" | grep -vE '^\s*$' || true)"
[ -n "${unreleased}" ] || { echo "${REPO}/CHANGELOG.md has nothing under [Unreleased]" >&2; exit 1; }
if grep -q "^## \[${VERSION}\]" "${CHANGELOG}"; then
  echo "${REPO}/CHANGELOG.md already has a ${VERSION} heading" >&2; exit 1
fi

echo "${REPO}: ${last} -> ${TAG} (${KIND}) on ${TODAY}"
echo "Unreleased entries:"
echo "${unreleased}" | sed 's/^/  /'

if [ -z "${DRY}" ]; then
  python - "${CHANGELOG}" "${VERSION}" "${TODAY}" <<'PY'
import re, sys
path, version, today = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
new = re.sub(
    r"^## \[Unreleased\]\n",
    f"## [Unreleased]\n\n## [{version}] - {today}\n",
    text, count=1, flags=re.M,
)
open(path, "w", encoding="utf-8", newline="\n").write(new)
PY
fi

# 4. commit, tag, push
run git -C "${DIR}" add CHANGELOG.md
run git -C "${DIR}" commit -m "docs: release ${TAG}"
run git -C "${DIR}" tag -a "${TAG}" -m "${TAG}"
run git -C "${DIR}" push origin main "${TAG}"

# 5. root pin
run git -C "${REPO_ROOT}" add "${REPO}"
run "${REPO_ROOT}/bin/medialab-versions.sh"
run git -C "${REPO_ROOT}" commit -m "chore: bump ${REPO} pin to ${TAG}"
echo "Root pin bumped (not pushed). Release notes publish via ${REPO}'s release workflow."
