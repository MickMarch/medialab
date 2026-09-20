# 0005 - Register the Jellyfin library root once, not per download

Date: 2026-07-20. Context: first live end-to-end run of the completion webhook.

## What happened

The MVP pipeline had a per-download REGISTER step calling medialab-jellyfin
`POST /library/paths` with the new item's folder. Jellyfin 404s when asked to
add a sub-path of an already-registered library root, and it recursively scans
registered roots anyway. The step failed on the first real download.

A second fallout fix in the same run: medialab-jellyfin's `.env` pointed
`JELLYFIN_HOST` at `127.0.0.1` (itself, inside the container) instead of
`host.docker.internal`. Templates must carry the container-side value.

## Decision

- The library roots (`.../Movies`, `.../Shows`) are registered once at setup
  time. The per-download pipeline is RENAME -> SCAN; SCAN notifies Jellyfin
  that the new path changed.
- `POST /library/paths` stays in medialab-jellyfin for one-time setup use (the
  setup wizard), not for the pipeline.
- The completion relay (`notify_complete.py`) is standalone and stdlib-only so
  it runs unchanged on the host today and inside a qBittorrent container later.
