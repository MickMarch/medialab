# Spec: uptime and autostart for the whole stack

Status: Approved
Issue: MickMarch/medialab#16

## Problem

Every piece of the stack is scoped to an interactive user login, not to the
machine being on. Observed on the host on 2026-09-21:

| Layer | How it starts today | Survives reboot without login? |
|---|---|---|
| Docker Desktop (engine for all four containers) | `HKCU\...\Run` at login of user Shadow; `com.docker.service` is `Manual` and is only the privileged helper | no |
| qBittorrent | `HKCU\...\Run` at login | no |
| Jellyfin | `Jellyfin.Windows.Tray.exe` in `HKCU\...\Run`; the tray process spawns `jellyfin.exe` | no |
| The four containers | `restart: unless-stopped`; come back once the engine does | only if the engine does |

`AutoAdminLogon` is `0`. After any reboot (Windows Update at night, a power
blip, a crash) nothing is up until someone logs in at the keyboard. The remote
Discord surface is exactly the thing you cannot use to fix that.

What is already right: sleep on AC is `0` (never), hibernate is off, wake timers
are allowed, and the containers already restart themselves. Fast startup is on
(harmless here).

## Goal and non-goals

**Goal.** "The stack is up" means: the gateway answers
`GET /api/v1/health` with both downstream workers `true`, and the bot is logged
in to Discord. That state must be reached automatically after a cold boot with
nobody at the keyboard, and after Docker Desktop, qBittorrent or Jellyfin
restarts on their own.

**Non-goals.** Waking the host from power-off or sleep (Wake-on-LAN, smart
plug). The NIC driver exposes no power-management properties to Windows, so
WoL would need BIOS work first; the host does not sleep on AC, so the only
wake case is a hard power loss. Deferred; folded into the containerization
item if it ever matters.

## Design

Three layers, each made to start with the machine rather than with a login.

### 1. Docker engine at boot

Docker Desktop on Windows has no service mode; it needs an interactive
session. Two ways to get one at boot:

- **(a) Automatic logon + immediate lock.** Configure Windows to log the
  `Shadow` account in at boot, and a Task Scheduler task at logon that runs
  `rundll32.exe user32.dll,LockWorkStation` so the desktop is never left open.
  Everything that starts at login today (Docker Desktop, qBittorrent, the
  Jellyfin tray) starts at boot with no other change. Credential is stored by
  Windows in the LSA secret store (Sysinternals `Autologon`, not the plain
  registry `DefaultPassword`).
- **(b) Docker Engine inside WSL2 as a systemd service**, no Docker Desktop.
  A scheduled task at startup runs `wsl -d Ubuntu --exec true` to boot the
  distro; `systemd` starts `docker.service`; the Windows `docker` CLI talks to
  it over the WSL socket. Boot-scoped and headless, but it replaces Docker
  Desktop's tooling and networking (`host.docker.internal` must be recreated
  via `/etc/hosts` or the WSL mirrored-networking mode), which every service
  `.env` depends on.

**Decision: (a).** It is the smallest change that meets the goal, keeps the
tooling the rest of the workspace assumes, and the machine is a single-user
gaming PC that is physically at home. (b) is the right answer for a headless
server and is the path the containerization item would take; it is not
needed here.

### 2. Host apps

- **qBittorrent:** unchanged. It already starts at login, which (a) turns into
  boot. It must keep running in the interactive session because its Web UI
  and search plugins live in the GUI process.
- **Jellyfin:** register `jellyfin.exe --service` as a Windows service with
  `sc.exe`, pointed at the data directory the tray-launched server already
  uses (`C:\ProgramData\Jellyfin\Server`), so libraries and metadata are
  untouched and no reinstall is needed. The service starts at boot regardless
  of login and survives a logoff; the tray is removed from login startup so
  two servers never fight over the port. This removes the one dependency the
  pipeline has on a GUI process being alive on the host.

### 3. Verification: a doctor script

`bin/medialab-doctor.sh` reports, in one table, every layer of "the stack is
up":

| Check | How |
|---|---|
| Docker engine reachable | `docker info` |
| Each compose service running and healthy | `docker compose ps --format json` |
| qBittorrent Web UI answering | `GET http://127.0.0.1:8080/api/v2/app/version` (401 counts as up) |
| Jellyfin answering | `GET http://127.0.0.1:8096/health` |
| Gateway health with both workers `true` | `GET http://127.0.0.1:8000/api/v1/health` |
| Bot logged in | last `Logged in as` line in the bot container log newer than the container start |

Exit non-zero on any failure so it can be run by hand after a reboot or from
a scheduled task. It is a read-only check; it starts nothing.

### 4. Host recipe, documented once

A `docs/host-setup.md` page holds the exact steps for (1) and (2) with the
verification command, so the recipe is repeatable on a rebuilt machine and is
the input to the setup wizard (MickMarch/medialab#23) later. No step is
automated by the workspace; each is a one-time host action.

## Decisions

1. Autologon plus lock over a WSL2 engine. Rejected (b) for scope: it changes
   networking assumptions in every `.env` for a problem (a) already solves on
   this host.
2. Jellyfin as a Windows service, not the tray. Rejected keeping the tray:
   it ties the media server to a GUI session for no benefit.
3. qBittorrent stays a login-session GUI app. Rejected a scheduled task in
   session 0: the Web UI and the search plugins need the GUI process.
4. Doctor script is read-only. Rejected an auto-remediation script: starting
   things is what autostart is for; the doctor tells you which layer failed.
5. Wake-on-LAN deferred (non-goal above).
6. Automatic logon accepted for this single-user machine at home (see Open
   questions).

## Open questions

None. Automatic logon was accepted on 2026-09-21: anyone who can power the
PC on gets a logged-in-but-locked session; the lock task closes the desktop
within seconds of logon and the account password still gates the lock
screen. Recorded as decision 6.

## Test plan

No service code changes, so no unit tests. Acceptance is a live check:

1. `bin/medialab-doctor.sh` green on the current running stack (baseline).
2. Reboot the host and do not touch the keyboard. Within five minutes,
   `bin/medialab-doctor.sh` green from another machine over SSH or, failing
   that, the Discord bot answers `/storage`.
3. Log off. Jellyfin stays reachable (service). Docker and qBittorrent go
   down: expected and documented; a logoff is not a reboot.

## Rollout

1. Root PR: `bin/medialab-doctor.sh` + `docs/host-setup.md` + this spec.
2. Host: Jellyfin service registration, Autologon, lock task. Each step has a
   verification line in `docs/host-setup.md`.
3. Reboot test per the test plan; record the result on the issue; spec to
   Shipped.
