# Findings

Status: Complete (run 2026-10-02, NordVPN via gluetun, Docker Desktop on Windows 10)

Outcomes of the lab, feeding the spec revision for
[MickMarch/medialab#28](https://github.com/MickMarch/medialab/issues/28).

## Results

| # | Question | Result | Evidence | Consequence for the spec |
|---|---|---|---|---|
| 1 | Kill-switch | PASS | Tunnel public IP differed from host IP. With the tunnel stopped through the control server, `curl` from inside the namespace got no route at all. Tunnel restored on its own after `PUT running`. | gluetun firewall is the physical layer the spec wants. No app code involved. |
| 2 | API over compose network, Bearer key, bound interface | PASS | Probe reached `http://gluetun:8080/api/v2` with `Authorization: Bearer`, web API 2.15.1. `current_interface_name` reads `tun0`. Host header validation stayed on and accepted `gluetun:8080`; it only rejected the port-mapped `127.0.0.1:8090`. | `QB_HOST=gluetun`, `VPN_INTERFACES=tun0` become the shipped defaults. No validation or CSRF relaxation needed. |
| 3 | Hook egress by IP, by name, tooling | PASS, PASS | With `FIREWALL_OUTBOUND_SUBNETS` set to the compose subnet, the hook reached the webhook both by IP and by service name. Image ships `curl` and Python 3.14. A real completion fired the autorun command and the webhook received hash, name and `content_path`. | Completion hook is a one-line `curl` in the autorun preference, pointing at `http://medialab-orchestrator:8000/...`. `notify_complete.py` is no longer needed in the containerized layout. |
| 4 | Provisioning without clicks | PASS | Every needed setting is reachable through the API with a cookie session: interface (`current_network_interface`), autorun, save path, queueing, upload limit, admin password (`web_ui_password`), plugin install (`search/installPlugin`). API key is created by `POST app/rotateAPIKey`, which returns it, and is stored in plain text as `WebUI\APIKey` in `qBittorrent.conf`. Everything survived a container restart. | Two viable provisioning paths; see below. |
| 5 | gluetun restart and recreate | PASS with rule | `restart gluetun` kept qBittorrent attached. `up -d --force-recreate gluetun` left qBittorrent on a dead namespace; a plain `docker compose up -d` recreated it and everything came back. Startup to healthy took 30 to 60 s because Nord's first server often failed the health check and gluetun rotated. | Compose must keep `depends_on: gluetun: condition: service_healthy`. Provider switch procedure is "edit vpn.env, `docker compose up -d`", never a gluetun-only recreate. Health poll must tolerate a one-minute window. |
| 6 | End-to-end download | PASS | Creative Commons short film (129 MB) added through the API from the probe with `savepath=/media/_incoming/Movies`, finished in about 25 s at 5.6 MB/s through the tunnel while the host was itself on a VPN. Deleted with files through the API. | Tunnel inside a host tunnel works at full speed; no MTU tuning needed. Issue #30 becomes moot for torrent traffic. |

## Provisioning options

**A. Seed `qBittorrent.conf` before first start.** Write `WebUI\APIKey`,
`WebUI\Password_PBKDF2`, `Session\Interface`, `Session\InterfaceName`,
`Session\DefaultSavePath`, `AutoRun\...`, `Connection\UPnP=false` into the
config volume from an init step. Zero interaction, but ties us to the file
format and requires computing a PBKDF2 hash ourselves.

**B. One-shot init container after first boot.** Read the temporary password
from the qBittorrent log, log in once, `setPreferences`, `rotateAPIKey`,
`installPlugin`, write the returned key into the downloader's env. Uses only
the public API, but needs log scraping and a second restart so the downloader
picks up the key.

**Recommendation: A for the key and password, B's API calls for everything
else.** Seeding the key in the conf is what makes the stack start with a
known key on first boot; the rest is plain `setPreferences` from the setup
wizard (#23) and can be re-run idempotently.

## Settings carried from the host snapshot

| Setting | Host | Container |
|---|---|---|
| Network interface | `NordLynx` | `tun0` |
| Autorun program | `bin/notify-complete.bat "%I" "%N" "%F"` | `curl -s -X POST http://medialab-orchestrator:8000/api/v1/webhooks/torrent-complete -H "Content-Type: application/json" -d '{"hash":"%I","name":"%N","content_path":"%F"}'` plus the gateway `X-API-Key` header |
| Default save path | user Downloads | `/media/_incoming` (torrent-downloader still passes the path per add) |
| UPnP | on | off |
| Local service discovery | off | off (image default is on; set it off) |
| Queueing | off | off (image default is on) |
| Upload limit | set | carried over |
| Host header validation, CSRF | on | on, unchanged |

## Facts established from documentation

- gluetun reads a mounted `/gluetun/wireguard/wg0.conf` for providers that
  issue files. NordVPN does not; its native provider needs only the NordLynx
  private key (`WIREGUARD_PRIVATE_KEY`) and a server filter.
- API key auth needs qBittorrent >= 5.2 (web API >= 2.14.1). The current
  host runs 5.2.3; the lab image is 5.2.4.
- gluetun blocks egress to anything but the tunnel unless the subnet is in
  `FIREWALL_OUTBOUND_SUBNETS`. Compose service-name resolution kept working
  with gluetun's DNS in this setup.
- gluetun control server: `GET /v1/vpn/status`, `PUT /v1/vpn/status`,
  `GET /v1/publicip/ip`. Auth is mandatory; `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE`
  with an API key is enough.

## Lab-only gotchas

- Git Bash rewrites arguments that look like POSIX paths (`/media/...`)
  into `C:/Program Files/Git/media/...` before `docker exec` sees them. Set
  `MSYS_NO_PATHCONV=1` or run such commands from PowerShell. Not a
  qBittorrent or Docker behaviour.
- `current_network_interface` is the key to **set** the interface;
  `current_interface_name` is what you **read** back.

## Open after the lab

- PBKDF2 format for seeding `WebUI\Password_PBKDF2` (needed for option A
  if a known admin password is wanted; the API key alone suffices for the
  stack).
- Whether to drop the gateway webhook `X-API-Key` into the autorun command
  line (visible in qBittorrent preferences) or add a dedicated hook secret.
- Staging dir layout under `/media` and the `MEDIA_HOST_PATH` env rename in
  torrent-downloader, now that the save path is a container path.
