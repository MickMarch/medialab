#!/usr/bin/env bash
# Tooling-drift gate. Every Python repo in the workspace is expected to carry
# identical shared tooling config. This compares each repo against the first
# and exits non-zero on any difference, so drift is caught instead of found
# months later.
#
# Compared byte-for-byte:   .pre-commit-config.yaml, .github/dependabot.yml,
#                           .python-version
# Compared after TOML parse: [tool.ruff] (minus per-repo per-file-ignores),
#                            [tool.mypy] (minus per-repo overrides),
#                            [tool.pytest.ini_options].markers,
#                            requires-python
#
# Per-repo variation is allowed only where a repo genuinely differs (its own
# mypy overrides, its own per-file-ignores); everything else is shared.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mapfile -t REPOS < <(medialab_repos)
BASE="${REPOS[0]}"
status=0

compare_file() {
  local rel="$1" repo
  for repo in "${REPOS[@]:1}"; do
    if [ ! -f "${REPO_ROOT}/${repo}/${rel}" ]; then
      echo "MISSING  ${repo}/${rel}"
      status=1
    elif ! diff -q --strip-trailing-cr "${REPO_ROOT}/${BASE}/${rel}" "${REPO_ROOT}/${repo}/${rel}" >/dev/null; then
      echo "DRIFT    ${repo}/${rel} differs from ${BASE}/${rel}"
      diff --strip-trailing-cr "${REPO_ROOT}/${BASE}/${rel}" "${REPO_ROOT}/${repo}/${rel}" | sed 's/^/           /' || true
      status=1
    fi
  done
}

# Normalized JSON dump of the shared pyproject blocks.
shared_toml() {
  python - "$1" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
tool = data.get("tool", {})
ruff = dict(tool.get("ruff", {}))
ruff.get("lint", {}).pop("per-file-ignores", None)
mypy = dict(tool.get("mypy", {}))
mypy.pop("overrides", None)
shared = {
    "requires-python": data.get("project", {}).get("requires-python"),
    "ruff": ruff,
    "mypy": mypy,
    "pytest.markers": tool.get("pytest", {}).get("ini_options", {}).get("markers"),
}
print(json.dumps(shared, indent=2, sort_keys=True))
PY
}

compare_pyproject() {
  local base_dump repo repo_dump
  base_dump="$(shared_toml "${REPO_ROOT}/${BASE}/pyproject.toml")"
  for repo in "${REPOS[@]:1}"; do
    repo_dump="$(shared_toml "${REPO_ROOT}/${repo}/pyproject.toml")"
    if [ "${base_dump}" != "${repo_dump}" ]; then
      echo "DRIFT    ${repo}/pyproject.toml shared tooling differs from ${BASE}"
      diff <(echo "${base_dump}") <(echo "${repo_dump}") | sed 's/^/           /' || true
      status=1
    fi
  done
}

compare_file .pre-commit-config.yaml
compare_file .github/dependabot.yml
compare_file .python-version
compare_pyproject

if [ "${status}" -eq 0 ]; then
  echo "No tooling drift across: ${REPOS[*]}"
fi
exit "${status}"
