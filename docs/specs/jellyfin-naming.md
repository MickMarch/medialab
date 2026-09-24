# Spec: full Jellyfin naming convention

Status: Draft
Issue: MickMarch/medialab#19

## Problem

The RENAME step moves a TV download folder to `Series (Year)/Season NN/` and
leaves movies untouched. Jellyfin's own conventions go further, and the gap
shows in the live library (observed 2026-09-24):

- Movie folders keep raw release names (`Dune.Part.Two.2024.2160p...-FLUX[TGx]`)
  with the video still release-named inside, plus `.nfo`, `.txt`, `.jpg`
  sidecars and `Torrent Downloaded From` junk folders.
- Season packs land as one folder of release-named episode files; Jellyfin
  has to guess episode numbers from those names.
- Multi-season packs (`Show S01-S07/…/Season 1 S01/…`) fail the current
  season parse outright and stay wherever they were.
- One `Season 08` folder sits directly under `Shows/` with no series folder.

Jellyfin's matching, versions and specials handling work cleanly only when
the layout is the documented one:

- Movies: `Movies/Title (Year)/Title (Year).ext`, extras in an `extras/`
  subfolder (https://jellyfin.org/docs/general/server/media/movies).
- Shows: `Shows/Title (Year)/Season NN/Title SNNEMM.ext`, specials in
  `Season 00` (https://jellyfin.org/docs/general/server/media/shows).

## Goal and non-goals

**Goal.** Every completed download is placed and named to that convention,
for both libraries, from the data the pipeline already has: canonical title
and year from TMDB, season and episode numbers parsed from each file name.

**Non-goals.** Re-organising what is already in the library (a one-off
migration is its own issue once this ships and has proven itself on new
downloads). Edition tags (`Director's Cut`) in movie names: PTN does not
parse them reliably and Jellyfin treats them as optional. Removing or
repointing the torrent in qBittorrent after the move: that is #20's
remove-vs-pause decision; today's behaviour (paused torrent left pointing at
the old path) is unchanged by this spec.

## Design

`services/rename.py` stays a pure planner plus a separate mover. The planner
gains file-level output: instead of one `(source, dest)` folder pair it
returns a `RenamePlan` of `(source_file, dest_file)` moves and the directory
Jellyfin should be told to scan.

### Shared rules

- **Video files** are those with a known video extension (`.mkv`, `.mp4`,
  `.avi`, `.m4v`, `.ts`, `.webm`, `.mov`), a constant in the module.
- **Companion files** are subtitle files (`.srt`, `.ass`, `.sub`, `.idx`,
  `.vtt`) whose stem starts with a video file's stem. They move with that
  video and keep whatever suffix follows the shared stem (`.en`, `.forced`),
  so `Show.S01E02.1080p.en.srt` becomes `Title S01E02.en.srt`.
- **Everything else** (`.nfo`, images, `.txt`, junk folders) is left where
  it is. After the moves, the source folder is deleted only if it contains
  no video files at all; otherwise it is left for a human.
- **Title sanitising:** characters illegal in Windows paths (`\ / : * ? " < > |`)
  are removed, runs of whitespace collapsed, trailing dots stripped.
  `Mission: Impossible` becomes `Mission Impossible`. Year `0` or unknown
  yields `Title` with no parentheses.
- **Idempotent:** a move whose destination already exists is skipped, so a
  retry after a partial run finishes the remainder. A source that no longer
  exists is skipped for the same reason.
- **Single-file torrents** (a bare `.mkv` in the library root) are handled
  the same as a folder containing one file.

### Movies

1. Main video = the largest video file in the download.
2. `Movies/Title (Year)/Title (Year).ext` for it, companions alongside.
3. Every other video file goes to `Movies/Title (Year)/extras/` with its
   original name. Jellyfin lists that folder as extras rather than as a
   second copy of the film.
4. Scan path = the movie folder.

### Shows

1. Every video file in the download, recursively, is parsed with PTN for
   season and episode. Companions follow their video.
2. `Shows/Title (Year)/Season NN/Title SNNEMM.ext`; a multi-episode file
   (`S01E01E02`, `S01E01-E02`, PTN returns a list) becomes
   `Title S01E01-E02.ext`. Season 0 is written as `Season 00`, Jellyfin's
   specials folder.
3. A video file with no parseable season and episode fails the whole job
   with `EPISODE_UNPARSEABLE` and the offending file name in `last_error`;
   nothing is moved. The operator fixes the name and retries. Rejected:
   moving what parses and leaving the rest, because a half-placed season is
   worse to untangle than an unplaced one.
4. Multi-season packs work by construction: files are placed by their own
   season, whatever subfolder they came from. The pack-level
   `SeasonUnparseableError` goes away.
5. Scan path = the series folder (one scan covers every season touched).

### Job and wire changes

- `dest_path` keeps its meaning (the folder to scan) and is what `/jobs`
  shows. No schema change; `RenamePlan` is internal.
- `ErrorCode.SEASON_UNPARSEABLE` is replaced by `EPISODE_UNPARSEABLE`
  (orchestrator-local, not in contracts). `Fixed`/`Changed` changelog entry.
- A `--dry-run` planner CLI is not part of this spec; the plan function is
  pure and testable, which is the same guarantee.

## Decisions

1. File-level moves, not a folder rename. Only per-file placement gives
   episode names Jellyfin does not have to guess, and handles nested packs.
2. Title and year from TMDB only; PTN for season and episode only. Same
   split as today, applied per file.
3. Leave non-media files behind and delete the source folder only when it
   holds no video. Rejected moving everything: junk in the library folder is
   what this spec removes. Rejected deleting unconditionally: a file we did
   not recognise as video should not vanish.
4. Extras subfolder for secondary movie videos. Rejected leaving them beside
   the main file: Jellyfin then shows samples and featurettes as versions.
5. Whole-job failure on any unparseable episode. See Shows step 3.
6. No existing-library migration in this spec (non-goal).

## Open questions

1. Delete the residual source folder when it has no video files, or leave
   every folder for a human? The design says delete; say so if you would
   rather keep them.

## Test plan

Pure planner tests in `tests/test_rename.py`, no disk: movie single file,
movie folder with sidecars and a sample, movie companions, show season pack,
show multi-episode file, specials to `Season 00`, multi-season nested pack,
unparseable episode fails whole job, title sanitising, missing year,
idempotent skip of existing destinations. Mover tests with `tmp_path`:
moves, skips existing, deletes an emptied source folder, keeps one with a
leftover video. Worker test: `dest_path` set to the scan folder.

## Rollout

One orchestrator PR; `Changed` changelog entry; minor release; verify on the
next real movie and the next real show download before touching #20.
