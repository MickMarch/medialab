# Spec: stuck and failed download remediation

Status: Draft
Issue: MickMarch/medialab#20

## Problem

The pipeline advances a job only when the qBittorrent completion webhook
fires. Anything that stops the webhook, or breaks after it, leaves a job
wedged with nobody watching. Four modes, all observed:

1. **Error during download.** qBittorrent flips the torrent to `error` or
   `missingFiles` (a transient write lock, a disk hiccup). The completion hook
   never fires; the job sits at `DOWNLOAD_SUBMITTED` forever.
2. **Error during a pipeline step.** RENAME or SCAN hits a locked file; the
   job goes `FAILED`. Recoverable today only by a human pressing retry.
3. **Error after completion, during seeding.** STOP_SEEDING pauses the
   torrent; the paused torrent still points at the download folder. Since
   the naming work, RENAME empties that folder for both libraries, so any
   later recheck errors permanently and the qBittorrent UI fills with red
   entries for downloads the library already has.
4. **Completed but unnoticed.** Two jobs in the live table
   (`0fea2c00…` and `d6ff5546…`, 2026-08-13) have hashes, complete torrents
   in qBittorrent, and status `DOWNLOAD_SUBMITTED`: the webhook was missed
   (the host, the relay, or the gateway was down at that moment). Nothing
   ever revisits them.

`docs/decisions/0003-webhook-plus-poll.md` already records that webhook-only
was the wrong absolute. This spec adds the poll.

## Goal and non-goals

**Goal.** Every job reaches `DONE` or a state a human is told about, without
a human noticing first. Transient failures heal themselves; genuine ones stop
retrying and are flagged. Completed downloads leave nothing behind in
qBittorrent.

**Non-goals.** Stalled or slow downloads (`stalledDL`, `metaDL`): they are
not errors and a resume does nothing; a stall timeout is a later item.
Push notifications to Discord: the bot is a thin client with no push
channel; `/jobs` shows flagged jobs and that is the surface for now.
Re-adding a torrent from its magnet: out of scope, a human decision.

## Design

### torrent-downloader: two per-hash actions

| Endpoint | Does | Idempotent |
|---|---|---|
| `POST /transfers/{hash}/resume` | `torrents_resume` on that hash. `404 TRANSFER_NOT_FOUND` if qBittorrent has no such torrent. | yes: resuming a running torrent is a no-op |
| `DELETE /transfers/{hash}` | `torrents_delete(delete_files=False)`: removes the torrent from qBittorrent, keeps the files. `404` if unknown. | yes: `404` on the second call is treated as done by the caller |

Both return the existing `{status, message}` envelope. The bulk
`POST /transfers/stop-seeding` stays for the `/stop-seeding` command.

### orchestrator: STOP_SEEDING removes instead of pausing

The pipeline step calls `DELETE /transfers/{hash}` for the job's own hash.
Once the pipeline owns the files there is no reason for qBittorrent to keep
a handle on them; removal is what makes mode 3 impossible and keeps the
qBittorrent UI clean. A `404` from the downloader means it was already
removed (retry after a partial run) and the step succeeds. The job records
`seeding_removed_at`.

Seeding policy: the containerization spec's "stop seeding N minutes after
100%, default 0" is honoured with N fixed at 0 here. A configurable delay is
that spec's follow-up; nothing here prevents it (the poll can defer the
delete until `completed_at + N`).

### orchestrator: health poll

A background `asyncio` task started in the app lifespan, every
`HEALTH_POLL_INTERVAL_SECONDS` (default `300`; `0` disables it, which is what
tests use). Each tick reads `GET /transfers` once and every non-terminal job,
joins them by hash, and applies the first matching rule per job:

| Job status | Transfer | Action |
|---|---|---|
| `DOWNLOAD_SUBMITTED` / `DOWNLOADING`, no hash yet | any | nothing (hash arrives from the downloader or the webhook) |
| `DOWNLOAD_SUBMITTED` / `DOWNLOADING` | `state` is `error` or `missingFiles` | mode 1: `POST /transfers/{hash}/resume`, `remediations += 1`. When `remediations` would exceed `AUTO_RESUME_MAX` (default `3`): `NEEDS_ATTENTION`, `last_error = "qBittorrent state <state> after N resumes"` |
| `DOWNLOAD_SUBMITTED` / `DOWNLOADING` | `progress >= 1.0` or a complete state (`uploading`, `stalledUP`, `queuedUP`, `pausedUP`, `stoppedUP`, `forcedUP`, `checkingUP`) | mode 4: run the pipeline exactly as the webhook would (`worker.process(hash)`), with the transfer's `name` as `release_name` when the job's is empty |
| `DOWNLOAD_SUBMITTED` / `DOWNLOADING` | absent from qBittorrent | `NEEDS_ATTENTION`, `last_error = "torrent no longer in qBittorrent"` |
| `FAILED` | any | mode 2: if `attempts <= AUTO_RETRY_MAX` (default `2`) run `worker.process(hash)`; otherwise `NEEDS_ATTENTION` keeping the existing `last_error` |
| `NEEDS_ATTENTION`, `DONE` | any | nothing |

