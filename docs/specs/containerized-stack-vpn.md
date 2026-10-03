# Spec: containerized qBittorrent behind a VPN kill-switch

Status: Shipped
Issue: MickMarch/medialab#28

Revised after the practice lab in
[docs/lab/containerized-qbittorrent](../lab/containerized-qbittorrent/README.md);
its [FINDINGS.md](../lab/containerized-qbittorrent/FINDINGS.md) is the
evidence behind every "verified" below. Jellyfin stays external; the setup
wizard is MickMarch/medialab#23 and only consumes what this spec defines.

## Hard invariant

No torrent traffic, download or seed, may ever occur unless a VPN tunnel is
up and carrying it. No bypass, no dev exception. Every decision below is
subordinate to this.

## Problem

qBittorrent runs on the Windows host, bound by hand to a VPN adapter named in
the downloader's allowlist. That makes the suite non-portable (the adapter
name is provider-specific, the completion hook is a `.bat` holding the
gateway key, the save path is a Windows path handed across a container
boundary) and the kill-switch is an application assertion, not a property of
the network. It also fails in practice when the host runs two VPNs: a second
tunnel with lower route metrics carries the torrent traffic even though
qBittorrent is "bound" to the first (MickMarch/medialab#30). Self-hosters
without the same provider cannot follow the setup at all.

## Goal and non-goals

**Goal.** qBittorrent and torrent-downloader run as containers whose only
network path is a gluetun WireGuard tunnel, so a dropped tunnel means no
route rather than a refused request, and no torrent-related lookup or fetch
ever leaves from the host's address or through the host's resolver. The VPN is bring-your-own: one provider env file, swappable
without touching anything else. First boot needs no clicking in the
qBittorrent UI. Paths, the completion hook and the VPN check become
provider-agnostic constants.

**Non-goals.** Bundling or recommending a specific VPN subscription. Owning
Jellyfin's lifecycle. Multi-host or multi-user layouts. Per-environment
compose overlays and a dev dry-run default, which move to their own issue.
A delayed stop-seed window, which is a settings knob on the existing
STOP_SEEDING step and not part of this change.

## Design

### Topology

```
                 compose network (internal)
 medialab-bot / medialab-web --> medialab-orchestrator --> torrent-downloader
                                        ^                         |
                                        | completion hook         | qBittorrent API
                                        | (curl from inside       v  http://gluetun:8080
                                        |  the gluetun namespace) +---------------------+
                                        +-------------------------| gluetun             |
                                                                  |  WireGuard tun0     |
                                                                  |  firewall           |
                                                                  |  qbittorrent        |
                                                                  |  (network_mode:     |
                                                                  |   service:gluetun)  |
                                                                  +----------+----------+
                                                                             | tunnel only
                                                                             v
                                                                          internet
 /media bind mount: host MEDIA_HOST_DIR -> /media in qbittorrent AND orchestrator
```

### Compose services added

| Service | Image | Notes |
|---|---|---|
| `gluetun` | `qmcgaw/gluetun` (pinned major) | `cap_add: NET_ADMIN`, `/dev/net/tun`, `env_file: ./gluetun/vpn.env`, `FIREWALL_OUTBOUND_SUBNETS` set to the compose subnet (fixed via `ipam`), control server with API-key auth on loopback only, healthcheck built in. |
| `qbittorrent` | `lscr.io/linuxserver/qbittorrent` (pinned, >= 5.2) | `network_mode: service:gluetun`, `depends_on: gluetun: condition: service_healthy`, volumes `qbittorrent-config:/config` and `${MEDIA_HOST_DIR}:/media`. No ports of its own; the WebUI is published on `gluetun` to `127.0.0.1` for the operator. |
| `torrent-downloader` (moved) | existing image | Also `network_mode: service:gluetun`. Talks to qBittorrent on `127.0.0.1:8080`, listens on `API_PORT=8001` (8000 is gluetun's control server in the shared namespace), and is addressed by the orchestrator as `http://gluetun:8001`. Its DNS is gluetun's DNS-over-TLS forwarder and its egress (TMDB, details-page scraping, plugin fetches) is the tunnel. Verified in the lab's second run. |

gluetun and qBittorrent are third-party images with no `build:` key. `bin/lib.sh` gains a
filter so version and build scripts iterate only built services; a
`medialab_third_party_services` helper lists the rest for `medialab-status`.

### Bring-your-own VPN

One gitignored file, `gluetun/vpn.env`, holding exactly one provider block.
`gluetun/vpn.env.example` ships the NordVPN block (native provider, needs
only `WIREGUARD_PRIVATE_KEY` and a server filter), a `custom` block for
providers that issue a WireGuard `.conf` (mounted at
`/gluetun/wireguard/wg0.conf` through a documented overlay), and a pointer to
gluetun's provider list for everything else. Switching provider is: edit the
file, run `docker compose up -d`. The tunnel interface inside the namespace is
always `tun0`, so nothing downstream changes. Verified: a gluetun-only
recreate orphans qBittorrent; a plain `up -d` recreates both correctly.

### Paths

`/media` is one bind mount seen identically by qBittorrent and the
orchestrator. torrent-downloader's `MEDIA_HOST_PATH` (a Windows path handed
to host qBittorrent) becomes `MEDIA_MOUNT_PATH=/media`, the same name and
meaning as the orchestrator's. Save path per add becomes
`<MEDIA_MOUNT_PATH>/<STAGING_SUBDIR>/<MEDIA_TYPE_SUBDIRS[media_type]>`, built
from `medialab-contracts` constants and joined with `/`. The current builder
joins with backslashes for host qBittorrent on Windows; verified in the lab
that Linux qBittorrent then treats `/media\_incoming\Movies` as one filename
at `/` and the torrent errors. This change is a prerequisite for the move. The hook's `content_path` is already a
container path on the same mount, so no translation remains anywhere.
`docs/decisions/0001` gets a follow-up note.

### VPN check (defense in depth, two layers)

1. **Physical.** gluetun's firewall: with the tunnel down, nothing in the
   namespace has a route. Verified with the control server stopping the
   tunnel. gluetun also gates qBittorrent's start through the healthcheck
   and self-heals a dead tunnel (`HEALTH_RESTART_VPN`).
2. **Assertion.** torrent-downloader's existing `is_vpn_bound()` stays and
   keeps refusing `POST /download` unless `current_interface_name` is in
   `VPN_INTERFACES`. The shipped default becomes `tun0` instead of
   `NordLynx`. Empty still means deny all.

The orchestrator's aggregated `/health` exposes the downloader's
`vpn_interface_bound` flag so the web UI and the bot can show it; enforcement
stays in one place.

### Completion hook

qBittorrent's autorun command becomes a `curl` POST from inside the
namespace to
`http://medialab-orchestrator:8000/api/v1/webhooks/torrent-complete` with the
gateway `X-API-Key` header and the `{hash, name, content_path}` body.
Verified: reaches the orchestrator by service name through gluetun's firewall
and DNS, and the image ships `curl`. `scripts/notify_complete.py` and
`bin/notify-complete.bat` are retired from the compose path (kept one release
for host installs, then removed).

### Zero-click provisioning

A new idempotent script, `bin/medialab-qbt-provision.sh`, run by the operator
once (and by the setup wizard later):

1. If `qBittorrent.conf` has no `WebUI\APIKey`, generate a `qbt_`-prefixed
   32-character key and write it into the conf before the container's first
   start. Verified: the key is stored in plain text and honoured on boot.
   The same value goes into torrent-downloader's `QB_API_KEY`.
2. Start the stack, wait for gluetun health, then over the API with the
   Bearer key: `setPreferences` for `current_network_interface=tun0`,
   `upnp=false`, `lsd=false`, `queueing_enabled=false`, `save_path`,
   `autorun_enabled` plus `autorun_program`, `web_ui_password` (random,
   written to a gitignored file for the operator), and
   `search/installPlugin` for the configured plugin list.

Verified: every one of those preference writes took effect and survived a
restart; plugin install lands in `/config/qBittorrent/nova3/engines`.

### Per-repo changes

| Repo | Change |
|---|---|
| torrent-downloader | `MEDIA_HOST_PATH` becomes `MEDIA_MOUNT_PATH` (container path, `/` join); `QB_HOST` example `127.0.0.1`; `API_PORT` example `8001`; `VPN_INTERFACES` default `tun0`; `.env.example` and README rewritten for the shared-namespace layout. |
| medialab-orchestrator | `TORRENT_DOWNLOADER_URL` example becomes `http://gluetun:8001`; aggregated `/health` carries `vpn_interface_bound`; webhook README documents the curl autorun; `notify_complete.py` marked deprecated. |
| medialab-web, medialab-bot | Show VPN status from aggregated health (web: status card; bot: startup health line). |
| workspace | compose: `gluetun` and `qbittorrent` services, fixed subnet, `gluetun/vpn.env.example`, `compose.wgfile.yml` overlay; `bin/lib.sh` built-vs-third-party split; `bin/medialab-qbt-provision.sh`; README and `docs/host-setup.md` updated; `docs/secrets.md` gains the VPN key, qBittorrent API key and gluetun control key rows. |
| medialab-contracts | None. |

## Decisions

1. **Containerize qBittorrent; Jellyfin stays external.** Rejected: leaving
   qBittorrent on the host. Only a container can be given gluetun's namespace,
   and the host layout is what fails under two VPNs.
2. **Bring-your-own VPN via one gluetun env file; no bundled provider.**
   Rejected: a free provider. Free tiers either block P2P or monetise
   traffic, the opposite of the goal. Rejected: a `.conf`-only contract.
   NordVPN, the maintainer's provider, does not issue files; gluetun's native
   provider needs only a private key. Both paths are supported; the env file
   is the contract.
3. **gluetun is the kill-switch; `is_vpn_bound()` stays as the assertion
   layer.** Rejected: dropping the app check as redundant. It costs one API
   call and turns a silent stall into a clear `VPN_NOT_BOUND` error.
4. **Enforcement in torrent-downloader only; the gateway surfaces, does not
   refuse** (resolves former open question 3). Rejected: a second refusal at
   the gateway. With a physical layer underneath, a third check adds
   duplication without safety; status in `/health` gives the clients what
   they need to warn before confirm.
5. **Stop-seeding stays the orchestrator's STOP_SEEDING step** (resolves
   former open question 2). It already removes the torrent once the pipeline
   owns the files (decision 0003). A delay is a future settings knob on that
   step, not a timer in the downloader, which would be lost on restart.
