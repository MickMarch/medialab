# Host setup: making the stack start with the machine

One-time steps on the Windows host so the whole stack is up after a cold boot
with nobody at the keyboard. Design and rationale:
[docs/specs/uptime-autostart.md](specs/uptime-autostart.md). Verify any time
with:

```bash
bin/medialab-doctor.sh
```

Every row `ok` means the stack is up: Docker engine, the four containers,
qBittorrent's Web UI, Jellyfin, the gateway with both workers reachable, and
the bot logged in to Discord.

## 1. Jellyfin at boot as a SYSTEM scheduled task

Jellyfin's `--service` flag runs headless but does not perform the Windows
Service Control Manager handshake: registered with `sc.exe`, it logs
`Startup complete` and is then killed at the 30 s timeout (event 7009). The
official installer works around that with NSSM. Without adding a download, the
boot-scoped equivalent is a Task Scheduler task running as `SYSTEM` at startup
with restart-on-failure, pointed at the data directory the tray-launched server
already uses (`C:\ProgramData\Jellyfin\Server`) so libraries and metadata are
untouched. Run in an elevated PowerShell:

```powershell
$action    = New-ScheduledTaskAction -Execute "C:\Program Files\Jellyfin\Server\jellyfin.exe" -Argument '--service --datadir "C:\ProgramData\Jellyfin\Server"' -WorkingDirectory "C:\Program Files\Jellyfin\Server"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "medialab-jellyfin-server" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

Then hand over from the tray-launched instance and start the task:

```powershell
Get-Process Jellyfin.Windows.Tray, jellyfin -ErrorAction SilentlyContinue | Stop-Process -Force
Start-ScheduledTask -TaskName "medialab-jellyfin-server"
```

Disable the tray's login autostart so two servers never fight over the port
(this is the same flag Task Manager's "Disable" sets; the Run entry stays for
manual use):

```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -Name JellyfinTray -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force
```

Verify (elevated, the task runs as SYSTEM): `Get-ScheduledTask medialab-jellyfin-server`
is `Running`, and `curl http://127.0.0.1:8096/health` prints `Healthy`.

## 2. Automatic logon plus immediate lock

Docker Desktop and qBittorrent need an interactive session. Windows logs the
account in at boot and a task locks the desktop seconds later.

1. Automatic logon. Use Sysinternals Autologon so the credential lands in the
   LSA secret store, not the plain registry:
   https://learn.microsoft.com/sysinternals/downloads/autologon. Run it,
   enter the account and password, click Enable. This is the one step that
   needs the account password typed by its owner.
2. Lock-at-logon task (elevated PowerShell):

   ```powershell
   $action  = New-ScheduledTaskAction -Execute "rundll32.exe" -Argument "user32.dll,LockWorkStation"
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
   $trigger.Delay = "PT10S"
   Register-ScheduledTask -TaskName "medialab-lock-at-logon" -Action $action -Trigger $trigger -RunLevel Limited -Force
   ```

Verify: `Get-ScheduledTask medialab-lock-at-logon` is `Ready`;
`(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon").AutoAdminLogon`
is `1`.

## 3. Docker Desktop: its own autostart switch must be on

Docker Desktop keeps a `Run` entry at `HKCU\...\Run` but honours its own
setting, `AutoStart` in `%APPDATA%\Docker\settings-store.json`, over that
entry. With `AutoStart: false` the app exits immediately at logon and nothing
in the Docker layer comes up. Turn it on in Docker Desktop: **Settings >
General > Start Docker Desktop when you sign in to your computer**. Or, with
Docker Desktop fully quit, flip the one key by text edit:

```powershell
$f = "$env:APPDATA\Docker\settings-store.json"
[IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f) -replace '"AutoStart"\s*:\s*false', '"AutoStart": true'), (New-Object System.Text.UTF8Encoding($false)))
```

Do not round-trip that file through `ConvertFrom-Json | ConvertTo-Json` in
Windows PowerShell 5.1; it drops keys and Docker Desktop then refuses to start
with a settings-loading error.

Verify: `(Get-Content "$env:APPDATA\Docker\settings-store.json" -Raw | ConvertFrom-Json).AutoStart` is `True`.

## 4. Things already right, left alone

- qBittorrent starts at logon from `HKCU\...\Run` and must stay a GUI process
  (its Web UI and search plugins live there).
- The containers carry `restart: unless-stopped`; they return with the engine.
- Power plan: sleep on AC is never, hibernate off, wake timers allowed.

## Acceptance

Reboot and do not touch the keyboard. Within five minutes
`bin/medialab-doctor.sh` is all `ok` (run it over SSH, or ask the bot
`/storage` from Discord). A logoff is not a reboot: Jellyfin (SYSTEM task) survives it,
Docker and qBittorrent do not, by design.
