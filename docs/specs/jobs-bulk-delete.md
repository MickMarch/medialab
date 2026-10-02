# Spec: delete several jobs at once from the Jobs page

Status: Shipped
Issue: MickMarch/medialab#105

## Problem

Deleting a download is one job at a time: Delete, read the plan, confirm,
and the row swaps. That is right for one wrong pick. It is painful for the
common clean-up, a whole season or a show followed by mistake, where every
episode is its own job and the same three taps repeat ten or twenty times
on a phone.

## Goal and non-goals

Goal: on the Jobs page, a Select mode reveals a checkbox per row. A sticky
bottom bar shows how many are selected and offers Delete selected. Pressing
it shows one confirmation listing what will be removed for every selected
job, then one press deletes them all, each exactly as the single delete
does today. Jobs the single delete would refuse are listed as refused and
left alone; the rest still go.

Non-goals: deleting from the bot (multi-step and stateful; web-only per the
UI scope rule); deleting by show or season as a unit (the user picks rows);
bulk retry or bulk redo; undo; changing what a single delete removes.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-orchestrator | the bulk plan and bulk delete endpoints, reusing `plan_deletion` and `DeletionService` per job |
| medialab-web | Select mode, the bottom bar, the combined plan, the result notice |
| medialab-contracts | unchanged (see decision 4) |
| medialab-bot | unchanged |

### orchestrator

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/jobs/deletion-plan` | `{"job_ids": [...]}` | `BulkDeletionPlanView`: `plans`, one `JobDeletionPlanView` per requested id in request order |
| POST | `/jobs/delete` | `{"job_ids": [...]}` | `BulkDeleteView`: `results`, one `JobDeleteResultView` per requested id in request order |

- `JobDeletionPlanView`: `job: JobView | None` (None when the id is
  unknown), `plan: DeletionPlanView` (an unknown id yields a plan with
  `refused = "no such job"`). No side effects, same as the single plan.
- `JobDeleteResultView`: `job_id`, `job: JobView | None` (the DELETED job
  on success), `error: str | None` (the refusal reason, "no such job", or
  the downstream failure message).
- `/jobs/delete` runs the ids one after another, each through
  `DeletionService.execute` followed by
  `watchlist.ignore_submission_for_job`, exactly like `DELETE /jobs/{id}`.
  A refusal or a downstream failure on one job is recorded in its result
  and the loop continues; the response is `200` whenever the request itself
  was valid. Nothing is deleted twice: a job already DELETED is reported
  as refused by `plan_deletion`, as today.
- `job_ids` is deduplicated, must hold at least one id and at most
  `BULK_JOBS_MAX` (a named constant, 100); otherwise `422 INVALID_INPUT`.
- Same auth and rate limit as the other job routes.

### medialab-web

- **Select mode.** A `Select` toggle button in the Jobs toolbar. Pressing it
  adds a `select-mode` class to the `#jobs` section. In that mode each row
  shows a checkbox (`name="job_ids"`, value the job id) in a new first
  column; a DELETED row has no checkbox. The per-row Delete, Retry and Redo
  buttons stay. Pressing the toggle again, or Cancel in the bar, leaves
  select mode and clears the selection.
- **Polling pauses in select mode**, the same way it pauses while a single
  plan is open: the jobs poll trigger condition also requires no
  `.select-mode` on the page. Leaving select mode lets polling resume on
  its next tick.
- **Bottom bar.** A `#bulk-bar` element fixed to the bottom of the
  viewport, visible only in select mode. It holds "Jobs selected: N",
  a `Delete selected` button (disabled at N = 0) and `Cancel`. N is kept
  current by a `change` listener on `#jobs` (one inline `hx-on:change`
  on the section, no script file).
- **Combined plan.** `Delete selected` posts the checked ids to
  `POST /partials/jobs/plan` (web), which calls the gateway bulk plan and
  renders `partials/bulk_plan.html` into a `#bulk-plan` slot above the
  table: a card headed "Nothing has happened yet. Pressing Delete removes:"
  with one block per job (title and year or release name, then the same
  bullet list the single plan shows), refused jobs in their own section
  with the reason, a red `Delete N jobs` button counting only the
  deletable ones, and `Cancel`. The slot counts as an open plan for the
  polling pause (`.plan-slot`).
