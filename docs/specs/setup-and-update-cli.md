# Spec: medialab-setup, the install and update CLI

Status: Shipped
Issue: MickMarch/medialab#23 (setup), MickMarch/medialab#129 (update)

Allowed statuses: Draft, Approved, Shipped, Superseded. No implementation code
before Approved. No version numbers anywhere in a spec.

## Problem

Standing the stack up on a fresh host is a README walk: copy seven `.env`
templates, obtain six third-party credentials from six web consoles, invent
five inter-service API keys and paste each into two files that must match,
create the media folders, run the qBittorrent provision script, start compose,
then follow `docs/host-setup.md` for autostart. `docs/secrets.md` already
records that the key pairs "are hand-synced today" and names the wizard as the
fix. Updating is the same shape in miniature: pull the root repo, update
submodules to their pins, rebuild, recreate, run the doctor, and there is no
documented way back when the new images misbehave.

Both procedures are correct and both are unrepeatable by anyone but the
author. The project is meant to be shared; a reader who clones it should reach
a green doctor without reading `bin/` to learn what order things happen in.

## Goal and non-goals

**Goal.** One CLI, `medialab-setup`, run on the Windows host before any
container exists, with two commands. `setup` takes a fresh clone to a running,
verified stack from a single question-and-answer pass, generating every shared
value once and writing every `.env` from it; it is idempotent, so re-running it
on a configured host changes nothing it was not asked to change. `update`
moves a running stack to the current pins, rebuilds, recreates, verifies, and
restores the previous state when verification fails. Both end by running the
existing doctor and both can be run with `--dry-run` to print the plan.

**Non-goals.** A graphical installer, an MSI, or a Windows service. Linux or
macOS hosts (the host-level steps are Task Scheduler and Windows Firewall; a
Linux path is a later spec). Publishing images to a registry (images build from
source, as today). Installing anything `winget` cannot: the tool runs
`winget` for Git, `uv`, Docker Desktop and Jellyfin and otherwise opens the
download page.
Collecting any VPN account password or storing a credential anywhere other than
the `.env` it belongs in. Replacing `bin/medialab-doctor.sh`,
`bin/medialab-qbt-provision.sh` or `bin/medialab-release.sh`; the CLI drives
them.

## Design

### Shape

`medialab-setup` is its own repository and submodule, a `uv` project like the
services, published nowhere: it runs from the clone with
`uv run --project medialab-setup medialab-setup <command>` and the root repo
ships a two-line `bin/medialab-setup.sh` wrapper so the README command is
short. Dependencies: `typer` for the command tree, `rich` for tables and
progress, `questionary` for prompts, `pydantic` + `pydantic-settings` for the
answer model, `httpx` for the few live checks. It never imports a service
package; the facts it needs about services come from `docker-compose.yml` (the
service list, as `bin/lib.sh` does) and from each service's `.env.example`
(the variable list, which stays the authoritative schema).

```
medialab-setup
  setup   [--express | --custom] [--answers FILE] [--dry-run] [--skip-host]
  update  [--to <root-ref>] [--dry-run] [--no-rollback]
  plan    (alias of setup --dry-run)
```

### The answer model

Every value the operator can decide lives in one Pydantic model, `Answers`,
grouped by the section that asks for it. A value is one of three kinds:

| Kind | Examples | Behaviour |
|---|---|---|
| asked | TMDB key, Jellyfin key, Discord token and guild, VPN provider block, media root, web password | prompted, with the "where to get this" text lifted from `docs/secrets.md`; existing `.env` value offered as the default |
| generated | orchestrator `API_KEY`, downloader `API_KEY`, jellyfin-worker `API_KEY`, `QB_API_KEY`, `WEB_SECRET_KEY` | never prompted; generated with `secrets.token_urlsafe` once, reused on re-run if already present in the owning `.env` |
| derived | both halves of every key pair in `docs/secrets.md`, `MEDIA_HOST_DIR`, `TZ`, the subnet | computed from an asked or generated value; written to every file that needs it so the pairs cannot drift |

`--express` asks only the asked values that have no sane default (the six
credentials and the media root) and takes every other default. `--custom`
walks every asked value and every tunable in the `.env.example` files, showing
the template's comment as help. `--answers FILE` reads an `Answers` JSON or
TOML file and asks nothing; the tool writes one back to a gitignored
`.medialab-setup/answers.toml` after every run, with secret fields redacted
and marked as living in their `.env`, so a rebuilt machine can replay the
non-secret decisions.

