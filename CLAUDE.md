# CLAUDE.md - medialab workspace root

This file provides context for Claude Code when opened at the `medialab/` workspace root.

Each subdirectory is an independent git repo. This root repo tracks only workspace-level docs.

---

## Architecture

```
medialab/
├── CLAUDE.md                     (this file - workspace context)
├── .gitmodules                   (submodule registry - source of truth for service versions)
├── .gitignore                    (blocks unregistered future service dirs)
├── torrent-downloader/           (submodule - independent git repo)
├── medialab-bot/                 (submodule - independent git repo)
├── medialab-jellyfin/            (submodule - independent git repo)
├── medialab-contracts/           (future submodule - shared Pydantic models)
└── medialab-orchestrator/        (future submodule - not yet created)
```

```
Discord user
    | slash command
medialab-bot (discord.py)
    | HTTP + X-API-Key
torrent-downloader (FastAPI) ---- qBittorrent + TMDB (host)

Future (front-door gateway - orchestrator owns the whole lifecycle):
Discord user
    | slash command
medialab-bot ----------------> medialab-orchestrator --+--> torrent-downloader -> qBittorrent + TMDB (host)
   (one dependency)                    | (gateway)      |
                                       |                +--> medialab-jellyfin   -> Jellyfin (host)
                                       |
qBittorrent (host, run-on-completion script)
    | webhook (torrent finished)      |
    v                                 v
scripts/notify_complete.py --> medialab-orchestrator (advances job: stop-seed, resolve TMDB,
                                rename TV folder, register path, trigger scan)

Bot talks ONLY to orchestrator. torrent-downloader + medialab-jellyfin become
downstream workers, never client-facing. Orchestrator owns a SQLite job table
spanning search -> download -> seed-stop -> rename -> register -> scan.
```

## Architecture style

Named honestly (portfolio vocabulary): **orchestrated microservices behind an
API gateway, with a persisted job state machine.** Concretely:

- **Service-per-capability** - each service wraps one external system
  (qBittorrent+TMDB, Jellyfin) or one client surface (Discord). Small-N (3-4),
  service-oriented rather than fine-grained micro.
- **API Gateway** - the orchestrator front-doors all bot traffic; downstream
  services are never client-facing.
- **Orchestration, not choreography** - a central coordinator drives the
  workflow through an explicit job state machine (SQLite). No event bus.
- **Event-triggered ingress at the tail** - the qBittorrent completion webhook
  is the one event edge; everything else is request/response.
- **Forward-retry saga** - the job table advances through idempotent steps and
  retries forward on failure (no compensation/rollback).

Deliberate restraint (the senior signal, stated so reviewers see intent):
SQLite over Postgres, in-process asyncio worker over Celery/Redis, no message
broker - each chosen as the lightest thing that fits single-host, low-volume
scale. The scale-up path (broker-backed choreography, Postgres, external
workers) is the documented "at 100x load" answer, not the MVP.

## Roadmap order

1. **medialab-jellyfin library endpoints** - scan trigger, add path, item search.
   COMPLETE. PR merged, library router live on main.
2. **torrent-downloader v1.1** - `media_type`-based save path resolution.
   COMPLETE. PR merged, `media_type` on `POST /download` plus
   `GET /transfers/{torrent_hash}/info` live on main.
3. **engineering-standards backfill** - bring existing services up to the
   "Engineering standards" section below: add ruff config + lint/format CI
   step to all three, add the missing **medialab-bot CI workflow** entirely,
   add mypy/pyright gate, pre-commit configs, dependabot + pip-audit, enforce
   Keep-a-Changelog format. Low-risk, parallelizable, strengthens every later
   item. Can run alongside item 4.
4. **medialab-contracts package** - shared Pydantic models (`MediaType`, error
   shape, job/transfer DTOs). Stand it up before v1.2 touches schemas, so v1.2
   consumes the shared `MediaType`/transfer-info model rather than re-defining
   them. Own repo/submodule, pinned per consumer.
