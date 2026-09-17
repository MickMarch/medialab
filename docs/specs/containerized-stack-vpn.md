# Spec: containerized self-hostable stack + VPN enforcement

Status: DRAFT (awaiting approval)
Date: 2026-07-02
Roadmap: backlog item 20 (fully containerized, self-hostable stack). Absorbs the
VPN-enforcement hardening. Spec-first; no code until approved.

## Hard invariant (non-negotiable)

**No torrent traffic - download OR seed/upload - may ever occur unless a VPN is
active and bound. No bypass. No dev exception.** Every decision below is
subordinate to this. If a design choice weakens it, the choice is wrong.

## Goals

1. Make the suite self-hostable: containerize the services medialab ships +
   qBittorrent, so bring-up is (near) one command, minus unavoidable user
   secrets.
2. Enforce the VPN invariant with a physical kill-switch, not just an app check.
3. Minimize the user's torrent fingerprint (stop seeding shortly after
   completion).
4. Keep it right for a single-user Windows host (not a server/multi-tenant
   design).

## Decisions (locked with the user, 2026-07-02)

1. **Container scope: medialab services + qBittorrent; Jellyfin external.**
   Containerize the four medialab services and qBittorrent (qBittorrent must be
   containerized so its network can be VPN-bound as the kill-switch). Jellyfin
   stays a connect-to dependency reached by URL - the user may run it native
   (easy GPU transcoding on Windows) or in their own container. The app does not
   own Jellyfin's lifecycle. Media directories stay on the host, bind-mounted
   into the containers that touch files (qBittorrent, orchestrator).
2. **VPN: bring-your-own, app-enforced, via a WireGuard config file (no
   password).** No bundled VPN. Free VPNs are unsafe for torrenting (P2P-banned
   on safe free tiers; the P2P-allowing free ones log / sell / exit-node traffic
   - the opposite of a minimal fingerprint), so bundling one is a liability. The
   *enforcement* is the product; the VPN subscription is the user's. Setup docs
   recommend reputable privacy-first paid providers (Mullvad / ProtonVPN paid /
   IVPN). **The user never types a VPN password into the app.** They generate a
   WireGuard config on their provider's own website (a throwaway, revocable,
   single-purpose key - NOT their account password; it cannot access their
   account or billing) and drop the file in. This is both the safest mechanism
   and the most comfortable UX: no account credential ever touches medialab, the
   file comes from a source the user already trusts, and the key is revocable
   from the provider's dashboard at any time. Solves the "why does a media app
   want my VPN login" trust problem by never asking for the login.
3. **Kill-switch = gluetun VPN-client container; qBittorrent routes through it.**
   qBittorrent joins gluetun's network (`network_mode: service:gluetun`) and has
   no independent internet route. gluetun holds the WireGuard tunnel and has a
   built-in firewall kill-switch: if the tunnel drops, all non-tunnel egress is
   blocked - qBittorrent physically *cannot* leak a packet (not "refuses to" -
   cannot). This is a stronger guarantee than the current host `NordLynx`
   interface binding, and it is automatic rather than a hand-configured setting.
   gluetun is independently-audited open-source, so the trust surface is a
   well-known VPN client, not medialab itself.
4. **App-layer check stays as defense-in-depth.** torrent-downloader's
   `is_vpn_bound()` pre-flight refusal on `POST /download` stays - it refuses to
   *start* a download when the VPN is not confirmed, giving a clear error
   instead of a silent stall. The check verifies gluetun's tunnel is up (see
   open Q5 for depth: interface-present vs. IP-leak-test). The hardcoded
   `NordLynx` literal becomes configurable so the check is provider/mechanism
   agnostic. Two layers: physical (gluetun kill-switch) + assertion (app check).
   Never bypassable, including in dev.
5. **Seeding: stop N minutes after 100%, N configurable.** Default `N = 0` (stop
   immediately at completion) to match the minimal-fingerprint goal, but
   configurable up so a ratio-required tracker is not a dead end. A brief
   non-zero window is the etiquette-friendly middle (some upload avoids peer
   deprioritization). Ties into the settings store (item 9).
6. **Environments: prod + staging full-function; dev dry-run by default.** Dev
   defaults every download to `dry_run` but can be flipped to live for a real
   test run. Dev with no VPN bound stays search-only (downloads refused by the
   invariant - the correct behavior, not a limitation).