### `setup` phases

Phases run in order; each is a function that reports a table row per check or
action and raises on failure, so a failing phase stops the run with every
earlier phase's effect intact and visible.

1. **Preflight.** Checks first, installs second. Git with submodules
   initialised, `uv`, Docker Desktop, Jellyfin, free space on the media
   drive, the published ports (`8081`, `8000`, `QBT_WEBUI_PORT`, `8096`) not
   held by a foreign process, and a warning when a host qBittorrent is
   installed (two clients would fight over the staging folders). For each
   missing prerequisite with an unattended `winget` package (Git, `uv`,
   Docker Desktop, Jellyfin Server) the tool shows the exact `winget install`
   line and runs it on confirmation, once per item; where `winget` is absent
   or the package fails it opens the vendor download page in the browser and
   waits for the operator to finish. Docker Desktop and Jellyfin may need a
   logout or reboot after install; the tool says so and resumes from Preflight
   when re-run, since every earlier result is re-derived, not stored.

2. **Collect.** Build `Answers` from existing `.env` files, then the answers
   file, then prompts, in that precedence. Live-validates each asked
   credential where a cheap read-only call exists: TMDB `GET /configuration`,
   Jellyfin `GET /System/Info`, Discord `GET /users/@me`. A failed validation
   re-prompts; `--answers` mode fails instead.
3. **Generate.** Write the root `.env`, each service `.env`, and
   `gluetun/vpn.env`. Each file is rendered from its own `.env.example`: every
   key in the template appears, in template order, with the template's
   comments kept, and the value from `Answers`. A key present in an existing
   `.env` but absent from the template is kept at the end under a
   "not in template" comment, never dropped. Files are written atomically
   (temp file then rename) and the existing file is copied to
   `.medialab-setup/backup/<timestamp>/` first. Also creates
   `<media root>/Movies`, `<media root>/Shows`, and the two `_incoming`
   staging folders.
4. **Build.** `bin/medialab-build.sh`, streamed.
5. **Provision.** `bin/medialab-qbt-provision.sh`, streamed; then compose
   `up -d` with both env files as the README shows; then, through the running
   medialab-jellyfin worker's `POST /library/paths`, register `Movies` and
   `Shows` as Jellyfin library roots if they are not already (decision
   `0005-register-once`). Never `_incoming`.
6. **Host.** Skipped with `--skip-host`. The steps in `docs/host-setup.md`,
   each as a check-then-apply pair that prints the PowerShell it is about to
   run and asks once per step: Jellyfin as a SYSTEM startup task, disable the
   Jellyfin tray's login autostart, lock-at-logon task, Docker Desktop
   `AutoStart`, the after-logon doctor task, the LAN firewall rule for the
   web UI. Steps that need elevation are run through a single elevated
   PowerShell child so UAC prompts once. Automatic logon is **not** automated:
   it needs the account password typed by its owner into Sysinternals
   Autologon, so the tool prints that step and waits for confirmation.
7. **Verify.** `bin/medialab-doctor.sh`. Exit code is the doctor's.

### `update` phases

1. **Check.** Table per service: running image version (from the container
   label), pinned tag (submodule pin at the current root commit), and the
   target pin (after fetching `origin/main`, or `--to`). Lists the root
   commits between here and the target with their subjects, so the operator
   sees which releases they are about to take. Exits zero with "up to date"
   when nothing moves.
2. **Snapshot.** Record the current root commit, the current `.versions.env`,
   and copy every `.env` to `.medialab-setup/backup/<timestamp>/`. The
   snapshot is the rollback target.
3. **Fetch.** `git pull --ff-only` on the root (refuses on a dirty tree or a
   non-`main` branch, the same rule `medialab-release.sh` applies), then
   `git submodule update --init --recursive` so each service is at its pin.
4. **Migrate config.** For each service, diff `.env.example` keys against the
   service `.env`. New keys are appended with the template default and
   comment and listed in the table; removed keys are left in place and
   flagged. A new key with no default and no derivable value (a new secret)
   prompts, or fails under `--dry-run` or when stdin is not a terminal.
