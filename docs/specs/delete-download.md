# Spec: /delete, undo a wrong download

Status: Draft
Issue: MickMarch/medialab#55

## Problem

A wrong pick (wrong film, wrong language, wrong cut) cannot be undone from
Discord. Cleaning up by hand means the qBittorrent UI, the download folder,
the placed files in the library, and a Jellyfin rescan, and any step missed
leaves a ghost: a red torrent, an orphan folder, or a library entry with no
file.

## Goal and non-goals

**Goal.** One command removes a job's download from everywhere it touched,
at whatever stage it is in, after showing exactly what will be removed and
asking once. The job row stays as a record of what happened.

**Non-goals.** Deleting library items that did not come through the
pipeline (no job row): that is a library browser, a different feature.
Deleting a series folder wholesale: only what this job placed is removed.
Undo of a delete.

## Design

### What a job may have left behind, by stage

| Job status | qBittorrent | On disk |
|---|---|---|
| `DOWNLOAD_SUBMITTED`, `DOWNLOADING` | torrent present, maybe partial | partial files under the download folder |
| `STOP_SEEDING` .. `RENAME` (mid-pipeline), `FAILED`, `NEEDS_ATTENTION` | torrent removed at STOP_SEEDING, or still present if it failed before | download folder still in place |
| `SCAN`, `DONE` | torrent removed | files placed in the library; download folder gone |

To remove exactly what a job placed, RENAME records it: a new job column
`placed_paths` (JSON list of destination paths, in-container) written when
the plan is applied. Existing DONE jobs have none; for them the delete falls
back to the movie folder (`dest_path`) for movies and refuses for shows with
a message saying which folder to clean by hand, since a series folder may
hold seasons from other jobs.

### torrent-downloader

`DELETE /transfers/{hash}` gains `?delete_files=true|false` (default
`false`, today's behaviour). `true` maps to `torrents_delete(delete_files=True)`:
qBittorrent removes the torrent and its files. `404` when the torrent is
already gone, as today.

### orchestrator: `DELETE /jobs/{id}`

Two-phase to support the confirmation:

- `GET /jobs/{id}/deletion-plan`: returns what a delete would do, computed
  without side effects: `{"torrent": bool, "download_folder": path|null,
  "placed_paths": [...], "scan_path": path|null, "refused": reason|null}`.
  The bot shows this before asking for confirmation.
- `DELETE /jobs/{id}`: executes that plan in order, each step idempotent:
  1. `DELETE /transfers/{hash}?delete_files=true` (404 is fine).
  2. Remove the download folder if it still exists (`media_root /
     source_path or release_name`).
  3. Remove every `placed_paths` entry that exists, then remove now-empty
     parent directories up to (not including) the library root.
  4. Jellyfin scan of the placed files' parent (movie folder's parent, or
     the series folder) with `update_type: Deleted`, so the library drops the
     item at once instead of on the next full scan. `JellyfinClient.scan`
     gains an `update_type` parameter.
  5. Job status `DELETED`, `last_error` cleared, `deleted_at` stamped.
     `DELETED` is terminal: the health poll ignores it, retry refuses it.
- A job with `refused` in its plan returns `409` with the reason.

### medialab-bot: `/delete`

1. `/delete` lists the last 25 jobs (newest first, any status except
   `DELETED`) in a Select, label `Title (Year)` or release name,
   description `status · when`.
2. Picking one fetches the deletion plan and posts it as an ephemeral
   message: the torrent line, the download folder, each placed file, and
   which Jellyfin path will be rescanned. Two buttons: **Delete** (red) and
   **Cancel**. The buttons time out after 60 s.
3. **Delete** calls `DELETE /jobs/{id}` and reports the result; **Cancel**
   edits the message to say nothing was changed.
4. A refused plan shows the reason and no Delete button.

### doctor / health

No change. A deleted job is not "needing attention".

## Decisions

1. Record `placed_paths` at RENAME rather than re-deriving them at delete
   time. Re-deriving would re-run the planner on a folder that no longer
   exists. Recording is exact and cheap.
2. Refuse rather than guess for pre-existing show jobs without
   `placed_paths`. Deleting a series folder can take out seasons from other
   downloads. Movies fall back to `dest_path` because a movie folder belongs
   to one job.
3. Keep the job row as `DELETED`. Rejected removing the row: the history of
   what was downloaded and undone is worth keeping, and the health poll needs
   a terminal status to skip.
4. Plan-then-execute over a single call with a `confirm=true` flag. The
   user must see the concrete paths before the destructive step; a flag
   proves nothing was shown.
5. Jellyfin is told `Deleted` for the parent path, not asked for a full
   library scan. Same endpoint the pipeline already uses.
6. Files are deleted through the downloader for anything qBittorrent still
   owns and through the orchestrator's media mount for anything it placed.
   Neither service deletes outside its own media root.

## Open questions

1. Confirmation button timeout: 60 s proposed. Say if you want longer.

## Test plan

Downloader: `delete_files` forwarded true/false, default false. Orchestrator:
`placed_paths` written at RENAME and migrated on old databases; deletion plan
for each stage (downloading, mid-pipeline, done movie, done show with and
without `placed_paths`); execute removes torrent, folder, placed files,
empties parents but never the library root, scans with `Deleted`, marks
`DELETED`; idempotent second delete; poll ignores `DELETED`; retry refuses.
Bot: `/delete` lists jobs, plan rendering, Delete calls the endpoint, Cancel
does not, refused plan has no Delete button.

## Rollout

Downloader PR (minor), orchestrator PR (minor), bot PR (minor). Verify live
by downloading a small wrong item on purpose and deleting it at the DONE
stage, then once mid-download.
