# Spec: credential health

Status: Shipped
Issue: MickMarch/medialab#136

Allowed statuses: Draft, Approved, Shipped, Superseded. No implementation code
before Approved. No version numbers anywhere in a spec.

## Problem

Every external system the stack talks to is gated by a credential the operator
supplied once: the TMDB key, the Jellyfin key, the Discord token, the
qBittorrent key, the VPN key. When one expires or is revoked, nothing says so.
A bad TMDB key shows up as a failed search, a bad Jellyfin key as a job stuck
before its library scan, a bad Discord token as a bot that is simply offline,
which is exactly the surface the operator would use to find out. The gateway
health endpoint reports whether each worker is reachable, not whether the
worker can reach what it fronts.

## Goal and non-goals

**Goal.** Each worker checks its own credentials on a schedule and whenever an
upstream call is refused, and reports a per-credential state through its
health endpoint. The orchestrator aggregates the states into the health
response every client already reads. The operator is told plainly which
credential is wrong, through a banner in the web UI, one Discord message per
change, and a Windows notification on the host, and the notification opens
the install wizard on that one field. Fixing a credential rewrites its `.env`
and recreates only the container that holds it.

**Non-goals.** Rotating credentials automatically; the operator obtains a new
key from the console as today. Monitoring anything that is not a credential
(disk, VPN tunnel, container liveness all have their signals). A resident
host agent; the host check is a scheduled task. Credentials that never
leave the host: the web password and the inter-service keys are generated
and verified by the install itself.

## Design

### Which credential lives where

| Credential | Owner | Check | Refusal signal classified |
|---|---|---|---|
| TMDB API key | torrent-downloader | `GET /3/configuration` | 401 |
| qBittorrent WebUI key | torrent-downloader | `GET /api/v2/app/webapiVersion` | 403 |
| Jellyfin API key | medialab-jellyfin | `GET /System/Info` | 401 |
| Discord bot token | medialab-bot | the gateway login result | `LoginFailure` |
| VPN key | gluetun | already observable: tunnel health and `vpn_interface_bound` | n/a |

The owner is the service that holds the key in its `.env` and makes the
calls; nothing else learns the key. The VPN key stays out: a dead tunnel is
already a red doctor row and a `vpn_interface_bound: false`, and gluetun
offers no key check that the tunnel check does not already imply.

### Wire model (medialab-contracts)

```
CredentialStatus = ok | invalid | unreachable | unknown
CredentialState  { status, checked_at: datetime | None, detail: str }
CREDENTIAL_TMDB_API_KEY = "tmdb_api_key"
CREDENTIAL_QB_API_KEY = "qb_api_key"
CREDENTIAL_JELLYFIN_API_KEY = "jellyfin_api_key"
CREDENTIAL_DISCORD_TOKEN = "discord_token"
```

The names equal the `Answers` field names in medialab-setup, so a state maps
to a wizard field with no translation table. `unreachable` means the service
could not be asked (network, outage); `unknown` means not checked yet.
Only `invalid` is a problem the operator can fix.

### Workers

Each owning worker gains a `credentials: dict[str, CredentialState]` field on
its existing `HealthResponse` and a small checker:

- **Scheduled probe.** An asyncio task runs the check for each owned
  credential every `CREDENTIAL_CHECK_INTERVAL_SECONDS` (default six hours;
  a runtime setting through the existing registry) and at startup after a
  short delay. Probes are one cheap read-only call each, far below any rate
  limit.
- **Refusal classification.** The client wrapper that makes upstream calls
  already sees the status code. A 401 from TMDB or Jellyfin, or a 403 from
  qBittorrent, sets that credential to `invalid` at once with the status in
  `detail`; the next successful call sets it back to `ok`. No extra traffic.
- The bot has no HTTP server. It reports its login result to the gateway:
  `POST /api/v1/credentials/discord_token` with `CredentialState`, sent after
  a successful login and after the final failed attempt of its existing
  retry loop. The orchestrator stores the last report with its timestamp.

### Orchestrator

`GET /api/v1/health` gains `credentials: dict[str, CredentialState]`: the
union of each reachable worker's map and the bot's last report. A worker that
is unreachable contributes its credentials as `unreachable`. The existing
health poll (`HEALTH_POLL_INTERVAL_SECONDS`) already fetches downstream health
on a schedule; it now also diffs the credential map against the last seen
map and, on any transition into or out of `invalid`, posts one Discord
message through the existing notify webhook when one is configured. Last
seen states persist in the orchestrator's settings store so a restart does
not re-announce.

### Web UI

A site-wide banner partial, polled by htmx on every page at a slow interval
(the `/health` call is local and cheap), lists each `invalid` credential by
its guide title with a link to the install wizard's fix URL on the host
(`setup.cmd` is on the host, so the banner shows the command to run and the
field name rather than a clickable launch; the toast below is the clickable
path). The Services card on the storage page gains one row per credential.

### Host notification (medialab-setup)

A `check-credentials` command reads the gateway health and, for each
`invalid` credential, raises a Windows toast through PowerShell's WinRT
notification API (no extra module) with the guide title and a button that
runs `setup.cmd --fix <name>`. It remembers what it last toasted in the
state dir so a standing problem is announced once per day, not every run.
The host phase gains one more step, "Credential check task", a scheduled
task running the command every thirty minutes at logon and on a schedule,
applied with the other non-elevated steps and listed on the wizard's Next
steps panel.

### Repair (medialab-setup wizard)

