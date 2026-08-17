#!/usr/bin/env bash
# Stop-hook helper: nudge to refresh STATE.md when the workspace has moved on
# without it. Stays silent unless there is something worth saying, so the
# reminder keeps its signal value.
#
# Fires a reminder when either:
#   - tracked files have been modified more recently than STATE.md, or
#   - STATE.md does not exist at all.
#
# Always exits 0. A reminder is advisory, never a gate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/STATE.md"

emit() {
  printf '{"systemMessage": %s}\n' "$1"
}

if [[ ! -f "$STATE_FILE" ]]; then
  emit '"STATE.md is missing. Recreate it so the next session can resume cleanly."'
  exit 0
fi

state_mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)

# Newest mtime among tracked, non-ignored files, excluding STATE.md itself.
newest=0
while IFS= read -r f; do
  [[ "$f" == "STATE.md" ]] && continue
  [[ -f "$REPO_ROOT/$f" ]] || continue
  m=$(stat -c %Y "$REPO_ROOT/$f" 2>/dev/null || echo 0)
  (( m > newest )) && newest=$m
done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null)

if (( newest > state_mtime )); then
  emit '"Workspace files changed after STATE.md was last written. If this session changed what is in flight or what is next, refresh STATE.md before ending."'
fi

exit 0
