# STATE

Session-resume snapshot. Read this first at the start of a session, before
`CLAUDE.md` and before running git commands.

This file is **rewritten, never appended**. It describes only the present. History
lives in git log and in `ROADMAP-DONE.md`.

**Last updated: 2026-08-26**

---

## Now

**One PR open and ready to merge:** torrent-downloader
[#21 - configurable VPN interface allowlist](https://github.com/MickMarch/torrent-downloader/pull/21).
CI `quality` check is SUCCESS. Branch `feat/configurable-vpn-interfaces`, commit
`b17e4ca`, pushed.

Nothing else in flight. Root repo clean and in sync with origin, apart from the
expected `M torrent-downloader` (the submodule sits on the unmerged feature
branch, so the root pin still points at main).

**On merge:** bump the root submodule pin, and pick the release version from the
actual last tag (`v1.5.0`) plus the change kind. The CHANGELOG has `Added` +
`Changed` entries under `Unreleased`, so a minor bump - but choose it at release
time from the real tag, never predicted ahead.

## Last done

- **Configurable VPN interface allowlist** (torrent-downloader PR #21). Replaced
  the hardcoded `expected_interface: str = "NordLynx"` default arg with a
  `VPN_INTERFACES` comma-separated allowlist, so any VPN provider works. Stays
  fail-closed: empty or unset rejects every download, never "allow any". Logs
  the bound interface on every check. Verified live - the running stack parses
  `NordLynx,NordLayer-NordLynx` from `.env` and logs
  `VPN check passed. qBittorrent is bound to 'NordLynx' (accepted: ...)`.
  Added the first direct unit tests for `is_vpn_bound`, which had none.
- **medialab-bot DNS fix** (`cbf7216`). ~1000 gateway reconnects over two days
  were 987 `gaierror` DNS failures, not connection failures. Docker's embedded
  resolver forwards public lookups to the host, and the host's VPN tunnels
  cycling took that path down. The bot is the only service resolving a public
  name, so only it was affected. Pinned it to `1.1.1.1` / `8.8.8.8`.
- **Compose network rename** (`5319d2f`). The network was named `medialab`, the
  same identifier as the compose project name, so it materialized as
  `medialab_medialab` and linters flagged the collision. Renamed to `internal`
  (now `medialab_internal`).
- **STATE.md / ROADMAP-DONE.md split** (`cb74db0`). CLAUDE.md mixed durable
  context with volatile session state; completed items 1-7, 16, 19, 23 moved to
  `ROADMAP-DONE.md`. A Stop hook (`bin/state-reminder.sh`) nudges for a refresh
  only when tracked files are newer than this file.

## Next (agreed order)

1. **Merge PR #21**, bump the root pin, tag a release.
2. **Item 18 - uptime / autostart.** Pairs with 16: an always-on pipeline needs
   an always-on stack. Docker runtime on host boot, plus host-app autostart for
   qBittorrent and Jellyfin.
3. **Item 17 - torrent size in the picker**, then **item 13 - `/stop-seeding`
   command.** Two small isolated quick wins.
4. **Item 11 - full Jellyfin naming**, then **item 10 - stuck/failed
   remediation.** Item 10's spec design is locked in `CLAUDE.md` but has no spec
   file and no code yet.

Full ordering rationale and the rest of the queue: `CLAUDE.md` -> "Backlog
ordering".

## Open threads

- **Dual-VPN host routing.** `NordLynx` (personal) and `NordLayer-NordLynx`
  (employer) are both up, and NordLayer installs `0.0.0.0/1` + `128.0.0.0/1` at
  metric 0, so it wins general egress even while qBittorrent is bound to
  NordLynx. Torrent traffic therefore leaves via the work tunnel. PR #21 makes
  the app *accept* either interface; it does not change routing. Making torrents
  actually travel over NordVPN is host-level split tunneling - a separate task,
  not scheduled. Binding and routing are separate facts.
- **Discord token was printed to a terminal** during a `docker compose config`
  run. Not committed (`.env` is gitignored), solo use, so rotation deferred by
  decision. Rotate before sharing the project with anyone.
- Orphan-webhook cosmetic gap: a webhook with no matching job inserts
  `tmdb_id=0`, so RESOLVE_META resolves an empty title. Not on the normal path
  (a real `/download` submit creates the job with the true `tmdb_id`). Fix is a
  PTN-parse title fallback, tied to item 21.
- `WORKING-STATE.md` is a one-shot rollback document, now obsolete since the
  post-rework stack is verified live. Prune or archive it.

## Live pins

Four submodules match their pinned SHA. **torrent-downloader is ahead** - it
sits on `feat/configurable-vpn-interfaces` pending PR #21.

| Submodule | Version | Note |
|---|---|---|
| medialab-bot | v2.2.0 | |
| medialab-contracts | v0.3.0 | |
| medialab-jellyfin | v1.0.0-1-g080efb5 | |
| medialab-orchestrator | v0.4.2 | |
| torrent-downloader | v1.5.0-1-gb17e4ca | on feature branch, PR #21 open |

Verify with `git submodule status`; for build/run skew use `bin/medialab-status.sh`.

Note: the running downloader image is tagged `1.5.0.dev0` (built from a dirty
tree during live verification). Rebuild from the tag after merging so the image
carries a real version.

## Host notes

- Docker Desktop's port relay broke after a container recreate: `wslrelay` and
  `com.docker.backend` both held port 8000 on IPv6 only, with nothing on IPv4,
  so `curl localhost:8000` returned `000` while the app was healthy over the
  Docker network. A Docker Desktop restart cleared it. Worth remembering as a
  first check when the host cannot reach a published port but containers can
  reach each other.

---

## Maintaining this file

Rewrite it at the end of a working session, or whenever the answer to "where are
we" changes. Keep every section short - if a section grows past a screen, the
detail belongs in `CLAUDE.md` (durable design) or a spec file, not here.

When a backlog item completes, move its entry out of `CLAUDE.md` into
`ROADMAP-DONE.md`, keeping only the outcome and any durable lesson.