`setup.cmd --fix <name>` and `medialab-setup wizard --fix <name>` open the
credentials page with every field collapsed except the named one, its guide
popover open, and the submit button labelled "Replace and restart". Submit
runs the existing collect and generate (only that key changes), then
`docker compose up -d <owning service>` to recreate the one container, then
polls the gateway health until that credential reads `ok` or a short window
passes, and shows the result. No build, no provision, no doctor: the phases
are reused as functions, not as the full chain.

## Decisions

1. **Owners check their own credentials; the orchestrator only aggregates.**
   Matches "service per capability": the key never leaves the worker that
   uses it, and the check is one more use of the client that already exists.
   Rejected a central checker in the orchestrator: it would need every key.
2. **State rides on the existing health endpoints.** Clients already poll
   `/health`; a new endpoint would mean a second poll everywhere. Rejected a
   separate `/credentials` route for the same reason.
3. **Refusal classification plus a slow probe, not a fast probe.** A refusal
   is detected the moment it matters, at zero extra traffic; the probe only
   catches keys that expired while idle. Six hours is ample for that.
4. **Names shared with the setup tool's answer fields.** One vocabulary from
   the health response to the wizard field; declared once in contracts.
5. **The bot reports its login result to the gateway.** It is the only owner
   without an HTTP surface, and a failed login is the one case Discord cannot
   announce itself. Rejected the doctor as the only signal: it runs after
   logon, not when the token dies.
6. **Discord messages on transitions only, persisted.** Rejected a message
   per poll: a dead key at night would post dozens of times.
7. **A scheduled task raises the toast, not a resident process.** Same
   pattern as the doctor-after-logon task; the thirty-minute cadence bounds
   how long a problem goes unseen on the host, and the daily dedupe bounds
   noise. Rejected a tray app: a new process to install, update and debug.
8. **Repair recreates one container and verifies through health.** The
   wizard's phases are functions; the fix path calls collect, generate and
   compose for one service. Rejected re-running the full install: builds
   and provisioning have nothing to do with a key.
9. **VPN key excluded.** Its failure is already loud and already named by the
   doctor and the gateway; a second signal for it would be redundant.

10. **Probe every six hours by default, as a bounded runtime setting.** One
    read-only call per credential per interval is negligible for every
    service involved; the setting lets an operator tighten it. Rejected a
    fixed constant: the runtime settings registry exists for exactly this.
11. **One toast per credential per day.** A standing problem is announced,
    not nagged; the web banner and Discord message remain visible meanwhile.
    Rejected per-run toasts: thirty-minute reminders train the operator to
    dismiss them.
12. **No banner on the web login page.** The banner needs the gateway call,
    which needs a session; the login page stays static.

## Open questions

None. The draft's three questions were accepted as proposed and recorded as
decisions 10 to 12.

## Test plan

- **medialab-contracts**: `CredentialState` validation, status enum values,
  the four names exist and are unique.
- **torrent-downloader / medialab-jellyfin**: health response carries the
  map; a mocked client returning the refusal status flips the state to
  `invalid` on the next call and back to `ok` after a success; the probe task
  runs at startup and on the interval with a faked clock; the interval is a
  runtime setting with bounds.
- **medialab-bot**: the login loop posts `ok` after success and `invalid`
  after the last failed attempt, through the mocked gateway client class.
- **medialab-orchestrator**: aggregation of reachable and unreachable workers;
  the bot report endpoint stores and serves the state; the health poll posts
  one notification per transition and none when unchanged, with the last
  seen map persisted and reloaded.
- **medialab-web**: the banner partial lists invalid credentials by title and
  renders nothing when all are `ok`; the Services card rows.
- **medialab-setup**: `check-credentials` toasts once per day per invalid
  credential through a faked PowerShell runner; the host step row exists and
  applies; the wizard `--fix` page shows one field expanded; the fix submit
  rewrites the one key, recreates the one service and verifies through
  health, all with the existing fakes.
- Root `bin/tests`: `setup.cmd` forwards `--fix`.

## Rollout

1. medialab-contracts: model and names; release.
2. torrent-downloader and medialab-jellyfin: health field, classification,
   probe, setting; release each.
3. medialab-orchestrator: aggregation, bot report endpoint, transition
   notifications; release.
4. medialab-bot: login report; release.
5. medialab-web: banner and card rows; release.
6. medialab-setup: `check-credentials`, host step, wizard `--fix`; release.
7. Root: `setup.cmd --fix`, pins, README line, spec to Shipped.
8. Acceptance on the host: revoke the TMDB key in the console, see the
   banner, the Discord message and the toast within the probe interval or
   on the next search; click through to the fix; confirm `ok` returns.

## Result

Shipped across seven releases in the rollout order: contracts (models and
names), torrent-downloader and medialab-jellyfin (owner checks, probe,
`credentials` on health), medialab-orchestrator (aggregation, bot report
endpoint, transition notices with a JSON ledger), medialab-bot (login
report), medialab-web (banner and card rows), medialab-setup
(`check-credentials`, the host task, `wizard --fix`), then `setup.cmd --fix`
at the root. Two notes from implementation:

- The Jellyfin worker has no runtime settings registry, so its probe interval
  is env-only (`CREDENTIAL_CHECK_INTERVAL_SECONDS`); the downloader exposes
  it as a runtime setting as well.
- The toast button opens a generated `fix-<name>.cmd` in the state dir
  rather than passing arguments: WinRT toast actions launch a file or URI,
  not a command line.

Acceptance (revoke the TMDB key, see banner, Discord notice and toast, fix
through the wizard) is pending the next deploy of the stack, which is also
the first live `update` run.
