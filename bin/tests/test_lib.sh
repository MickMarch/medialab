#!/usr/bin/env bash
# Tests for bin/lib.sh. Runs against a fixture compose file through the
# MEDIALAB_COMPOSE_FILE override, so no real services are needed.
#
#   bin/tests/test_lib.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MEDIALAB_COMPOSE_FILE="${HERE}/fixtures/compose.mixed.yml"

# shellcheck source=lib.sh
. "${HERE}/../lib.sh"

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS  ${label}"
  else
    echo "FAIL  ${label}"
    echo "      expected: ${expected}"
    echo "      actual:   ${actual}"
    failures=$((failures + 1))
  fi
}

check "medialab_services lists only services with a build key" \
  "medialab-built" "$(medialab_services | tr '\n' ' ' | sed 's/ $//')"

check "medialab_third_party_services lists only image-only services" \
  "thirdparty" "$(medialab_third_party_services | tr '\n' ' ' | sed 's/ $//')"

check "medialab_image strips the tag from a built service" \
  "medialab/medialab-built" "$(medialab_image medialab-built)"

check "medialab_image strips the tag from a third-party service" \
  "example/thirdparty" "$(medialab_image thirdparty)"

check "medialab_image_ref keeps the tag" \
  "example/thirdparty:1.2.3" "$(medialab_image_ref thirdparty)"

check "medialab_version_var upper-cases and underscores the service name" \
  "MEDIALAB_BUILT_VERSION" "$(medialab_version_var medialab-built)"

if [[ "${failures}" -eq 0 ]]; then
  echo "lib.sh: all checks passed"
else
  echo "lib.sh: ${failures} check(s) failed"
  exit 1
fi
