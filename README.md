# medialab

A self-hosted media automation suite: a Discord bot drives the full lifecycle of
finding, downloading, and publishing media to Jellyfin, fronted by an
orchestrating gateway over a SQLite job state machine.

Architecture style: **orchestrated microservices behind an API gateway, with a
persisted job state machine.** The Discord bot talks to exactly one service, the
orchestrator, which fronts every request and fans out to downstream workers.

```
Discord user
    | slash command
medialab-bot ----------------> medialab-orchestrator --+--> torrent-downloader -> qBittorrent + TMDB (host)
   (one dependency)                    | (gateway)      |
                                       |                +--> medialab-jellyfin   -> Jellyfin (host)
                                       |
qBittorrent (host, run-on-completion script)
    | webhook (torrent finished)      v
scripts/notify_complete.py --> medialab-orchestrator (advances job: stop-seed, resolve TMDB,
                                rename TV folder, register path, trigger scan)
```

Each subdirectory is an independent git repo, pinned here as a submodule. This
root repo tracks only workspace-level docs and the compose file. The full design,
roadmap, and engineering standards live in [CLAUDE.md](CLAUDE.md).

## Services

| Service | Role | Client-facing |
| --- | --- | --- |
| `medialab-bot` | Discord UI layer | yes (to users) |
| `medialab-orchestrator` | Front-door gateway + job state machine | yes (to the bot) |
| `torrent-downloader` | qBittorrent + TMDB worker | no |
| `medialab-jellyfin` | Jellyfin library worker | no |
| `medialab-contracts` | Shared Pydantic models (not a service) | n/a |

## Running with Docker Compose

The services run as containers on one shared network and reach host-installed
apps (qBittorrent, Jellyfin) over `host.docker.internal`. The orchestrator is the
only port published to the host.

### Build vs run, and where `.env` fits

`.env` files are a **runtime** input, not a build input - no secret is ever baked
into an image.

1. **Build** the images (no `.env` needed):

   ```bash
   docker compose build
   ```

2. **Configure** each service. Every service keeps its own `.env` (there is no
   shared root `.env` for service config); copy each template and fill it in:

   ```bash
   cp torrent-downloader/.env.example      torrent-downloader/.env
   cp medialab-jellyfin/.env.example       medialab-jellyfin/.env
   cp medialab-orchestrator/.env.example   medialab-orchestrator/.env
   ```

   Compose also interpolates one value of its own, the host media root that is
   bind-mounted into the orchestrator. Set it in a root `.env` or the shell:

   ```bash
   echo 'MEDIA_HOST_DIR=F:/Media' > .env   # the host path qBittorrent saves into
   ```

3. **Run** (each service's `.env` must exist now - compose fails fast if one is
   missing, which is intentional):

   ```bash
   docker compose up -d
   ```

Editing a `.env` after the stack is up has no effect until that container is
recreated: `docker compose up -d --force-recreate <service>` re-reads it
(settings are read once at process start; there is no hot-reload).

> Per-service `.env` files keep each service independently runnable and
> deployable, and stop one service's secrets from bleeding into another. The
> planned `medialab-setup` wizard (roadmap item 8) generates all of these
> interactively.

## Development

Each service is a standalone `uv` project:

```bash
cd <service>
uv sync --dev
uv run pytest
```

Engineering standards (ruff, mypy, pre-commit, CI gate, Keep-a-Changelog,
dependabot) are uniform across services - see [CLAUDE.md](CLAUDE.md).