5. **torrent-downloader v1.2** - thread `tmdb_id` through `POST /download`,
   cache `{media_type, host_path, tmdb_id}` vs hash, return `tmdb_id` from
   `GET /transfers/{hash}/info`. Additive, backward-compatible. Consumes
   `medialab-contracts` (item 4). Hard prerequisite for the orchestrator (it
   resolves canonical Title (Year) from the cached tmdb_id, not by guessing the
   release name).
6. **medialab-orchestrator MVP** - front-door orchestrating gateway, NOT a
   post-download relay. Bot talks only to the orchestrator; it brokers
   search/download/status and the post-download pipeline, fanning out to
   torrent-downloader + medialab-jellyfin (both become downstream workers).
   SQLite job table spanning the full lifecycle, in-process asyncio worker,
   qBittorrent completion webhook via a relay script, shared media-dir volume
   for TV folder renames, `GET /jobs` observability. Core value prop.
   Full design: `medialab-orchestrator-spec.md` (frozen draft). Depends on
   item 5 (v1.2). This MVP also absorbs the medialab-bot tech-debt cleanup
   below (bot rewritten onto the single gateway dependency) and forces the root
   `docker-compose.yml` (shared network + media mount) to land now.
7. **medialab-bot Dockerfile** - so all services are containerized per Deployment.
8. **medialab-setup CLI wizard** (new tool, not a microservice) - one-time
   pre-deployment setup: collects TMDB/Jellyfin/qBittorrent API keys with
   guided instructions for obtaining each, creates/selects movie+TV
   directories, registers them as Jellyfin libraries, writes per-service
   `.env` files (each service keeps its own `.env`/`.env.example`, not a
   shared root `.env` - root compose references them via per-service
   `env_file:` paths), optionally runs `docker compose up`. Express mode
   (defaults) and custom mode (every config value editable). Lives in its
   own directory/repo, run locally before containers exist - not a
   long-running service.
9. **medialab-bot `/settings` cog** - runtime config viewing/editing via Discord
   slash commands (`/settings get`, `/settings set key value`), calling each
   service's settings endpoint (torrent-downloader already has
   `core/settings_manager.py` - check its current surface before designing this).
   Bot reports whether a changed setting hot-reloads or requires a container
   restart. No separate GUI - Discord is the existing user-facing surface.

Items 8-9 are fast-follows after the MVP (1-7); do not block the MVP on them.

## Session start - check submodule state

Run this at the start of every session to see which services have changed since last pinned:

```bash
git submodule status
```

Output format: `[+]<sha> <path> (<tag or branch>)`

- No prefix - submodule matches pinned SHA, no changes since last session
- `+` prefix - service has new commits, context in that service's CLAUDE.md may be stale; read it before working on that service
- `-` prefix - submodule not initialized, run `git submodule update --init`

To update the root repo's pin to a service's latest commit:

```bash
git submodule update --remote torrent-downloader
git add torrent-downloader
git commit -m "chore: update torrent-downloader submodule pin"
```

## Services

### torrent-downloader (v1.1 - complete)

FastAPI REST API. GitHub: https://github.com/MickMarch/torrent-downloader

Endpoints:
- `GET /api/v1/health` - public, no auth
- `GET /api/v1/search/tmdb` - TMDB multi-search
- `GET /api/v1/search/tmdb/movie/{tmdb_id}` - movie detail
- `GET /api/v1/search/tmdb/show/{tmdb_id}` - show detail
- `GET /api/v1/search/torrents` - qBittorrent plugin search, grouped by resolution
- `POST /api/v1/download` - submit magnet URI (VPN enforced); accepts `media_type`
  (movie|show) and resolves the save path itself under `MEDIA_HOST_PATH`, no
  genre subfolders, caches `media_type`/`host_path` against the torrent hash
- `GET /api/v1/transfers` - active transfers
- `GET /api/v1/transfers/{torrent_hash}/info` - cached `media_type` and
  `host_path` for a hash, looked up by the orchestrator at completion time
- `POST /api/v1/transfers/stop-seeding` - stop seeding completed transfers
- `GET /api/v1/storage` - disk usage
- `DELETE /api/v1/cache` - evict cache

