# 0006 - Work tracking lives in GitHub, docs hold one truth each

Date: 2026-09-17. Context: audit of the workspace's planning and documentation
layer.

## What happened

The root `CLAUDE.md` had grown to roughly 770 lines holding the architecture,
per-service endpoint lists, the full backlog with ordering, design debt, and
session state, alongside `STATE.md`, `WORKING-STATE.md`, `ROADMAP-DONE.md`,
and per-service `CLAUDE.md` files that restated the same conventions. Drift
followed: service version headers three releases stale, a pipeline step
described that had been removed, two documents each claiming to be the
authority over the other, pointers to deleted spec files, and a session-state
file that was already wrong one commit after it was written. Five repos carried
byte-identical tooling config with no check, and three CI variants.

## Decision

- Every fact has exactly one owner. Work tracking (backlog, ordering, in
  flight, open threads) lives in GitHub Issues and a Project board. Designs
  live in `docs/specs/` with a status enum. Lessons live here. Architecture
  and deployment live in the root README. Rules live in the root `CLAUDE.md`,
  which holds no facts of its own beyond pointers. A service's API and config
  live in that service's README.
- Service `CLAUDE.md` files link to the root once and contain only code-local
  facts.
- Shared tooling config is guarded by `bin/medialab-drift.sh` in CI, and CI
  itself is one reusable workflow.
- Releases are cut by one script and published by one workflow so the
  changelog, the tag, and the release cannot disagree.
- No session-state file. The board and `git log` are the resume point.
