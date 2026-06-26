# medialab-orchestrator spec (draft - pre-repo)

Status: FROZEN DRAFT (2026-06-26). Design locked for now, no repo/code yet -
captured as a saved state, still subject to revision before build. Once
approved for build, this content moves into
`medialab-orchestrator/CLAUDE.md` under a "Planned endpoints" section (same
pattern medialab-jellyfin used pre-implementation), the repo/submodule get
created, and the dependent cross-service changes get sequenced.

## What this service is

A **front-door orchestrating gateway**. The Discord bot talks to exactly one
service - the orchestrator. The orchestrator brokers the entire media
lifecycle (search -> pick -> download -> seed-stop -> rename -> register ->
scan) and fans out to the downstream worker services. torrent-downloader and
medialab-jellyfin become pure downstream workers that are never client-facing.

```
BEFORE (split gateway):
  bot ──> torrent-downloader ──> qBittorrent
  bot ──> (post-download only) orchestrator ──> medialab-jellyfin ──> Jellyfin

AFTER (front-door gateway - this design):
  Discord user
      │ slash command
  medialab-bot ──> medialab-orchestrator ──┬──> torrent-downloader ──> qBittorrent + TMDB
   (one dependency)        │ (the gateway)  └──> medialab-jellyfin   ──> Jellyfin
                           └── owns the job lifecycle (SQLite)
```

### Why this shape (portfolio-relevant)

- **One client-facing gateway, downstream services never exposed.** A
  recognized API-gateway / orchestration pattern - intent is legible to a
  reviewer.
- **One job record spans the whole lifecycle**, not just the post-download
  tail. The job table is the system's spine.
- **The bot collapses to a single dependency.** It no longer holds
  torrent-downloader *and* jellyfin URLs/keys, nor save-path config, nor
  cross-service health checks. All of that moves behind the gateway where it
  belongs - this dissolves the bot tech-debt noted in the root CLAUDE.md.
- **One-time effort.** Building the bot against the gateway now avoids a
  later cross-repo refactor to peel it off torrent-downloader.

### Honest trade-off (documented, not hidden)

Search is a stateless TMDB lookup - the gateway proxies it without creating
state, so those endpoints are thin forwards whose only value is gateway
consistency (one bot-facing surface). Every **stateful** endpoint
(download, status, pipeline) binds to a job record - that is where the
orchestrator earns its name. If an endpoint would be a pure forward that
touches no job state and adds no gateway value, that is the signal it should
not exist here. Search is the sole accepted exception, kept for "bot has one
dependency."

## Stack / repo

New independent repo, submodule pinned in root `medialab/` like the other
three. Same stack: FastAPI, `uv`, `hatchling` + `hatch-vcs`,
`pydantic-settings`, `pytest`. Same conventions: `X-API-Key` auth,
`{"status": "error", "code": ..., "detail": ...}` error shape, `slowapi`
rate limiting, `X-Request-ID` request logging, health-check reachability
reporting.

Deps unique here: stdlib `sqlite3` (job store), `PTN` (season number only),
an async HTTP client (`httpx`) for downstream fan-out, and `medialab-contracts`
(shared Pydantic models - `MediaType`, error shape, job/transfer DTOs).

Engineering standards (root CLAUDE.md "Engineering standards") apply from the
first commit: ruff lint+format, mypy gate, pre-commit, CI running
lint -> typecheck -> test, Keep-a-Changelog, dependabot + pip-audit.

## Core architecture decisions (and why)

1. **Front-door gateway** (above) - one client-facing surface, downstream
   workers never exposed.
2. **Job state table (SQLite), not a sync call chain.** Webhook + download
   submit record/advance jobs through explicit states. Durability (survives
   restart), observability (`GET /jobs`), retry. The difference between an
   orchestrator and a relay.
3. **SQLite, not Postgres.** Single-host homelab, handful of jobs/day.
   Lightest durable, queryable store that fits the scale. Choosing it (over
   Postgres) is the signal, not a limitation.
4. **In-process asyncio worker, not Celery/Redis.** No external broker for
   low-volume single-host work. FastAPI `lifespan` starts an asyncio task that
   advances jobs. Redis + worker container here would be over-engineering.
5. **TMDB id captured at download, threaded through - no title guessing.** The
   bot already knows the TMDB id (user picked the search result). It flows
   bot -> orchestrator -> torrent-downloader (cached vs hash) -> back to
   orchestrator at completion. Orchestrator gets exact canonical
   `Title (Year)` from TMDB. PTN is used only for the **season number**.
