#!/usr/bin/env bash
# Run the medialab-setup CLI from its submodule; arguments and exit code pass through.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exec uv run --project "${REPO_ROOT}/medialab-setup" medialab-setup "$@"
