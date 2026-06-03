# CLAUDE.md - medialab workspace root

This file provides context for Claude Code when opened at the `medialab/` workspace root.

Each subdirectory is an independent git repo. This root repo tracks only workspace-level docs.

---

## Architecture

```
medialab/
├── CLAUDE.md                     (this file - workspace context)
├── .gitignore                    (blocks service subdirs from root repo)
├── torrent_downloader/           (independent git repo)
├── medialab-bot/                 (independent git repo - next)
└── medialab-orchestrator/        (independent git repo - future)
```

```
Discord user
    | slash command
medialab-bot (discord.py)
    | HTTP + X-API-Key
torrent-downloader (FastAPI)
    |
qBittorrent + TMDB

Future (when Jellyfin wired up):
medialab-bot → medialab-orchestrator → torrent-downloader
                                     → Jellyfin API
```

## Services

### torrent-downloader (v1.0.0 - complete)

FastAPI REST API. GitHub: https://github.com/MickMarch/torrent_downloader

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

### medialab-orchestrator (future)

Add when Jellyfin integration starts. Owns cross-service workflows (download complete
polling, Jellyfin library scan trigger). Not needed until then.

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

## Environment

Host: Windows 10, main PC (also gaming machine - avoid CPU/GPU-heavy local services).
Media server: Jellyfin (REST API available for future integration).
VPN: active VPN required (torrent-downloader enforces VPN binding).
