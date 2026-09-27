# Spec: live download progress, ETA and speed on active jobs

Status: Approved
Issue: MickMarch/medialab#86

## Problem

A job shows a status and nothing else while qBittorrent works on it. There is
no way to tell from the web jobs table or the bot's `/jobs` whether a download
is 2% or 98% done, how fast it is going, or when it will finish. The data
exists: torrent-downloader's `TransferInfo` already carries `progress`,
`eta_seconds`, `download_speed` and `state`. The orchestrator's `/transfers`
returns live transfers and jobs side by side but never joins them, and `/jobs`
returns stored rows only. The `DOWNLOADING` status (#85) moves only on the
health poll, so it can lag a download start by one poll interval.

## Goal and non-goals

Goal: every job waiting on qBittorrent (`DOWNLOAD_SUBMITTED` or `DOWNLOADING`)
carries live progress, ETA and speed whenever it is listed. The web jobs table
shows a progress bar with percent, speed and ETA, and refreshes faster while
anything is downloading. The bot's `/jobs` shows percent and ETA per active
job. Listing a job that qBittorrent is actively fetching moves it to
`DOWNLOADING` at once instead of on the next poll.

Non-goals: storing progress history; push updates (websockets, SSE, Discord
message edits on a timer); progress for pipeline steps after download
(rename, scan); upload or seeding stats.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `JobProgress`, `ETA_UNKNOWN_SECONDS` |
| medialab-orchestrator | joining transfers to active jobs on read; the shared forward-only `DOWNLOADING` rule |
| medialab-web | progress bar, speed, ETA; adaptive refresh |
| medialab-bot | percent and ETA in `/jobs` |

torrent-downloader is unchanged.

### Model (contracts)

`JobProgress`: `progress: float` (0.0 to 1.0), `download_speed: int` (bytes
per second), `eta_seconds: int | None`, `state: str` (qBittorrent state).
qBittorrent reports an unknown ETA as `8640000`; the orchestrator maps it to
`None`, named in contracts as `ETA_UNKNOWN_SECONDS`.

### Orchestrator

- `JobView` gains `progress: JobProgress | None = None`.
- `GET /jobs` and `GET /jobs/{id}`: if any returned job is `DOWNLOAD_SUBMITTED`
  or `DOWNLOADING` and has a `torrent_hash`, make one transfers read and attach
  `progress` to each job whose hash matches. No active job, no downstream call.
- If the transfers read fails, jobs are returned without `progress`. Listing
  never fails because qBittorrent or the downloader is down.
- The same read applies the #85 rule: a `DOWNLOAD_SUBMITTED` job whose
  transfer is in an active state moves to `DOWNLOADING`. The rule is one
  function used by both the health poll and the read, so they cannot drift.
- A job without a `torrent_hash` yet (a `.torrent` URL download before it is
  stamped) has no progress, as today.

### Web

- Jobs table, `DOWNLOAD_SUBMITTED` and `DOWNLOADING` rows: a `<progress>` bar
  under the status badge with `42% - 3.1 MB/s - ETA 12m`. ETA reads `-` when
  unknown; speed reuses the existing size formatter per second.
- Adaptive refresh: the jobs partial sets its own `hx-trigger` interval, a
  short interval while any listed job has progress and the existing
  `JOBS_REFRESH_SECONDS` otherwise. Both are named constants.
- Phone layout: the bar stacks with the rest of the row like the other cells.

### Bot

- `/jobs`: each active job line appends `42% - ETA 12m`, with a text bar made
  of block characters (fixed width, named constant). No emoji.
- `/transfers` is unchanged.

### ETA formatting

Both UIs format ETA the same way: under an hour `12m`, under a day `3h 05m`,
otherwise `2d 4h`. The formatter is a pure function in each UI; it is not
shared because it is presentation, and the rule is to extract only on a third
consumer.

## Decisions

1. **Read-through, not stored.** Rejected: writing progress to `pipeline_job`
   on every poll. Progress changes every second and is worthless a minute
   later; storing it adds writes and a column that is always stale.
2. **Attach to `/jobs` instead of a new route.** Rejected: a separate
   `/jobs/progress` route. Both UIs already list `/jobs`; a second call per
   refresh doubles requests and makes the UIs join the data themselves.
3. **A read may move a job to `DOWNLOADING`.** Rejected: leaving transitions
   to the poll only. The user sees "Submitted" next to a moving progress bar
   for up to one poll interval. The move is forward-only and idempotent, so
   doing it on read is safe.
4. **Adaptive refresh over push.** Rejected: SSE or websockets. HTMX polling
   is already how the page refreshes; a shorter interval only while something
   is downloading keeps load near zero when idle.
5. **Unknown ETA is `None`, not the sentinel.** Rejected: passing `8640000`
   through and letting each UI special-case it.

6. **The web short refresh interval is 5 seconds, a named constant.**
   Rejected: a runtime setting; nothing yet needs to tune it without a
   redeploy.

## Open questions

None.

## Test plan

- **medialab-contracts**: `JobProgress` round-trip; `eta_seconds` accepts
  `None`.
- **medialab-orchestrator**: `/jobs` with no active job makes no transfers
  call; an active job with a matching hash gets `progress` with fields mapped
  from the transfer; the unknown ETA sentinel becomes `None`; a job without a
  hash gets none; a failed transfers read returns jobs without progress and
  status 200; a `DOWNLOAD_SUBMITTED` job with an active transfer is returned
  and stored as `DOWNLOADING`; a queued transfer leaves it submitted; the
  health poll and the read call the same rule function.
- **medialab-web**: an active row renders a progress bar, percent, speed and
  ETA; an unknown ETA renders `-`; a row without progress renders no bar; the
  partial uses the short interval when any job has progress and the long one
  otherwise; the ETA formatter covers minutes, hours and days.
- **medialab-bot**: `/jobs` appends percent, ETA and the text bar for an
  active job and nothing for others; the ETA formatter covers the same cases.
  Client class mocked.

## Rollout

1. medialab-contracts PR and release.
2. medialab-orchestrator PR and release. The `JobView.progress` field is
   additive, so the current web and bot keep working.
3. medialab-web and medialab-bot PRs, in either order.
4. Release each, bump root pins, rebuild and redeploy. No host step.
