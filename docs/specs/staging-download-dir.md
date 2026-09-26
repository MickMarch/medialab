# Spec: staging directory for downloads

Status: Draft
Issue: MickMarch/medialab#59

## Problem

qBittorrent saves straight into `F:\Media\Movies` and `F:\Media\Shows`, the
roots Jellyfin's library monitor watches. So Jellyfin indexes every raw
release folder while it downloads and just after it completes: it fetches
metadata for the torrent name, extracts trickplay images, and holds the file
open. On 2026-09-26 that lock hit RENAME mid-move and left the film twice
(#58). Even without the lock, users see torrent-named ghosts in Jellyfin for
the minutes between completion and placement.

## Goal and non-goals

**Goal.** Jellyfin never sees a download until the pipeline has placed and
named it. The final placement stays a same-volume rename, not a copy.

**Non-goals.** A separate disk or a qBittorrent "incomplete" directory (a
second move per download for no gain). Moving the existing library.

## Design

One staging root inside the media root, beside the libraries:

```
F:\Media\
├── Movies\          Jellyfin library root (unchanged)
├── Shows\           Jellyfin library root (unchanged)
└── _incoming\       staging, not a Jellyfin library
    ├── Movies\      qBittorrent save path for media_type=movie
    └── Shows\       qBittorrent save path for media_type=show
```

Same drive, so RENAME's move is an atomic rename. `_incoming` is not under
either library root, so Jellyfin's monitor never sees it.

### contracts

`STAGING_SUBDIR = "_incoming"` next to `MEDIA_TYPE_SUBDIRS`. Two services
must agree on it, so it has one home.

### torrent-downloader

`POST /download` resolves the save path as
`MEDIA_HOST_PATH \ STAGING_SUBDIR \ MEDIA_TYPE_SUBDIRS[media_type]`. The
`host_path` it caches and reports follows. No new config: the staging name is
a contract, not a preference.

### orchestrator

- Source root for RENAME (and for the delete plan's download folder) is
  `media_mount / STAGING_SUBDIR / subdir`; the destination root stays
  `media_mount / subdir`.
- Fallback for jobs that predate this change: if the source is absent under
  staging, look under the library root as today. Removed one release later.
- The health poll and webhook are unchanged; they key on hashes, not paths.

### host and workspace

- `bin/medialab-doctor.sh` checks that both staging folders exist and warns
  when not (qBittorrent creates them on first use, but a warning beats a
  silent first-download failure).
- `docs/host-setup.md` documents the layout and that `_incoming` must not
  be added as a Jellyfin library.
- Compose: unchanged; the orchestrator already mounts the whole media root.

## Decisions

1. Staging under the media root, not a separate path. Keeps the move a
   rename and needs no new mount or config on either service.
2. The staging name is a contracts constant, not per-service config. Two
   services must agree on it; a config value in each is the drift this
   workspace exists to remove.
3. Library-root fallback for one release. In-flight downloads at deploy time
   still complete correctly; the fallback is removed once none remain.
4. `_incoming` with a leading underscore so it sorts first and reads as
   internal in Explorer.

## Open questions

None expected.

## Test plan

Contracts: constant present and a plain name. Downloader: save path for
both media types includes the staging segment; `host_path` cached
accordingly. Orchestrator: RENAME source under staging; fallback to the
library root when staging has nothing; delete plan names the staging folder.
Doctor: warning row when a staging folder is missing.

## Rollout

Contracts minor, downloader minor, orchestrator minor, root docs and doctor.
Host: create the two folders (or let qBittorrent create them on first use).
Verify with one movie download: nothing appears in Jellyfin until the
pipeline finishes, then the named film appears once.