Auth: `X-API-Key` header on all endpoints except `/health`.
Error shape: `{"status": "error", "code": "<ErrorCode>", "detail": "..."}`.
Rate limits: 60 req/min general, 20 req/min search. 429 includes `Retry-After` header.
Request tracing: every response includes `X-Request-ID` UUID header.

v1.2 roadmap (not yet built):
- `GET /api/v1/search/trending?type=movie|show&window=day|week`
- `GET /api/v1/search/similar?tmdb_id=123&type=movie|show`

### medialab-bot (not yet started)

Discord bot. Tech stack: `discord.py`, `uv`, `hatchling + hatch-vcs`, `pydantic-settings`.

Slash commands planned:
- `/search query type` - TMDB search, present results as Discord embed + select menu
- `/torrent query` - skip TMDB, go straight to torrent search
- `/download` - confirm and submit selected magnet
- `/transfers` - list active downloads
- `/storage` - disk usage
- `/trending type` - trending movies or shows (requires torrent-downloader v1.2)
- `/similar title type` - similar titles (requires torrent-downloader v1.2)

Multi-step flow: user picks TMDB result via Discord Select component, then picks torrent
resolution, then confirms download. State lives in Discord message components - no
server-side session needed.

Roadmap: needs a Dockerfile (none yet) per the Deployment section below - mirror
torrent-downloader's two-stage uv install pattern, non-root user, hatch-vcs
APP_VERSION build arg.

Tech debt in this service to resolve when orchestrator is built - see
"medialab-bot tech debt" under medialab-orchestrator below.

### medialab-jellyfin (v1 - complete)

FastAPI REST API wrapping the Jellyfin media server API. GitHub:
https://github.com/MickMarch/medialab-jellyfin (private)

Endpoints:
- `GET /api/v1/health` - public, no auth, reports Jellyfin reachability
- `POST /api/v1/library/scan` - trigger Jellyfin library scan (`POST /Library/Media/Updated`)
- `POST /api/v1/library/paths` - add local directory to a Jellyfin library; resolves
  target library dynamically via `GET /Library/VirtualFolders` filtered by CollectionType
  (no env-var config); optional `library_name` override for ambiguous multi-library setups
- `GET /api/v1/library/items` - search library contents (`GET /Items`)

Same conventions as torrent-downloader: `X-API-Key` auth, structured error
shape, rate limiting, `X-Request-ID` tracing, `hatch-vcs` versioning.

Stays a thin proxy - assumes Jellyfin already reachable. No power-management
or workflow logic here; that belongs to the orchestrator.

### medialab-orchestrator (future)

> **Design superseded - see `medialab-orchestrator-spec.md` (frozen draft,
> 2026-06-26) for the current design.** The orchestrator is now a **front-door
> orchestrating gateway** (bot talks only to it; it fronts the whole lifecycle
> and owns a SQLite job table), not the post-download-only relay the notes
> below describe. The notes below are retained for the TV-folder-naming and
> Jellyfin-availability detail still referenced by the spec; treat the spec as
> the source of truth where they conflict.

Add when event-driven cross-service workflows are needed. Owns:

1. **Download-complete handling.** qBittorrent supports "Run external program
   on torrent completion" (a script invoked once per finished torrent, no
   polling). That script calls a webhook on the orchestrator
   (e.g. `POST /webhooks/torrent-complete` with hash/name from `%I`/`%N`).
   On receipt, orchestrator:
   - calls torrent-downloader `POST /api/v1/transfers/stop-seeding`
   - calls torrent-downloader `GET /api/v1/transfers/{hash}/info` to
     get `media_type` and `host_path`
   - for TV: renames/restructures the downloaded folder into Jellyfin's
     required convention (`Series Name (Year)/Season NN/`) before any
     Jellyfin call - see "TV folder naming" below. Movies need no rename
     (Jellyfin matches movie folders more loosely).
   - calls medialab-jellyfin `POST /library/paths` (movies/TV root only
     needs registering once at setup time, not per-download, since Jellyfin
     recursively scans an already-registered root) and `POST /library/scan`
     with the renamed path