6. **Shared media volume, not host shell-out.** Host media dir bind-mounted
   into the orchestrator container; file moves go through the mount, not a
   host shell. Cleaner container boundary. (Single-host trade-off documented;
   multi-host would need shared storage.)
7. **One TMDB key owner.** Orchestrator resolves title/year via
   torrent-downloader's existing `/search/tmdb/...` endpoints, not TMDB
   directly. torrent-downloader stays sole TMDB-key holder.

## Bot-facing endpoints (the gateway surface)

All under `/api/v1`, all require the orchestrator's `X-API-Key`. These mirror
the bot's slash commands.

### Search (stateless proxies to torrent-downloader)
- `GET /search/tmdb` - forwards to torrent-downloader TMDB multi-search.
- `GET /search/tmdb/{movie|show}/{tmdb_id}` - forwards to detail endpoints.
- `GET /search/torrents` - forwards to torrent-downloader qBittorrent search.

No job created here (job is born at download submit). Pure passthrough; value
is single-gateway consistency.

### Download (creates a job)
- `POST /download` - body carries `magnet_uri`, `media_type`, `tmdb_id`.
  Orchestrator:
  1. inserts `pipeline_job(status=DOWNLOAD_SUBMITTED, tmdb_id, media_type, ...)`
  2. forwards to torrent-downloader `POST /download` (which caches
     `{media_type, host_path, tmdb_id}` vs the torrent hash - v1.2)
  3. returns the job id/hash to the bot
  The job now exists and the bot tracks it by hash.

### Status / observability
- `GET /transfers` - live transfer state. Orchestrator joins
  torrent-downloader's live `/transfers` with its own job rows so the bot sees
  one merged view (download progress + pipeline state).
- `GET /jobs` (filter by `status`) - the lifecycle view. Demoable,
  screenshottable, proves orchestration.
- `GET /jobs/{hash}` - single job detail incl. `last_error`, `attempts`.
- `POST /jobs/{hash}/retry` - re-enter the worker from last good state.
- `GET /storage` - forwards to torrent-downloader disk usage.

### Health
- `GET /api/v1/health` - public, no auth. Reports reachability of both
  downstream services. The bot's single cross-service health signal (replaces
  the bot's current direct torrent-downloader health check).

## Webhook (post-download entry)