6. **Tunnel verification is interface binding plus gluetun's own health**
   (resolves former open question 5). Rejected: an external IP-leak probe in
   the app. gluetun already dials out through the tunnel every few minutes
   and restarts it on failure; a second probe adds a network dependency and a
   new failure mode to the download path.
7. **Environment overlays and dev dry-run move out** (resolves former open
   question 4 by scoping it out). They are orthogonal to the kill-switch and
   would double the compose surface of this change.
8. **API key is pre-seeded in `qBittorrent.conf`; all other settings go over
   the API.** Rejected: seeding everything in the conf (couples us to an
   undocumented file format for settings the API exposes). Rejected: doing
   everything over the API (needs the first-boot temporary password from the
   log and a second restart so the downloader learns the key).
9. **Completion hook is a script in the mounted config dir, called by
   autorun; the gateway key sits in an env file beside it.** Amended at
   cutover: qBittorrent runs the autorun command without a shell, so an
   inline `curl` with quoted JSON reached the orchestrator with literal
   backslashes and a 422 (the lab's echo server had accepted anything).
   `qbittorrent/config/hooks/notify-complete.sh` builds the body with
   `python3` and reads `notify.env`; autorun is
   `/config/hooks/notify-complete.sh "%I" "%N" "%F"`. Rejected: a dedicated
   hook secret, still; the same gateway key is used, now out of the
   preference string. Verified live: 202 and the job advanced.
10. **Paths unify on `/media` across qBittorrent and the orchestrator.**
    Rejected: keeping a host-path env in the downloader for compatibility.
    It was the source of the three-names-for-one-directory confusion.
11. **torrent-downloader joins gluetun's namespace.** Rejected: leaving it
    on the compose network with host-forwarded DNS. On 2026-10-03 a download
    failed on the stable stack because the container's resolver, which
    follows the host's VPN-driven DNS, could not resolve a details page for
    about four minutes after startup; pinning public resolvers was tried
    earlier and broke under a host VPN that blocks plain UDP/53. Inside the
    namespace the downloader resolves through gluetun's DNS-over-TLS
    forwarder and scrapes torrent-site pages through the tunnel instead of
    from the home IP. Verified: health, TMDB, plugin search and qBittorrent
    on `127.0.0.1` all work there; only the save-path join (decision 10)
    stood in the way. Cost: the downloader's port must avoid gluetun's 8000
    and the orchestrator addresses it through `gluetun`.
12. **Admin password is set once through the API and written to a
    gitignored file for the operator.** Rejected: leaving linuxserver's
    per-boot temporary password. The operator will open the WebUI
    occasionally and should not have to read a container log for it. The
    hash format only matters when seeding the conf, which we do not do for
    the password.
13. **Search plugin list is a workspace setting, `QBT_SEARCH_PLUGINS`, with
    a shipped default.** Rejected: hardcoding the list in the provision
    script. Plugins come and go; a setting keeps the change to `.env`.

## Open questions

None. Former questions 1 and 2 are decisions 12 and 13.

## Shipped notes (2026-10-03)

- Cutover on the host: PRs MickMarch/medialab#109, #116, #117, #118,
  torrent-downloader#46, medialab-orchestrator#54, medialab-web#21,
  medialab-bot#55. Releases: torrent-downloader v1.21.0, orchestrator
  v1.4.0, web v0.19.0, bot v2.15.0.
- Live checks passed: egress through the tunnel, downloader reachable at
  `gluetun:8001` with the VPN flag true, provisioning idempotent, a real
  download placed into the library and deleted again, the completion hook
  answered 202.
- gluetun needed eleven NordVPN server rotations (about seventy seconds)
  before one passed its health check; the provision script waits for health
  itself rather than relying on compose's dependency wait.
- Surfaced, tracked separately: re-downloading a deleted title hits the
  unique `torrent_hash` (MickMarch/medialab#119); unreachable source pages
  return 422 instead of a retryable error (MickMarch/medialab#110).

## Test plan

- **torrent-downloader**: config test that `VPN_INTERFACES` defaults to
  `tun0`; the save-path builder produces `/media/_incoming/Movies` from
  `MEDIA_MOUNT_PATH` and the contracts constants; existing `is_vpn_bound()`
  tests unchanged.
- **medialab-orchestrator**: aggregated `/health` includes
  `vpn_interface_bound`, false when the downloader is unreachable.
- **medialab-web, medialab-bot**: render the flag (unit test on the
  presenter).
- **workspace** (bash tests like `bin/medialab-drift.sh`): `medialab_services`
  excludes services without `build`; provision script is a no-op with exit 0
  on a second run; compose `config` validates with the example env files.
- **Live** (decision 0001): rerun the lab scripts against the real stack
  before release: kill-switch, API from the downloader container, hook
  delivery, one real download reaching DONE.

## Rollout

1. workspace: `bin/lib.sh` split and tests (no behaviour change for the
   current stack).
2. torrent-downloader: `MEDIA_MOUNT_PATH` with `/` join, `tun0` default,
   `API_PORT` and `QB_HOST` examples, docs. Release.
3. medialab-orchestrator: health flag, downloader URL example, deprecation
   note. Release.
4. medialab-web, medialab-bot: show the flag. Release.
5. workspace: compose services, provision script, docs, `docs/secrets.md`.
   Manual host steps: stop host qBittorrent, run the provision script, run
   the live checks, remove the host autorun hook and the `.bat`.
6. Close out: `docs/decisions/0001` follow-up note; a new decision note,
   "the network is the kill-switch, the app check is the message".
