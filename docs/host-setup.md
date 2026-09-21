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

## 1. Jellyfin as a Windows service

Jellyfin ships a `--service` mode. Register it as a service that starts at
boot, using the same data directory the tray-launched server already uses
(`C:\ProgramData\Jellyfin\Server`), so libraries and metadata are untouched.
Run in an elevated PowerShell:

```powershell
sc.exe create JellyfinServer binPath= "\"C:\Program Files\Jellyfin\Server\jellyfin.exe\" --service --datadir \"C:\ProgramData\Jellyfin\Server\"" start= auto DisplayName= "Jellyfin Server"
sc.exe description JellyfinServer "Jellyfin media server (medialab)"
sc.exe failure JellyfinServer reset= 86400 actions= restart/5000/restart/30000/restart/60000
```

Then stop the tray-launched instance and start the service:

```powershell
Stop-Process -Name Jellyfin.Windows.Tray -Force; Stop-Process -Name jellyfin -Force
Start-Service JellyfinServer
```

Remove the tray from login startup so two servers never fight over the port:

```powershell
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name JellyfinTray
```

Verify: `Get-Service JellyfinServer` shows `Running`, and
`curl http://127.0.0.1:8096/health` prints `Healthy`.

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

## 3. Things already right, left alone

- qBittorrent starts at logon from `HKCU\...\Run` and must stay a GUI process
  (its Web UI and search plugins live there).
- Docker Desktop starts at logon from `HKCU\...\Run`; the containers carry
  `restart: unless-stopped`.
- Power plan: sleep on AC is never, hibernate off, wake timers allowed.

## Acceptance

Reboot and do not touch the keyboard. Within five minutes
`bin/medialab-doctor.sh` is all `ok` (run it over SSH, or ask the bot
`/storage` from Discord). A logoff is not a reboot: Jellyfin survives it,
Docker and qBittorrent do not, by design.
