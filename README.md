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
    | slash command                                   gluetun VPN namespace (tun0 only)
medialab-bot ----------------> medialab-orchestrator --+--> | torrent-downloader -> qBittorrent | -> TMDB, trackers
medialab-web (browser) ------>         | (gateway)      |    |        (127.0.0.1)   curl hook  |    through the tunnel
                                       |                |    +-------------------------|-------+
                                       |                +--> medialab-jellyfin -> Jellyfin (host)
                                       |                                          |
                                       +<--- webhook (torrent finished) ----------+
                                       (advances the job: stop-seed -> resolve TMDB -> rename -> Jellyfin scan)
```

- **Service per capability.** Each service wraps one external system
  (qBittorrent + TMDB, Jellyfin) or one client surface (Discord).
- **API gateway.** The orchestrator front-doors all bot traffic; downstream
  services are never client-facing.
- **Orchestration, not choreography.** A central coordinator drives an explicit
  job state machine in SQLite. No event bus.
- **One event edge.** The qBittorrent completion webhook is the only
  event-triggered ingress; everything else is request/response.
- **The network is the kill-switch.** qBittorrent and torrent-downloader share
  gluetun's network namespace; with the tunnel down they have no route, not a
  refused request. The downloader's own VPN check stays as the message.
- **Forward-retry saga.** Idempotent steps, retried forward on failure, no
  compensation.

Deliberate restraint: SQLite over Postgres, an in-process asyncio worker over
Celery/Redis, no broker. Each is the lightest thing that fits single-host,
low-volume scale. The scale-up path (broker-backed choreography, Postgres,
external workers) is the documented answer at 100x load, not the MVP.

| Repo | Role | Client-facing | API |
| --- | --- | --- | --- |
| [medialab-bot](medialab-bot) | Discord slash-command UI | to users | [README](medialab-bot/README.md) |
| [medialab-web](medialab-web) | Browser UI (jobs, delete, storage) | to users | [README](medialab-web/README.md) |
| [medialab-orchestrator](medialab-orchestrator) | Gateway + job state machine | to the bot and the web UI | [README](medialab-orchestrator/README.md) |
| [torrent-downloader](torrent-downloader) | qBittorrent + TMDB worker | no | [README](torrent-downloader/README.md) |
| [medialab-jellyfin](medialab-jellyfin) | Jellyfin library worker | no | [README](medialab-jellyfin/README.md) |
| [medialab-contracts](medialab-contracts) | Shared Pydantic models + constants | n/a | [README](medialab-contracts/README.md) |
| [medialab-setup](medialab-setup) | Install and update CLI, run on the host | to the operator | [README](medialab-setup/README.md) |

Each is an independent git repo pinned here as a submodule. The root repo
tracks workspace docs, the compose file, `bin/`, and the shared GitHub
workflows. Each service's README is the source of truth for its endpoints and
config.

## Running with Docker Compose

Everything except Jellyfin runs as a container. gluetun holds the VPN tunnel;
qBittorrent and torrent-downloader live inside its network namespace, so
torrent traffic, tracker lookups and TMDB calls all leave through the tunnel
and none of them can leave without it. Jellyfin stays a host app reached over
`host.docker.internal`. Published ports: the orchestrator and the qBittorrent
WebUI on loopback, the web UI on 8081.

Clone with submodules, then double-click `setup.cmd`. It installs `uv` if
needed and opens the installer in your browser: a prerequisites page that
installs what is missing (Git, Docker Desktop, Jellyfin Server) with your
consent, one page with a field for every credential and a `?` beside each
explaining where to get it, then build, qBittorrent provisioning, start,
Jellyfin library registration and the doctor, streamed to the page.

```bash
git clone --recurse-submodules https://github.com/MickMarch/medialab.git
```

The same install from a terminal:

```bash
cd medialab
bin/medialab-setup.sh setup
```

`bin/medialab-setup.sh plan` shows what `setup` would write without writing
it; `--custom` asks every tunable instead of only the required values. To move
a running stack to the current pins, rebuild, verify, and roll back on
failure:

```bash
bin/medialab-setup.sh update
```

Design: [docs/specs/setup-and-update-cli.md](docs/specs/setup-and-update-cli.md)
and [docs/specs/install-wizard.md](docs/specs/install-wizard.md).
Tool docs: [medialab-setup/README.md](medialab-setup/README.md).

### By hand

The same steps without the tool, so the procedure never lives only in code.

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
   for s in torrent-downloader medialab-jellyfin medialab-orchestrator medialab-bot medialab-web; do
     cp "$s/.env.example" "$s/.env"
   done
   cp .env.example .env
   cp gluetun/vpn.env.example gluetun/vpn.env
   ```

   The root `.env` holds what compose itself interpolates: the host media
   root, the compose subnet, the qBittorrent WebUI port, the search plugin
   list. `gluetun/vpn.env` holds your VPN provider block; the example file
   shows NordVPN and the WireGuard-file path for Mullvad, Proton, AirVPN and
   others. No VPN account password is ever collected.

   Downloads land in `MEDIA_HOST_DIR/_incoming/<Movies|Shows>` and the
   orchestrator moves them into `<Movies|Shows>` once named, so Jellyfin never
   sees a raw release. `MEDIA_HOST_DIR` is the host path compose mounts;
   qBittorrent, torrent-downloader and the orchestrator all see it at `/media`
   (`MEDIA_MOUNT_PATH`), so no path is ever translated between them.

3. **Provision qBittorrent** (once, and any time you want the settings
   re-applied). Starts gluetun and qBittorrent, seeds the WebUI API key into
   both qBittorrent and `torrent-downloader/.env`, binds qBittorrent to the
   tunnel, installs the completion hook and the search plugins, and sets an
   admin password into `qbittorrent/admin-password`:

   ```bash
   bin/medialab-qbt-provision.sh
   ```

4. **Run** (compose fails fast if any service `.env` is missing, by design):

   ```bash
   docker compose --env-file .env --env-file .versions.env up -d
   ```

   Passing any `--env-file` disables compose's automatic `.env` load, so both
   files are named explicitly. A bare `docker compose up -d` still works, with
   `:dev` image tags.

Editing a `.env` after the stack is up takes effect only on recreate. After a
change to `gluetun/vpn.env` run a plain `docker compose up -d`: compose then
recreates gluetun and every container in its namespace together. A
gluetun-only recreate leaves qBittorrent and the downloader on a dead
namespace.

### Completion webhook

qBittorrent's "Run external program on torrent completion" is a `curl` POST to
the orchestrator from inside the namespace, set by the provision script. The
command and the deprecated host-side relay are documented in the
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
| `bin/medialab-doctor.sh` | is the stack up: engine, containers, qBittorrent WebUI, Jellyfin, gateway health with the VPN bound, bot login |
| `bin/medialab-qbt-provision.sh` | seed the qBittorrent API key, bind to the tunnel, install the hook and search plugins; idempotent |
| `bin/medialab-setup.sh` | run the install and update CLI ([spec](docs/specs/setup-and-update-cli.md)); `setup` and `update` land with their issues |

Service names, image names and `*_VERSION` variables are derived from
`docker-compose.yml` by `bin/lib.sh`. Adding a service means adding it to the
compose file and nothing else. A service with a `build:` key is one of ours:
it lives in a submodule and its git tag becomes the image version. A service
with only an `image:` is a pulled third-party image; the version and build
scripts skip it and `medialab-status` lists it separately. `bin/tests/`
exercises the helpers against a fixture compose file.

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
