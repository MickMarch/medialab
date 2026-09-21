# 0007 - Boot-scoped, not login-scoped

Date: 2026-09-21. Spec: `docs/specs/uptime-autostart.md`.

## What happened

The stack looked always-on because the host had been up for 12 days. Every
layer was in fact tied to an interactive login: Docker Desktop, qBittorrent
and the Jellyfin tray all started from the user's `Run` key, and automatic
logon was off. One reboot with nobody at the keyboard and the Discord surface,
the only remote control there is, would have stayed dark.

Three surprises while fixing it:

- Jellyfin's `--service` flag runs headless but never signals the Windows
  Service Control Manager. Registered with `sc.exe` it is killed at the 30 s
  timeout while its own log says `Startup complete`. The installer hides this
  behind NSSM. A SYSTEM scheduled task at startup does the job with nothing to
  download.
- Docker Desktop honours its own `AutoStart` setting over its `Run` entry.
  With the setting off, the app launches at logon and quits.
- Windows PowerShell 5.1's JSON cmdlets drop keys when round-tripping Docker's
  settings file; Docker then refuses to start. Edit such files by text
  replacement.

## Decision

- "Up" is defined by `bin/medialab-doctor.sh`, not by whether things happen to
  be running. Every layer must reach that state from a cold boot with no login.
- Prefer the mechanism that is boot-scoped by construction (a SYSTEM task, a
  real service) over one that depends on a session. Where a session is
  unavoidable (Docker Desktop, qBittorrent's GUI), make the session automatic
  and lock it.
- Verify with a reboot, not with the running stack. A long uptime proves
  nothing about startup.