2. **TV folder naming.** Jellyfin's TV library requires exact convention:
   `Series Name (Year)/Season NN/` (season zero-padded, never abbreviated
   to `S01`). Torrent release names almost never match this
   (`Show.Name.S01.1080p.GROUP/...`). Orchestrator must parse the release
   name (PTN, already a torrent-downloader dependency) and move/rename
   files into the correct structure before triggering a Jellyfin scan.
   Movies are more forgiving of folder naming and likely need no rename step.
3. **Jellyfin host availability.** Power-on Jellyfin host when down
   (mechanism TBD - WoL / smart plug / SSH, depends on host setup). Runs
   before any medialab-jellyfin call if the host might be asleep.

Orchestrator owns preconditions (is the dependency reachable/awake) and
multi-service state; the wrapper services (torrent-downloader,
medialab-jellyfin) stay stateless proxies assuming their dependency is up.

**medialab-bot tech debt to fold into this work:**

- `AppConfig.torrent_save_path` and `AppConfig.tmp_docker_save_path`
  (`medialab-bot/src/medialab_bot/config.py`) are passed by the bot into
  `download()` and `get_storage()`
  (`client/_torrents.py`, `client/_status.py`). Save-path policy is a
  workflow/placement concern, not something the Discord UI layer should own.
  Resolved by torrent-downloader's v1.1 `media_type`-based path resolution
  (see torrent-downloader roadmap above) - bot passes `media_type` instead of
  a path, and these config fields are removed from medialab-bot.
- `medialab-bot/src/medialab_bot/main.py` checks torrent-downloader's
  `/health` (incl. VPN binding) at startup and logs warnings. Once orchestrator
  exists, consider whether cross-service health aggregation (torrent-downloader
  + medialab-jellyfin + Jellyfin/qBittorrent reachability) belongs there
  instead, surfaced to the bot via a single orchestrator health check.

## Shared conventions

- Language: Python 3.12+
- Package manager: `uv` (not pip, not poetry)
- Build backend: `hatchling` + `hatch-vcs` (version from git tags, never hardcoded)
- Settings: `pydantic-settings` loading from `.env`
- Tests: `pytest` style only, run via `uv run pytest`
- Commits: Conventional Commits (`feat`, `fix`, `chore`, etc.)
- Workflow: spec approval → failing tests → implementation (never skip to code)
- No hardcoded secrets - `.env` for local dev, gitignored always
- No em dash character anywhere
- No "Claude Code" or AI attribution in commit messages or code comments
  (exception: CLAUDE.md files and .claude/ directories)

## Engineering standards

Workspace-wide standards every service inherits. New services adopt all of
these from their first commit; existing services backfill (see roadmap item
"engineering-standards backfill").

### Linting & formatting
- **Ruff** is the single linter + formatter (`uv run ruff check`,
  `uv run ruff format`). Config lives in each service's `pyproject.toml` under
  `[tool.ruff]`, kept identical across services. Baseline rule set: `E`, `F`,
  `I` (import sort), `UP` (pyupgrade), `B` (bugbear), `SIM` (simplify),
  `PLR2004` (magic value used in comparison). The magic-number/-string ban is
  enforced as the `PLR2004` lint rule, not left to review judgment - use named
  constants/enums/config instead.
- No separate `black`/`isort`/`flake8` - ruff replaces all three.

### Static typing
- Full type hints required (the code already has them). `mypy` (or `pyright`)
  runs in CI as a gate. Config in `pyproject.toml`.

### Pre-commit
- `.pre-commit-config.yaml` in every service: ruff (check + format),
  trailing-whitespace, end-of-file-fixer, yaml/toml checks. Local gate before
  a commit reaches CI. (The em-dash prohibition is an assistant authoring rule,
  not a pre-commit gate - do not add a hook for it.)

### CI (GitHub Actions)
- Every service has `.github/workflows/ci.yml` running, in order:
  `ruff check` -> `ruff format --check` -> `mypy` -> `uv run pytest`
  (with coverage). Tests-only CI is insufficient - lint + typecheck are gates.
- **medialab-bot currently has no workflow** - add one (backfill).
- Coverage reported; a floor is enforced once each service's suite is mature
  (target documented per service, not a blanket number).