5. **Apply.** `bin/medialab-build.sh`, then compose `up -d` with both env
   files. A change to `gluetun/vpn.env` or the gluetun image recreates the
   whole namespace, which compose does on its own when the gluetun service
   changes; the tool does not special-case it.
6. **Verify.** `bin/medialab-doctor.sh`, retried for up to the same window
   the host-setup acceptance allows (five minutes) because gluetun must pass
   its health check before the downloader starts.
7. **Rollback** on verify failure unless `--no-rollback`: `git checkout` the
   snapshot root commit, `git submodule update`, restore the `.env` files
   from the backup, `bin/medialab-build.sh` (images for old tags are still
   present, so this is a cache hit), compose `up -d`, doctor again. Reports
   both doctor tables. The root checkout is left detached at the snapshot
   commit with a printed `git switch main` hint; the operator decides whether
   to retry.

### State and files

| Path | Owner | Committed |
|---|---|---|
| `medialab-setup/` | the tool's repo, pinned as a submodule | yes |
| `bin/medialab-setup.sh` | root repo wrapper | yes |
| `.medialab-setup/answers.toml` | non-secret decisions, replayable | no (gitignored) |
| `.medialab-setup/backup/<timestamp>/` | pre-write copies of every `.env`, root commit, `.versions.env` | no (gitignored) |
| every `.env`, `gluetun/vpn.env` | rendered output; still the runtime input compose reads | no (already gitignored) |

Secrets are only ever in the `.env` that owns them and in the process memory
of a run. The tool never prints a secret, logs one, or writes one to
`answers.toml`; Rich tables show `set` or `missing` for secret fields.

### Documentation changes

`README.md` "Running with Docker Compose" collapses to: clone, run
`bin/medialab-setup.sh setup`; the current manual steps move under a
"By hand" heading so the tool never becomes the only record of what it does.
`docs/secrets.md` drops "hand-synced today" and names the tool as the
generator; its credential table stays the source of the prompt help text.
`docs/host-setup.md` stays the design and verification record for each host
step; the tool's Host phase links each row to its section.

## Decisions

1. **A Python CLI in its own repo, not more bash in `bin/`.** The existing
   scripts are good at one thing each and stay. Prompting, validation, a typed
   answer model, atomic writes and tests are what bash is worst at, and every
   other repo here is a tested `uv` project; the tool follows the convention
   and gets CI, ruff, mypy and pytest for free. Rejected a setup page inside
   medialab-web: the web UI needs its `.env` and a running orchestrator before
   it can serve a page, so it cannot own first-run.