### `POST /webhooks/torrent-complete`
Called by `scripts/notify_complete.py` (run by qBittorrent's "Run external
program on torrent completion" hook). Body `{hash, name}`. Finds the existing
job by hash (created at download submit), advances it from DOWNLOADING into
the post-download pipeline. Returns `202` immediately - never blocks
qBittorrent. If no job matches the hash (e.g. download predated the gateway),
it inserts one so the event is still tracked.

Why a relay script: qBittorrent's completion hook execs a local process with
`%I` (hash) / `%N` (name) - it cannot make an HTTP call itself.
`notify_complete.py` is a dumb relay (no business logic) that turns those args
into one POST. All real logic stays in the service, pytest-testable.

## Job lifecycle (SQLite `pipeline_job`)

Full lifecycle, search through scan:

```
DOWNLOAD_SUBMITTED   (POST /download accepted, forwarded to torrent-downloader)
DOWNLOADING          (qBittorrent working; updated from /transfers polling or left until webhook)
STOP_SEEDING         (webhook received -> POST torrent-downloader /transfers/stop-seeding)
RESOLVE_META         (GET /transfers/{hash}/info -> media_type, host_path, tmdb_id;
                      GET /search/tmdb/{type}/{tmdb_id} -> canonical title + year)
RENAME               (TV: PTN(name)->season; move host_path/<name> -> host_path/Title (Year)/Season NN/.
                      movie: no move, path = host_path/<name>)
REGISTER             (POST medialab-jellyfin /library/paths, idempotent)
SCAN                 (POST medialab-jellyfin /library/scan)
DONE
FAILED               (any step error; last_error stored; retryable)
```

Columns (MVP): `id`, `torrent_hash` (unique), `release_name`, `media_type`,
`tmdb_id`, `resolved_title`, `resolved_year`, `source_path`, `dest_path`,
`status`, `last_error`, `attempts`, `created_at`, `updated_at`.

State advanced one step at a time, persisted after each transition, so a
restart resumes from the last committed state.

## Idempotency (required for safe retry)

- STOP_SEEDING: stopping an already-stopped torrent is a no-op.
- RESOLVE_META: pure reads.
- RENAME: if `dest_path` populated and exists, skip the move.
- REGISTER / SCAN: Jellyfin path-register and scan are both safe to repeat.

## TV folder rename detail

- Jellyfin convention: `Series Name (Year)/Season NN/` (zero-padded, never
  `S01`).
- Title + year from **TMDB** (via torrent-downloader), not PTN.
- PTN parses `release_name` for the **season number only**.
- `host_path` from `/transfers/{hash}/info` is the media-type **root** (e.g.
  `/media/Shows` in-container via the shared mount), not torrent-specific.
  Downloaded folder is `host_path/<release_name>`.
- No season parseable: mark FAILED with clear `last_error`; operator fixes the
  folder and calls `retry`. No silent half-processing.
- Movies: no rename; `dest_path = host_path/<release_name>`.

## Cross-service changes this design requires

Multi-repo change. Sequencing matters. (Full ordering in root CLAUDE.md
roadmap - the two prerequisites below, engineering-standards backfill and
`medialab-contracts`, precede the orchestrator there.)

0a. **engineering-standards backfill** - ruff/mypy/pre-commit/CI-lint across all
    services (+ medialab-bot's missing workflow), dependabot, Keep-a-Changelog.
    Not orchestrator-specific but lands first; the orchestrator repo adopts all
    standards from commit one. See root CLAUDE.md "Engineering standards".
0b. **medialab-contracts** - shared Pydantic models (`MediaType`, error shape,
    job/transfer DTOs). The orchestrator, torrent-downloader v1.2, and the bot
    all import from it instead of redefining schemas. Stand up before v1.2.
1. **torrent-downloader v1.2** (orchestrator depends on it):
   - `POST /download` accepts `tmdb_id` alongside `media_type` (both from the
     shared `medialab-contracts` `MediaType`).
   - cache `{media_type, host_path, tmdb_id}` vs hash.
   - `GET /transfers/{hash}/info` returns `tmdb_id` (shared transfer-info DTO).
   - Additive, backward-compatible.
2. **medialab-bot** (rewrite its client layer): point every call at the
   orchestrator instead of torrent-downloader; drop torrent-downloader +
   jellyfin URLs/keys, save-path config, and the direct health check. Bot ends
   with one downstream dependency. This is the bulk of the bot tech-debt
   cleanup, done here rather than later.
3. **root `docker-compose.yml`** (new): shared Docker network; bind-mount host
   media dir into orchestrator; per-service `env_file:` (no shared root
   `.env`). Roadmap put compose "once orchestrator exists" - that's now.
4. **medialab-orchestrator** (new repo): everything above.

## Config (`core/config.py` / `.env`)

- `API_KEY` - the gateway's own key (bot uses this).
- `TORRENT_DOWNLOADER_URL`, `TORRENT_DOWNLOADER_API_KEY`
- `MEDIALAB_JELLYFIN_URL`, `MEDIALAB_JELLYFIN_API_KEY`
- `MEDIA_MOUNT_PATH` - in-container path of the mounted host media dir (e.g.
  `/media`), used to compute move source/dest.
- `DB_PATH` - SQLite file (default e.g. `./data/orchestrator.db`).

`scripts/notify_complete.py` reads its own minimal env (`ORCHESTRATOR_URL`
+ key if the webhook is authenticated) - it runs as a qBittorrent child
process, outside the service container.

## Out of scope for MVP (explicitly deferred)

- Jellyfin host power-on / wake (WoL/smart-plug) - assume host awake.
- Multi-host shared storage for the media mount - single-host bind mount now.
- `/trending`, `/similar` gateway endpoints - wait on torrent-downloader v1.2
  TMDB roadmap; add as passthroughs when they ship.

## Open questions for implementation phase (not blocking spec approval)

- Webhook auth: localhost-only caller - require `X-API-Key` anyway, or key
  only the `/api/v1` surface? Document the choice.
- DOWNLOADING progress: does the gateway actively poll torrent-downloader
  `/transfers` to advance DOWNLOAD_SUBMITTED -> DOWNLOADING, or rely solely on
  the completion webhook and treat `/transfers` as a live read-through? Lean
  read-through (less polling), confirm in implementation.
- PTN season edge cases (multi-season packs, specials) - verify against real
  release-name samples before writing the parser.