- **Execute.** The red button posts the deletable ids to
  `POST /jobs/delete` (web), which calls the gateway bulk delete, leaves
  select mode and re-renders the whole jobs table from a fresh `GET /jobs`
  with a notice: "Deleted N jobs" plus ", M could not be deleted" when any
  result carries an error, listing those by title with the reason.
- **Routes**

| Method | Path | Does |
|---|---|---|
| POST | `/partials/jobs/plan` | form `job_ids[]` -> gateway bulk plan -> `bulk_plan.html` |
| POST | `/jobs/delete` | form `job_ids[]` -> gateway bulk delete -> jobs table with the notice |

- **Client.** `OrchestratorClient` gains `bulk_deletion_plan(ids)` and
  `bulk_delete(ids)`; `schemas/jobs.py` gains the three views above.
- Phone: the bar spans the width with the count on the left and the two
  buttons on the right; the checkbox column is the leading inline block of
  the stacked row, so a row stays one tap target per control.

### medialab-bot

Unchanged. `/delete` remains the one-at-a-time remote path.

## Decisions

1. **Checkboxes and a sticky bar, not a long-press or swipe gesture.**
   Rejected: gestures need JavaScript the page does not have and are
   invisible until discovered. A Select toggle is the pattern every mail
   and photo app uses.
2. **One combined plan, not one confirmation per job.** Rejected: N
   confirmations is the pain this spec removes. The combined plan still
   shows every path before anything is removed, keeping decision 4 of the
   delete spec (plan-then-execute).
3. **Refused jobs are listed and skipped, not a reason to refuse the whole
   batch.** Rejected: all-or-nothing. A show with one pre-`placed_paths`
   episode would block deleting the other nine, and the user can read the
   refusal and clean that one by hand.
4. **New views live in the orchestrator's `schemas/jobs.py` and are copied
   to the web client, like `JobView` and `DeletionPlanView` today.**
   Rejected: moving them to medialab-contracts now. They embed `JobView`,
   which is not in contracts either; lifting the job views into contracts
   is its own chore and should move all of them together.
5. **`POST /jobs/delete`, not `DELETE /jobs` with a body.** Rejected: a
   DELETE with a JSON body is legal but some proxies and clients drop the
   body. A POST on a verb path is unambiguous.
6. **Sequential execution.** Rejected: running deletions concurrently.
   Each one talks to qBittorrent, the disk and Jellyfin; parallelism gains
   seconds on a clean-up the user does rarely and complicates the
   per-job error report.
7. **Polling pauses in select mode.** Rejected: keeping the poll running
   and re-applying the selection after each swap. The pause already exists
   for the single plan and loses nothing: the user is choosing, not
   watching progress.
8. **Web only.** Multi-select is stateful and multi-step; the UI scope rule
   puts it in the browser.

9. **Changing the status filter leaves select mode.** The table
   re-renders and the selection is cleared. Rejected: carrying the mode
   across; the filter form is outside the table and the user has already
   left the selection behind.

## Open questions

None.

## Test plan

- **orchestrator**: bulk plan returns one entry per id in request order,
  unknown id refused with "no such job", duplicates collapsed; empty list
  and more than `BULK_JOBS_MAX` ids are 422; bulk delete executes each
  deletable job and calls `ignore_submission_for_job` for it, records a
  refusal without stopping, records a downstream failure without stopping,
  returns 200 with per-job results; a job already DELETED is reported
  refused and untouched.
- **web**: Jobs page has the Select toggle and the hidden `#bulk-bar`; the
  table in select mode renders a checkbox per non-DELETED row and none for
  DELETED; the poll trigger pauses on `.select-mode`; `POST
  /partials/jobs/plan` renders a block per job with the same bullets as
  the single plan, refused jobs in their own section, and the red button
  counting only deletable ids; `POST /jobs/delete` calls the client with
  the ids, re-renders the table and shows "Deleted N jobs" with the refused
  list when any; client methods post the expected bodies (mocked at the
  client boundary).

## Rollout

1. orchestrator PR and release (minor).
2. web PR and release (minor). Redeploy. No host step.