2. **`.env.example` stays the schema; the tool renders it.** Rejected moving
   config into a single root file or a generated compose override: per-service
   `.env` is what makes each service independently deployable (issue #23) and
   `pydantic-settings` in each service already validates it. The tool
   templates each file from its own example so a new setting added to a
   service needs no change in the tool.
3. **Generated secrets over asked secrets wherever nobody else needs the
   value.** Inter-service keys and the web cookie secret have no reason to be
   human-chosen; generating them removes five prompts and the pair-drift
   class of bug entirely.
4. **Build from source, no registry.** Rejected publishing to GHCR: it adds a
   public registry, a publishing workflow in every repo, and an image-pull
   path that would differ from how the author's own host runs. Rollback is
   cheap anyway because the previous images remain in the local Docker cache.
5. **Rollback is a root commit plus an `.env` backup, nothing more.** Rejected
   snapshotting the SQLite database: schema migrations are forward-only in
   the orchestrator and a release that breaks the database is a release bug
   to fix forward, not something to paper over on the host.
6. **Host steps are automated except automatic logon.** The one step that
   needs the account password is typed by its owner into Autologon, as
   `docs/host-setup.md` already requires. Rejected collecting the password:
   the tool must never hold a Windows credential.
7. **Live-validate credentials with read-only calls.** A wrong TMDB key found
   at prompt time costs one re-prompt; found after `compose up` it costs a log
   dive. Validation is skipped offline with a warning, never fatal.
8. **Prerequisites are installed through `winget` on confirmation, with the
   download page as the fallback.** Revised from "checked, not installed":
   the operator asked for the fewest manual downloads. `winget` runs the
   vendor installers unattended and is present on every supported Windows 10
   build; licence acceptance is passed on the command line and shown first.
   Jellyfin keeps the installer's default data directory, which is the one
   `docs/host-setup.md` already assumes. A reboot the installer needs is
   reported, never forced.
9. **One tool, two commands, one spec.** `setup` and `update` share preflight,
   the `.env` renderer, the build and compose steps, the doctor, and the
   backup directory; splitting them would duplicate the half of each that
   matters.

10. **`update` stays strictly at pins.** Rejected pulling a submodule past
    its pin as a convenience: moving a pin is what `medialab-release.sh` is
    for, and an unpinned service would make the running stack unreproducible.
11. **`setup` runs the first `compose up` itself.** Rejected stopping after
    `.env` generation: "one command to green" is the point; `--dry-run` shows
    the plan for anyone who wants to look first.
12. **Jellyfin library roots are registered by the tool, once.** Rejected
    registration in the medialab-jellyfin worker's startup: it would re-run on
    every container restart, against decision `0005-register-once`.

## Open questions

None. Items 1 to 3 of the draft were accepted as proposed and recorded as
decisions 10 to 12.

## Test plan

`medialab-setup` repo, pytest, no network, no `.env`:

- `test_answers_precedence`: existing `.env` beats answers file beats prompt
  default; a generated key already present is reused, not regenerated.
- `test_render_env_from_example`: every template key appears in order with
  its comment; an extra existing key survives under the "not in template"
  comment; output is byte-identical on a second render (idempotent).
- `test_pairs_never_drift`: after rendering all files, each pair in the
  `docs/secrets.md` table holds equal values; the table is encoded as a
  fixture so a new pair is one line.
- `test_atomic_write_and_backup`: a failing write leaves the previous file
  intact and a backup copy exists.
- `test_no_secret_in_output`: rendered Rich tables and `answers.toml` contain
  none of the secret fixture values.
- `test_preflight_reports_each_missing_prereq` with the shell and Docker
  clients mocked at the client-class boundary.
- `test_migrate_env_adds_new_keys_flags_removed`: fixture `.env.example`
  gains and loses a key; the `.env` gains the new one with default and
  comment and keeps the removed one flagged.
- `test_update_check_table`: fixture compose JSON and submodule pins produce
  the expected running/pinned/target rows and the "up to date" exit.
- `test_rollback_restores_snapshot`: with git and compose mocked, a failing
  doctor restores the recorded commit and `.env` files and runs the doctor
  again.
- `test_dry_run_writes_nothing`: every phase under `--dry-run` leaves the
  filesystem hash unchanged.
- `@pytest.mark.integration`: live TMDB, Jellyfin and Discord validation
  calls; a real `setup --express --answers` against a scratch clone on the
  host.

Root repo, `bin/tests/test_lib.sh` style: the wrapper script resolves the
tool and forwards arguments and exit code.

## Rollout

1. New repo `medialab-setup` from the shared tooling (CI calling
   `python-ci.yml`, pre-commit, dependabot, `[tool.ruff]` and `[tool.mypy]`
   identical so `bin/medialab-drift.sh` passes). Added as a submodule.
   Closes MickMarch/medialab#23 when `setup` lands; `update` is a second PR
   that closes MickMarch/medialab#129.
2. Root PR: submodule pin, `bin/medialab-setup.sh`, `.gitignore` entry for
   `.medialab-setup/`, README and `docs/secrets.md` edits, this spec to
   Shipped.
3. Acceptance on the host: `setup --express` from a scratch clone in a
   separate directory with a scratch media root reaches a green doctor; then
   `update` on the real stack after the next service release, once with a
   deliberately broken `.env` to exercise rollback.
4. A `docs/decisions/` note if the work teaches one; the candidate is
   "the template is the schema" (decision 2) if it holds up.

## Result

Shipped as the `medialab-setup` submodule with `plan`, `setup` and `update`.
Two refinements found during implementation, neither changing a decision:

- Decision 12 (library roots registered by the tool): registration goes to
  Jellyfin on the host directly with the operator's key, not through the
  medialab-jellyfin worker. The worker publishes no port, and its
  `/library/paths` only appends a path to a library that already exists; a
  fresh server has none, so the tool must create the library.
- Host checks must work without elevation. `Get-ScheduledTask` and
  `Get-NetFirewallRule` return nothing for a standard user on this host; the
  SYSTEM task is probed through its task file (access denied means present)
  and the firewall rule through `netsh`'s exit code.

Lesson recorded: `docs/decisions/0010-the-template-is-the-schema.md`.
