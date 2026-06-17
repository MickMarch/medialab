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
└── medialab-orchestrator/        (future submodule - not yet created)
```

```
Discord user
    | slash command
medialab-bot (discord.py)
    | HTTP + X-API-Key
torrent-downloader (FastAPI) ---- qBittorrent + TMDB (host)

Future (when orchestrator built):
medialab-bot ---------------------------------> torrent-downloader -> qBittorrent (host)
                                                        |
qBittorrent (host, run-on-completion script)           |
    | webhook (torrent finished)                       |
    v                                                   v
medialab-orchestrator ----------------------------> medialab-jellyfin -> Jellyfin (host)
    (stop seeding, add path, trigger scan)
```

## Roadmap order

1. **medialab-jellyfin library endpoints** - scan trigger, add path, item search.
   COMPLETE. PR merged, library router live on main.
2. **torrent-downloader v1.1** - `media_type`-based save path resolution.
   Moved before orchestrator: qBittorrent's completion script provides save
   path (`%F`/`%R`) and torrent hash (`%I`) but not media type. The orchestrator
   needs media_type to call `POST /library/paths` with the right Jellyfin library.
   torrent-downloader must store media_type against the hash at download submission
   so the orchestrator can retrieve it at completion time. Resolves medialab-bot
   save-path tech debt as a side effect.
3. **medialab-orchestrator MVP** - download-complete webhook -> stop-seeding +
   Jellyfin add-path/scan. Blocked on torrent-downloader v1.1 (needs media_type
   lookup by hash). Core value prop.
4. **medialab-bot Dockerfile** - so all services are containerized per Deployment.
5. **medialab-setup CLI wizard** (new tool, not a microservice) - one-time
   pre-deployment setup: collects TMDB/Jellyfin/qBittorrent API keys with
   guided instructions for obtaining each, creates/selects movie+TV
   directories, registers them as Jellyfin libraries, writes per-service
   `.env` files (each service keeps its own `.env`/`.env.example`, not a
   shared root `.env` - root compose references them via per-service
   `env_file:` paths), optionally runs `docker compose up`. Express mode
   (defaults) and custom mode (every config value editable). Lives in its
   own directory/repo, run locally before containers exist - not a
   long-running service.
6. **medialab-bot `/settings` cog** - runtime config viewing/editing via Discord
   slash commands (`/settings get`, `/settings set key value`), calling each
   service's settings endpoint (torrent-downloader already has
   `core/settings_manager.py` - check its current surface before designing this).
   Bot reports whether a changed setting hot-reloads or requires a container
   restart. No separate GUI - Discord is the existing user-facing surface.

Items 5-6 are fast-follows after the MVP (1-4); do not block the MVP on them.

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

### torrent-downloader (v1.0.0 - complete)

FastAPI REST API. GitHub: https://github.com/MickMarch/torrent-downloader

Endpoints:
- `GET /api/v1/health` - public, no auth
- `GET /api/v1/search/tmdb` - TMDB multi-search
- `GET /api/v1/search/tmdb/movie/{tmdb_id}` - movie detail
- `GET /api/v1/search/tmdb/show/{tmdb_id}` - show detail
- `GET /api/v1/search/torrents` - qBittorrent plugin search, grouped by resolution
- `POST /api/v1/download` - submit magnet URI (VPN enforced)
- `GET /api/v1/transfers` - active transfers
- `POST /api/v1/transfers/stop-seeding` - stop seeding completed transfers
- `GET /api/v1/storage` - disk usage
- `DELETE /api/v1/cache` - evict cache

Auth: `X-API-Key` header on all endpoints except `/health`.
Error shape: `{"status": "error", "code": "<ErrorCode>", "detail": "..."}`.
Rate limits: 60 req/min general, 20 req/min search. 429 includes `Retry-After` header.
Request tracing: every response includes `X-Request-ID` UUID header.

v1.1 roadmap (not yet built):
- `GET /api/v1/search/trending?type=movie|show&window=day|week`
- `GET /api/v1/search/similar?tmdb_id=123&type=movie|show`
- `POST /api/v1/download` accepts `media_type` (movie|show) and resolves the
  save path itself: `{MOVIES_PATH}` or `{TV_PATH}` (configured per-container
  via env vars, both volume-mounted to the same host directories medialab-jellyfin
  and Jellyfin use). No genre subfolders - media type is the only split needed,
  since Jellyfin libraries are organized by media type at the top level.
  This removes save-path config from medialab-bot entirely (see medialab-bot
  tech debt below) and means medialab-jellyfin's library-scan trigger needs
  no path info from torrent-downloader - both containers see the same files
  via shared volume mounts.

### medialab-bot (not yet started)

Discord bot. Tech stack: `discord.py`, `uv`, `hatchling + hatch-vcs`, `pydantic-settings`.

Slash commands planned:
- `/search query type` - TMDB search, present results as Discord embed + select menu
- `/torrent query` - skip TMDB, go straight to torrent search
- `/download` - confirm and submit selected magnet
- `/transfers` - list active downloads
- `/storage` - disk usage
- `/trending type` - trending movies or shows (requires torrent-downloader v1.1)
- `/similar title type` - similar titles (requires torrent-downloader v1.1)

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

Add when event-driven cross-service workflows are needed. Owns:

1. **Download-complete handling.** qBittorrent supports "Run external program
   on torrent completion" (a script invoked once per finished torrent, no
   polling). That script calls a webhook on the orchestrator
   (e.g. `POST /webhooks/torrent-complete` with hash/name from `%I`/`%N`).
   On receipt, orchestrator:
   - calls torrent-downloader `POST /api/v1/transfers/stop-seeding`
   - calls torrent-downloader `GET /api/v1/transfers/{hash}/info` (v1.1) to
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
