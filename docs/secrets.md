# Secrets map

Where every credential in the stack comes from and which `.env` it goes in.
No values live here. Each service's `.env.example` is the authoritative list of
its variables; this page explains the ones that are easy to confuse and how to
obtain them.

## Third-party credentials

| Credential | Obtain | Goes in |
|---|---|---|
| TMDB API key (v3) | themoviedb.org account -> Settings -> API -> request a v3 key | `torrent-downloader/.env` (sole TMDB-key holder; the orchestrator and bot resolve metadata through it) |
| qBittorrent Web UI credential | qBittorrent -> Tools -> Options -> Web UI; enable and set the credential | `torrent-downloader/.env`, with `QB_HOST` pointing at the host from inside the container |
| Jellyfin API key | Jellyfin dashboard -> Administration -> API Keys | `medialab-jellyfin/.env`, with `JELLYFIN_HOST` pointing at the host from inside the container |
| Discord bot token + guild id | Discord developer portal -> your application -> Bot | `medialab-bot/.env` |
| Web UI password + cookie secret | Choose any strong password; generate the secret (`python -c "import secrets; print(secrets.token_urlsafe(48))"`). Rotating the secret signs everyone out. | `medialab-web/.env` as `WEB_PASSWORD`, `WEB_SECRET_KEY` |
| Jackett API key (optional) | Only if Jackett is installed; shown top-right of its web UI | `jackett.json` in qBittorrent's `nova3/engines` directory, not in any service `.env`. Not in use on this host. |

## Inter-service keys

Each service protects its API with a static `X-API-Key` you generate (any
strong random string). The caller and callee must hold the same value:

| Caller variable | must equal | Callee variable |
|---|---|---|
| bot `ORCHESTRATOR_API_KEY` | = | orchestrator `API_KEY` |
| web `ORCHESTRATOR_API_KEY` | = | orchestrator `API_KEY` |
| completion relay `ORCHESTRATOR_API_KEY` (qBittorrent process env) | = | orchestrator `API_KEY` |
| orchestrator `TORRENT_DOWNLOADER_API_KEY` | = | torrent-downloader `API_KEY` |
| orchestrator `MEDIALAB_JELLYFIN_API_KEY` | = | medialab-jellyfin `API_KEY` |

These pairs are hand-synced today. The setup wizard
(MickMarch/medialab#23) will generate them from one input.

## VPN

Torrent traffic requires a bound VPN interface; torrent-downloader checks
qBittorrent's binding against its `VPN_INTERFACES` allowlist and fails closed.
No VPN password is ever collected. When the stack is containerized
(`docs/specs/containerized-stack-vpn.md`), the user supplies a WireGuard
config file to the VPN container instead.

## Rules

- Every `.env` is gitignored. Never commit a real value.
- Never print a `.env` or `docker compose config` output to a shared terminal;
  it renders secrets in the clear.
- Rotate any key that has been displayed before sharing the project.