7. **Painless-for-average-user is the setup wizard's job (item 8), not
   containers.** Containers do not remove the unavoidable secrets (TMDB key,
   Jellyfin key, VPN interface). The wizard hand-holds them. qBittorrent WebUI
   credentials CAN be pre-provisioned in compose/setup so the user never
   hand-copies that one.

## Architecture (target)

```
                    +-- VPN interface (host or container tunnel) --+
                    |   qBittorrent BINDS to it (kill-switch)      |
                    v                                              |
[qBittorrent container] --(bound egress only)------------------> internet
        ^  no route if VPN down = traffic halts (invariant held)
        |
[torrent-downloader] --pre-flight is_vpn_bound() before POST /download
        ^
[orchestrator] --gateway; refuses/annotates VPN-down (see open Q)
        ^
[medialab-bot] --surfaces VPN status to the user
        |
[medialab-jellyfin] --> Jellyfin (EXTERNAL: native or user container) by URL

Media dir: host, bind-mounted into qBittorrent + orchestrator.
```

## Per-repo impact (sketch - versions decided at release, not predicted)

- **torrent-downloader:** make the VPN interface name configurable
  (`VPN_INTERFACE`, no default that assumes a provider - required at runtime for
  downloads). `is_vpn_bound()` reads config, not the `NordLynx` literal. Add the
  post-completion stop-seed delay (`SEED_MINUTES_AFTER_COMPLETE`, default 0).
  `/health` reports VPN interface + bound status.
- **orchestrator:** decide whether the gateway refuses downloads when VPN is
  down (open Q) and surfaces VPN status in aggregated `/health`. The STOP_SEEDING
  pipeline step already exists; align it with the delayed-stop setting or keep
  the delay entirely inside torrent-downloader (open Q).
- **medialab-bot:** surface VPN-down to the user (startup health + at download
  confirm). Best-practice: refuse/​warn at the confirm step, not a silent stall.
- **compose:** qBittorrent service added, VPN-bound; base + dev/staging/prod
  overlays; qBittorrent WebUI creds pre-provisioned; Jellyfin stays external
  (URL only).
- **medialab-setup (item 8):** wizard collects VPN interface, TMDB key, Jellyfin
  URL+key; verifies the VPN binding before first run.

## Open questions

**RESOLVED - 1. VPN mechanism.** gluetun VPN-client container holding a
WireGuard tunnel; qBittorrent routes through it (`network_mode:
service:gluetun`). The user supplies a WireGuard config file (no password). The
earlier apparent rejection of gluetun was a miscommunication (a garbled word in
the assistant's message, not a real objection). Decided 2026-07-02.

Remaining (resolve before writing tests):
2. **Where the stop-seed delay lives.** Inside torrent-downloader (a timer after
   completion) or driven by the orchestrator's STOP_SEEDING pipeline step (which
   already exists but currently fires on the webhook)? The webhook path is
   event-driven and restart-safe; an in-process timer is simpler but lost on
   restart.
3. **Gateway-level VPN refusal.** Does the orchestrator refuse a download at the
   gateway when VPN is down (fail fast, clearest UX), or only torrent-downloader
   refuse (single enforcement point, less duplication)? Defense-in-depth argues
   for both; DRY argues for one.
4. **Dry-run default in dev.** Is `dry_run` forced by a dev config flag the
   gateway/bot honor, or a compose env default the services read? Where does the
   "this environment is dev" signal live?
5. **VPN provider verification depth.** Is checking the interface is *bound*
   enough, or should the app also verify the tunnel is *up* (e.g. an external IP
   check confirming it differs from the ISP IP)? IP-leak-test-on-startup is the
   strongest but adds an external call and a failure mode.

## Sequencing (once open Qs resolved)

Likely: torrent-downloader (configurable VPN interface + stop-seed delay +
health) first, since it owns enforcement; then compose (qBittorrent + VPN
binding + overlays); then orchestrator + bot surfacing; the setup wizard (item
8) folds the VPN/keys collection in. Each its own repo PR + release.

## Explicitly out of scope

- Bundling or reselling a VPN. BYO only.
- Owning Jellyfin's lifecycle / GPU transcoding config. External dependency.
- Multi-host / multi-user. Single-user Windows host.