One job is processed at a time; a tick that raises logs and moves on to the
next job, never to the next tick early. The downloader being unreachable
skips the tick.

### Job model

- New status `NEEDS_ATTENTION`: terminal until a human acts. `POST
  /jobs/{id}/retry` accepts it (same as `FAILED`) and resets `remediations`
  and `attempts` to zero so the automatic budget starts over.
- New columns `remediations INTEGER NOT NULL DEFAULT 0` and
  `seeding_removed_at TEXT NULL`, added with `ALTER TABLE` at startup when
  missing (SQLite, no migration tool; the store already creates the table
  idempotently).
- `GET /jobs?status=NEEDS_ATTENTION` works by construction.
- `GET /health` gains `"needs_attention": <count>` so the doctor and the bot
  can surface it without a second call.

### bot

- `/jobs` already lists any status. The retry control (`JobRetryView`) is
  shown for `NEEDS_ATTENTION` as well as `FAILED`.
- The startup health log line prints the `needs_attention` count when it is
  non-zero. No new command.

### doctor

`bin/medialab-doctor.sh` reports `needs_attention` from the gateway health
as a warning row (does not fail the doctor: the stack is up, a job wants a
human).

## Decisions

1. Poll in the orchestrator's own process, not a new service or a cron. It
   already holds the store and both clients; the interval is minutes, not
   seconds. Reverses the MVP's "no polling" per decision 0003.
2. Remove the torrent at STOP_SEEDING, do not pause. Pausing was the root of
   mode 3 and is now incompatible with the naming layout. Files are never
   deleted by the downloader (`delete_files=False`).
3. Per-hash downloader endpoints, not orchestrator-side qBittorrent calls.
   The downloader is the only holder of the qBittorrent credential.
4. `NEEDS_ATTENTION` is a job status, not a derived flag. It must survive
   restarts, be filterable, and stop the poll from retrying; a flag on a
   read-through would do none of those.
5. Bounded budgets (`AUTO_RESUME_MAX`, `AUTO_RETRY_MAX`) reset by a human
   retry. Rejected unbounded auto-retry: it hides genuine failures forever.
6. Mode 4 reuses the webhook path verbatim. The poll is a second trigger for
   the same idempotent pipeline, not a second pipeline.
7. Stalls are out of scope (non-goal). Rejected treating `stalledDL` as an
   error: a resume changes nothing and the budget would burn on a healthy
   but slow torrent.

## Open questions

1. `HEALTH_POLL_INTERVAL_SECONDS` default `300`. Five minutes is quick enough
   for a media pipeline and negligible load. Say so if you want a different
   default.
2. The two 2026-08-13 jobs will be picked up by mode 4 on the first tick
   after deploy and run through the pipeline, which will rename and move
   those two movie folders into the new layout. That is the intended
   behaviour; flagging it so it is not a surprise.

## Test plan

torrent-downloader: route tests for resume and delete (calls the client with
the hash, `404` mapping, `delete_files=False` asserted).

orchestrator, `tests/test_health_poll.py`: one test per table row above with
a mocked transfers payload and an in-memory store; budget exhaustion flips
to `NEEDS_ATTENTION`; retry resets the budget; a raising job does not stop
the tick; unreachable downloader skips the tick; interval `0` never
schedules. STOP_SEEDING step: calls delete with the job's hash, treats `404`
as success, stamps `seeding_removed_at`. Store: columns added on an existing
database file. Health: `needs_attention` count.

bot: retry view offered for `NEEDS_ATTENTION`; startup log includes the
count.

## Rollout

1. torrent-downloader PR, minor release.
2. orchestrator PR (bump the downloader is not pinned; it is a runtime
   dependency), minor release. First tick processes the two 2026-08-13 jobs:
   verify both reach `DONE` and the folders are in the new layout.
3. bot PR, minor release. Doctor row in the same root PR as the spec status.
