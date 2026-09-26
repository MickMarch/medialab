# medialab

A self-hosted media automation suite: a Discord bot drives the full lifecycle of
finding, downloading, and publishing media to Jellyfin, fronted by an
orchestrating gateway over a SQLite job state machine.

Work tracking: [Issues](https://github.com/MickMarch/medialab/issues) and the
"medialab" Project board. Designs: [docs/specs](docs/specs). Lessons:
[docs/decisions](docs/decisions). Secrets map: [docs/secrets.md](docs/secrets.md).
Working rules for the assistant: [CLAUDE.md](CLAUDE.md).

## Architecture

**Orchestrated microservices behind an API gateway, with a persisted job state
machine.** The Discord bot talks to exactly one service, the orchestrator,
which fronts every request and fans out to downstream workers.

```
Discord user
    | slash command
medialab-bot ----------------> medialab-orchestrator --+--> torrent-downloader -> qBittorrent + TMDB (host)
   (one dependency)                    | (gateway)      |
                                       |                +--> medialab-jellyfin   -> Jellyfin (host)
                                       |
qBittorrent (host, run-on-completion script)
    | webhook (torrent finished)      v
notify_complete.py --------> medialab-orchestrator (advances the job:
                              stop-seed -> resolve TMDB -> rename -> Jellyfin scan)
```

- **Service per capability.** Each service wraps one external system
  (qBittorrent + TMDB, Jellyfin) or one client surface (Discord).
- **API gateway.** The orchestrator front-doors all bot traffic; downstream
  services are never client-facing.
- **Orchestration, not choreography.** A central coordinator drives an explicit
  job state machine in SQLite. No event bus.
- **One event edge.** The qBittorrent completion webhook is the only
  event-triggered ingress; everything else is request/response.
- **Forward-retry saga.** Idempotent steps, retried forward on failure, no
  compensation.

Deliberate restraint: SQLite over Postgres, an in-process asyncio worker over
Celery/Redis, no broker. Each is the lightest thing that fits single-host,
low-volume scale. The scale-up path (broker-backed choreography, Postgres,
external workers) is the documented answer at 100x load, not the MVP.

| Repo | Role | Client-facing | API |
| --- | --- | --- | --- |
| [medialab-bot](medialab-bot) | Discord slash-command UI | to users | [README](medialab-bot/README.md) |
| [medialab-orchestrator](medialab-orchestrator) | Gateway + job state machine | to the bot | [README](medialab-orchestrator/README.md) |
| [torrent-downloader](torrent-downloader) | qBittorrent + TMDB worker | no | [README](torrent-downloader/README.md) |
| [medialab-jellyfin](medialab-jellyfin) | Jellyfin library worker | no | [README](medialab-jellyfin/README.md) |
| [medialab-contracts](medialab-contracts) | Shared Pydantic models + constants | n/a | [README](medialab-contracts/README.md) |

Each is an independent git repo pinned here as a submodule. The root repo
tracks workspace docs, the compose file, `bin/`, and the shared GitHub
workflows. Each service's README is the source of truth for its endpoints and
config.

## Running with Docker Compose

Services run as containers on one shared network and reach the host-installed
apps (qBittorrent, Jellyfin) over `host.docker.internal`. Only the orchestrator
publishes a port.

`.env` files are a runtime input, not a build input; no secret is baked into an
image.

1. **Build** (no `.env` needed):

   ```bash
   bin/medialab-build.sh
   ```

2. **Configure.** Every service keeps its own `.env`; copy each template and
   fill it in (see [docs/secrets.md](docs/secrets.md) for where each value
   comes from):

   ```bash
   for s in torrent-downloader medialab-jellyfin medialab-orchestrator medialab-bot; do
     cp "$s/.env.example" "$s/.env"
   done
   ```

   Compose itself interpolates one value: the host media root bind-mounted into
   the orchestrator. Put it in a root `.env`:

   ```bash
   echo 'MEDIA_HOST_DIR=F:/Media' > .env
   ```

   Downloads land in `MEDIA_HOST_DIR/_incoming/<Movies|Shows>` and the
   orchestrator moves them into `<Movies|Shows>` once named, so Jellyfin never
   sees a raw release (see [docs/host-setup.md](docs/host-setup.md)).

   The same directory appears under three names because three different
   processes see it: `MEDIA_HOST_DIR` is the host path compose mounts,
   `MEDIA_HOST_PATH` (downloader) is the host path handed to host-installed
   qBittorrent, and `MEDIA_MOUNT_PATH` (orchestrator) is the in-container mount
   point. They are not duplicates of one setting.

3. **Run** (compose fails fast if any service `.env` is missing, by design):

   ```bash
   docker compose --env-file .env --env-file .versions.env up -d
   ```

   Passing any `--env-file` disables compose's automatic `.env` load, so both
   files are named explicitly. A bare `docker compose up -d` still works, with
   `:dev` image tags.

Editing a `.env` after the stack is up takes effect only on recreate:
`docker compose up -d --force-recreate <service>`.

### Completion webhook

qBittorrent's "Run external program on torrent completion" must invoke the
orchestrator's standalone relay, `scripts/notify_complete.py`, so finished
downloads enter the post-download pipeline. Setup is in the
[orchestrator README](medialab-orchestrator/README.md). Making the whole stack
start with the machine: [docs/host-setup.md](docs/host-setup.md).

## Versions and images

The git tag is the single source of truth for a service's version. The compose
file tags each image `medialab/<service>:${<SERVICE>_VERSION}` and passes that
version as the `APP_VERSION` build arg, which each Dockerfile bakes in as the
`hatch-vcs` version and an `org.opencontainers.image.version` label.

| Script | Purpose |
| --- | --- |
| `bin/medialab-versions.sh` | write `.versions.env` (gitignored) from each service's `git describe --tags` |
| `bin/medialab-build.sh [svc...]` | regenerate versions, then `docker compose build` |
| `bin/medialab-status.sh` | skew table: local / pinned / built / running / latest tag |
| `bin/medialab-release.sh <repo> <major\|minor\|patch>` | cut a release: date the changelog, tag, push, bump the root pin |
| `bin/medialab-drift.sh` | fail if shared tooling config differs between repos |
| `bin/medialab-doctor.sh` | is the stack up: engine, containers, host apps, gateway health, bot login |

Service names, image names and `*_VERSION` variables are derived from
`docker-compose.yml` by `bin/lib.sh`. Adding a service means adding it to the
compose file and nothing else.

A version string feeds two grammars, Docker tags (no `+`) and PEP 440 (no raw
`-N-gHASH`), so untagged commits map to `X.Y.Z.postN` and dirty trees to
`.dev0`. Tag before building a deploy so images carry exact versions.

## Development

Each repo is a standalone `uv` project:

```bash
cd <repo>
uv sync --dev
uv run pytest
```

Standards, workflow, and conventions: [CLAUDE.md](CLAUDE.md).

## Environments

A dev/staging model (base compose + overlays, a separate dev bot in a dev
guild) is deferred; a solo user with tagged releases to revert to does not
need it yet. It folds into the full-containerization work
([docs/specs/containerized-stack-vpn.md](docs/specs/containerized-stack-vpn.md)).