- **Dependabot** (`.github/dependabot.yml`) for `uv`/pip + GitHub Actions
  updates. **`pip-audit`** step in CI for dependency CVEs - audit the resolved
  project deps (`uv export ... | pip-audit -r`), not a bare `uvx pip-audit`
  (which audits only the isolated tool env and finds nothing useful).
  Unfixable CVEs are ignored by explicit ID with a comment, not by dropping the
  gate.

### Changelog
- Keep a Changelog format (https://keepachangelog.com): `Unreleased` section
  at top, grouped `Added`/`Changed`/`Fixed`/`Removed`, moved under a dated
  `vX.Y.Z` heading at release time. All three current services already have a
  `CHANGELOG.md` - enforce the format.

### DRY with judgment
- Extract a shared abstraction on the **third** real repetition, not the
  second, and never abstract across **domain** boundaries purely to dedupe
  (a coincidental code match in two services is not shared logic). Genuinely
  shared cross-service contracts live in `medialab-contracts` (see below), not
  copy-paste and not a forced base class. Prefer a little duplication over the
  wrong abstraction.

### Tests must run without `.env` (CI isolation)

CI runs on GitHub Actions with **no `.env` file and no real secrets**. Tests
that depend on real config or live external services fail there as false
negatives. Mitigation (already the pattern in medialab-jellyfin /
torrent-downloader - keep it uniform):

1. **Config defaults everywhere.** Every `pydantic-settings` field has a
   default (`None` for secrets, sensible literals otherwise) so the app
   imports cleanly with no `.env` present. Fields are "optional at import time,
   required at runtime" - never make a field mandatory at import or CI import
   fails before a test even runs.
2. **Unit tests never read real config.** `conftest.py` uses `autouse=True`
   fixtures to patch the config object (e.g. mock `core.auth.config` with a
   `TEST_API_KEY` constant). Tests assert against the injected test value, not
   a real key.
3. **External dependencies are mocked.** No unit test makes a real network call
   (qBittorrent, TMDB, Jellyfin, Discord, the downstream services). Mock at the
   client-class boundary (see the Discord-mocking convention), not at
   `httpx` internals, except in the dedicated client test module.
4. **Live-credential tests are marked and skipped.** Anything that genuinely
   needs real secrets or a live service is marked
   `@pytest.mark.integration` and skipped in CI (run only locally with a real
   `.env`). CI runs the default (non-integration) suite. Register the
   `integration` marker in `pyproject.toml` so it is not an unknown-marker
   warning.

Net rule: a fresh checkout with zero `.env` and no network must pass
`uv run pytest` green. If a test needs a secret or a live endpoint to pass,
it is either mis-scoped (mock it) or an integration test (mark + skip).

### Shared contracts (`medialab-contracts`)
- A small versioned package of Pydantic models shared across services
  (`MediaType`, the structured error shape, job/transfer DTOs, common enums).
  Single source of truth - editing a shared field happens once, not in three
  schemas. Each service depends on a pinned version; bumping it is a
  deliberate, reviewable step. Prevents schema drift as the surface grows.
  Lives in its own repo/submodule like the services.

## Git workflow

Each service is an independent repo with its own tags and releases.
Version tags: `vX.Y.Z` annotated tags pushed to GitHub, GitHub Release created from tag.
Branch strategy: feature branches off main, PR to merge.

## Deployment

All microservices (torrent-downloader, medialab-bot, medialab-jellyfin,
medialab-orchestrator) are intended to run as Docker containers on the host
PC. They reach host-installed applications - qBittorrent, Jellyfin, and any
future host apps - over the network via `host.docker.internal`, the same
pattern torrent-downloader already uses for qBittorrent (see its
`.env.example` `QB_HOST` notes). Each service's Dockerfile and `.env.example`
already account for this (host vs. container `*_HOST` values).

Containers communicate with each other over HTTP + `X-API-Key`, same as they
would un-containerized - no service-to-service magic beyond normal REST calls
(plus a shared Docker network/compose file once orchestrator exists).

## Environment

Host: Windows 10, main PC (also gaming machine - avoid CPU/GPU-heavy local services).
Media server: Jellyfin (REST API available for future integration).
VPN: active VPN required (torrent-downloader enforces VPN binding).
