# Spec: dismiss jobs that need attention

Status: Draft
Issue: MickMarch/medialab#121

## Problem

`NEEDS_ATTENTION` is where the health poll parks a job once its automatic
budget is spent (see `stuck-download-remediation.md`). The only action the
web and the bot offer on such a row is Retry. Retry re-enters the worker
from the last good state, which presumes the torrent still exists.

Observed on 2026-10-03: 16 jobs flagged. 13 were Vikings S06 episodes
flagged `torrent no longer in qBittorrent` at the qBittorrent
containerization cutover; their torrents lived in the old host qBittorrent
and never migrated, so nothing was downloaded. Retry cannot succeed for
them: there is no transfer to resume and no files to rename. Redo refuses
them because it accepts only `DONE`. Delete would clear the row but records
`DELETED`, which claims media was removed when nothing was ever placed.

The result is a list that only grows, an attention count that stops meaning
anything, and the bot's startup warning repeating a number nobody can act
on.

## Goal and non-goals

**Goal.** Every `NEEDS_ATTENTION` row offers an action that can actually
end its attention state, and a human can close out a job they have judged
not worth pursuing without lying about what happened to it. The record, the
error, and the decision all stay visible.

**Non-goals.** Hiding or purging job history: a dismissed job is still a
job. Automatic dismissal by age or by error class: the whole point of the
status is that a human decided. Fixing the causes behind the current
flagged jobs (#120 covers the rename case).

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-orchestrator | `DISMISSED` status, `dismissed_at`, the single and bulk dismiss routes, the Redo gate relaxation, the attention count |
| medialab-web | Dismiss on the row and in the bulk bar, cause-aware actions on attention rows, the `DISMISSED` filter |
| medialab-bot | Dismiss button beside Retry in `/jobs` |
| medialab-contracts | unchanged (job status lives in the orchestrator store, as today) |

### orchestrator

#### Job model

- New status `DISMISSED`: terminal, never retried, never polled. Reached
  only from `NEEDS_ATTENTION` or `FAILED`, only by a human.
- New column `dismissed_at TEXT NULL`, added with `ALTER TABLE` at startup
  when missing, like `seeding_removed_at`.
- `last_error` is kept as it was at dismissal. `placed_paths` is kept.
- The health poll's terminal set gains `DISMISSED`.
- `GET /health` `needs_attention` is unchanged in meaning (count of
  `NEEDS_ATTENTION`); dismissed jobs leave it by construction.

Lifecycle, additions only:

```
NEEDS_ATTENTION --dismiss--> DISMISSED
FAILED          --dismiss--> DISMISSED
NEEDS_ATTENTION --redo (nothing placed)--> DELETED, replacement created
DISMISSED       --delete--> DELETED (when the job placed files or a
                             download folder remains)
```

#### Routes

| Method | Path | Body | Behaviour |
|---|---|---|---|
| POST | `/jobs/{id}/dismiss` | none | `409 JOB_NOT_DISMISSABLE` unless status is `NEEDS_ATTENTION` or `FAILED`. Sets `status = DISMISSED`, `dismissed_at = now`. Marks the job's watchlist submission ignored (same call as delete). Returns `200 JobView`. Idempotent: dismissing a `DISMISSED` job returns `200` unchanged. |
| POST | `/jobs/dismiss` | `{"job_ids": [...]}` | Bulk form of the above, same shape and rules as `POST /jobs/delete`: one result per id in request order, per-id `error` for a refusal or an unknown id, `200` whenever the request itself is valid, `BULK_JOBS_MAX` reused. |
| POST | `/jobs/{id}/redo` | `DownloadRequest` | Gate relaxed: accepted when status is `DONE` (as today) or `NEEDS_ATTENTION` with `placed_paths` empty. The deletion plan for such a job removes the download folder if one remains and nothing else; the original ends `DELETED` and the replacement carries `redo_of`, exactly as for a `DONE` redo. |
| POST | `/jobs/{id}/retry` | none | Unchanged, except `409 JOB_NOT_RETRYABLE` when the job is `DISMISSED` or `DELETED`. |

`GET /jobs?status=DISMISSED` works by construction. `JobView` gains
`dismissed_at` and a derived, read-only `attention_cause`:

| `attention_cause` | When |
|---|---|
| `TORRENT_GONE` | `last_error` is the health poll's "torrent no longer in qBittorrent" and `placed_paths` is empty |
| `DOWNLOAD_ERROR` | `last_error` begins with the health poll's "qBittorrent state" message |
| `RENAME` | `last_error` begins with `RENAME:` |
| `SCAN` | `last_error` begins with `SCAN:` |
| `OTHER` | anything else |
| `null` | status is not `NEEDS_ATTENTION` or `FAILED` |

The poll and the worker already write these prefixes; this spec names them
as constants in one module so the view and the writers cannot drift.

#### Deletion plan

`plan_deletion` treats `DISMISSED` like `NEEDS_ATTENTION` today: refused
when there is nothing on disk to remove, otherwise the folder and the
placed paths. A dismissed job with nothing on disk therefore cannot be
deleted, and does not need to be.

### medialab-web

- **Row actions by cause.** On a `NEEDS_ATTENTION` or `FAILED` row the
  action set comes from `attention_cause`:

| Cause | Actions |
|---|---|
| `TORRENT_GONE` | Redo, Dismiss |
| `DOWNLOAD_ERROR`, `RENAME`, `SCAN`, `OTHER` | Retry, Dismiss |

  Delete stays where it is offered today. Redo on an attention row opens
  the same torrent step as Redo on a `DONE` row, with the notice "Picking a
  torrent replaces the failed download".
- **Dismiss** posts to `POST /jobs/{id}/dismiss` (web), which calls the
  gateway and re-renders the row with the notice "Dismissed." The row then
  shows status `DISMISSED` and only Delete when deletable.
- **Bulk bar.** Select mode gains `Dismiss selected` beside `Delete
  selected`. It posts the checked ids to `POST /jobs/dismiss` (web), which
  calls the gateway bulk dismiss, leaves select mode and re-renders the
  table with the notice "Dismissed N jobs" plus ", M could not be
  dismissed" listing those by title with the reason. No plan step: dismiss
  touches no files.
- **Filter.** The status filter lists `DISMISSED`. The default view shows
  dismissed rows, muted like `DELETED` rows.
- **Routes**

| Method | Path | Does |
|---|---|---|
| POST | `/jobs/{id}/dismiss` | gateway dismiss -> `job_row.html` |
| POST | `/jobs/dismiss` | form `job_ids[]` -> gateway bulk dismiss -> jobs table with the notice |

- **Client.** `OrchestratorClient` gains `dismiss_job(id)` and
  `bulk_dismiss(ids)`; the job schema gains `dismissed_at` and
  `attention_cause`.

### medialab-bot

`/jobs` already attaches `JobRetryView` when the result holds a flagged
job. The view gains a Dismiss button per flagged job beside Retry; pressing
it calls `POST /jobs/{id}/dismiss` and edits the message to show the new
status. No new command. Redo stays web-only per the UI scope rule.

### doctor

Unchanged. `needs_attention` already excludes dismissed jobs.

## Decisions

1. **A status, not a flag or a deletion.** Rejected: a `dismissed`
   boolean on `NEEDS_ATTENTION`. Every consumer (poll, count, filters, bot)
   keys on status; a flag would need a second check everywhere and would
   still show the row as needing attention. Rejected: reuse `DELETED`. It
   asserts media was removed; for most of these jobs nothing was ever
   placed, and the deletion plan refuses them for exactly that reason.
2. **Human only.** Rejected: auto-dismiss after N days or for
   `TORRENT_GONE`. The remediation spec bounded automatic retries so
   genuine failures are seen by a person; auto-dismissing them would undo
   that and is the silent failure this workspace forbids.
3. **Dismiss is not a hide.** Rejected: dropping dismissed rows from the
   default list. They stay, muted, filterable. The record of what failed
   and that someone chose to stop is part of the job history.
4. **Redo accepts `NEEDS_ATTENTION` only when nothing was placed.**
   Rejected: any `NEEDS_ATTENTION`. A job that placed some files and then
   failed at scan has media in the library; replacing it is a `DONE`-style
   redo after a successful retry, not a shortcut around it. Rejected:
   keeping the `DONE`-only gate. It leaves `TORRENT_GONE` jobs with no
   resolving action at all, which is the observed problem.
5. **Cause derived on read, not stored.** Rejected: a new `cause` column.
   The poll and the worker already encode the cause in `last_error`; a
   column would be a second source of truth. Deriving from named prefix
   constants keeps one writer per message.
6. **Watchlist submission goes ignored on dismiss.** Rejected: leaving it
   wanted. The follow poll would resubmit the episode on its next tick,
   re-creating the job the user just dismissed. Same rule as delete.
7. **No confirmation step for dismiss.** Rejected: a plan card like
   delete's. Dismiss touches no files and is reversible in effect: the job
   can still be deleted, and the title can be searched again.

## Open questions

1. Should Retry remain available on a `TORRENT_GONE` row as a secondary
   action, for the case where the user re-adds the torrent to qBittorrent
   by hand? Proposal: no; the health poll's completed-but-unnoticed rule
   already picks up a re-added torrent on the next tick.
2. Should a `DISMISSED` job be re-openable (back to `NEEDS_ATTENTION`)?
   Proposal: no; Redo or a fresh download covers every real case, and a
   reverse transition adds a state nobody asked for.

## Test plan

orchestrator, `tests/test_dismiss.py`: dismiss from `NEEDS_ATTENTION` and
`FAILED` sets status and timestamp and marks the submission ignored;
dismiss from `DONE`, `DOWNLOADING`, `DELETED` returns 409; dismissing a
`DISMISSED` job is a 200 no-op; bulk dismiss reports per-id results in
order with unknown ids and refusals as errors; `BULK_JOBS_MAX` enforced.
`tests/test_health_poll.py`: a `DISMISSED` job is never touched. `tests/
test_redo.py`: redo accepted for `NEEDS_ATTENTION` with empty
`placed_paths`, refused with non-empty; original ends `DELETED`, replacement
carries `redo_of`. `tests/test_jobs_view.py`: `attention_cause` for each
prefix and `null` for other statuses. Store: `dismissed_at` added to an
existing database file. Retry: 409 for `DISMISSED`.

medialab-web, `tests/test_jobs.py`: row renders Redo and Dismiss for
`TORRENT_GONE`, Retry and Dismiss otherwise; dismiss route re-renders the
row with the notice; bulk dismiss route calls the client with the ids and
renders the count notice; `DISMISSED` rows carry the muted class; status
filter offers `DISMISSED`.

medialab-bot, `tests/test_jobs_cog.py`: the view holds a Dismiss button per
flagged job; pressing it calls `dismiss_job` on the mocked client and edits
the message.

## Rollout

1. orchestrator PR: status, column, routes, redo gate, view fields. Minor
   release.
2. web PR against the released gateway. Minor release.
3. bot PR. Minor release.
4. Manual: on the Jobs page, select the 13 Vikings rows and either Redo
   the wanted episodes one by one or Dismiss them. Retry the two Rick and
   Morty jobs once #120 ships.
