# Spec: redo a bad download, search again and replace the original

Status: Approved
Issue: MickMarch/medialab#92

## Problem

A finished download can be wrong: bad quality, wrong cut, a mislabeled
file. Fixing it today is three separate actions in the right order: delete
the job, search again, download again, and the delete must be confirmed
before the replacement even exists. If the new search finds nothing, the
original is already gone.

## Goal and non-goals

Goal: **Redo** on a finished job. It reruns the torrent search with the
job's scope, the user picks another torrent, and only then does medialab
delete the original and start the replacement as a new job linked to the
old one. Web only.

Non-goals: automatic quality upgrades; redo for jobs that never finished
(retry and delete cover those); redo from the bot.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-orchestrator | `POST /jobs/{id}/redo`: delete the original and submit the replacement as one action; `redo_of` on the job |
| medialab-web | Redo button, the search step with the scope preset, the confirm step |

### orchestrator

`pipeline_job` gains `redo_of TEXT` (nullable, the replaced job's id).

| Method | Path | Behaviour |
|---|---|---|
| POST | `/jobs/{id}/redo` | body `DownloadRequest` (the newly picked torrent); refuses unless the job is `DONE` (409); computes the deletion plan for the old job and refuses if the plan is refused (409); creates the new job first with `redo_of = id`, `season` and `episode` copied from the old job; executes the old job's deletion plan (the existing `DeletionService`); submits the new download; returns 202 `DownloadResponse` with the new job |

Order matters: create the new row, delete the old, submit the new. If the
deletion fails partway, the new job exists in `DOWNLOAD_SUBMITTED` with no
transfer and the old job is not `DELETED`; the response is 502 and both
jobs are visible, so nothing is silently lost. The user can retry the
redo, which reuses the same replacement job when one with `redo_of = id`
and no hash already exists.

`GET /jobs/{id}` and the jobs list expose `redo_of`, and the old job's view
gains `redone_by: str | None` computed on read.

The watchlist (#24) records a follow submission against the replacement
job when its job is redone, so the episode stays "already submitted".

### medialab-web

- Job row (`DONE` only): **Redo**. It opens the torrent step in `#stage`
  with the job's title, year, media type, tmdb id, season and episode
  preset, and a notice "Picking a torrent replaces the original download".
- The torrent step's Download button, when reached through Redo, posts to
  `POST /partials/jobs/{id}/redo` with the picked torrent, which calls the
  gateway redo route and re-renders the jobs table.
- The old row shows `Replaced by <new job>` once redone; the new row shows
  `Redo of <old job>`.

### medialab-bot

Unchanged.

## Decisions

1. **Delete after the pick, not before.** Rejected: delete then search;
   a search that finds nothing would leave the library without the title.
2. **One gateway action for delete plus submit.** Rejected: the web calling
   `DELETE /jobs/{id}` then `POST /download`; two calls cannot be made
   atomic from the client, and the link between the jobs would be lost.
3. **New job first.** Rejected: delete first then create; a crash between
   the two leaves no record that a replacement was intended.
4. **Redo only for `DONE`.** Rejected: any status; a job still in the
   pipeline is either retryable or deletable already, and redoing it would
   race the worker.
5. **Web only.** The bot is for remote downloading; a two-step replace with
   a confirmation belongs in the web UI.

## Open questions

None.

## Test plan

- **orchestrator**: redo refused on non-`DONE` (409) and on a refused
  deletion plan (409); success creates the new job with `redo_of`, season
  and episode, marks the old `DELETED`, submits the download, returns the
  new job; a deletion failure returns 502 with both jobs present and the
  replacement reused on the next attempt; `redone_by` on the old job.
- **web**: Redo appears only on `DONE` rows; it opens the torrent step with
  the job's scope; picking posts to the redo partial; rows show the links.

## Rollout

1. orchestrator PR (`redo_of` via `_ADDED_COLUMNS`); depends on the
   `season` and `episode` columns from the show browser (#91).
2. web PR.
3. Release both, bump root pins, redeploy. No host step.
