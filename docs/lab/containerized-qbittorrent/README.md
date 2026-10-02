# Lab: qBittorrent behind gluetun

Practice ground for [MickMarch/medialab#28](https://github.com/MickMarch/medialab/issues/28)
and the [containerized stack spec](../../specs/containerized-stack-vpn.md).
Standalone: own compose project, own network, own ports. It never touches the
medialab stack, the host qBittorrent, or `F:\Media`.

## Questions this lab answers

| # | Question | Script |
|---|---|---|
| 1 | Does qBittorrent's traffic leave via the tunnel, and does it stop dead when the tunnel drops? | `scripts/01-killswitch.sh` |
| 2 | Can a sibling container reach the qBittorrent API at `gluetun:8080` with a Bearer key, and what does `current_interface_name` report? | `scripts/02-api-from-probe.sh` |
| 3 | Can the completion hook reach another compose service by IP? By name? Are curl and Python present for it? | `scripts/03-hook-egress.sh` |
| 4 | Which `qBittorrent.conf` keys must the real compose pre-seed (API key, interface binding, autorun, paths, plugins)? | `scripts/04-provisioning.sh` |

Record outcomes in [FINDINGS.md](FINDINGS.md).

## Setup

1. `cp vpn.env.example secrets/vpn.env` and keep one provider block.
   - **NordVPN**: in your Nord account, NordVPN > Manual setup > generate an
     access token. Then fetch the NordLynx private key straight into the file
     (replace TOKEN; the token is single-use for this and can be revoked):

```bash
curl -s -u token:TOKEN https://api.nordvpn.com/v1/users/services/credentials | python -c "import json,sys; print('WIREGUARD_PRIVATE_KEY=' + json.load(sys.stdin)['nordlynx_private_key'])"
```

     Paste the output line over the empty `WIREGUARD_PRIVATE_KEY=` in
     `secrets/vpn.env`. This key is the same one the NordVPN app uses for
     NordLynx; it is not your account password and cannot touch billing.
   - **Providers that give a `.conf` file** (Mullvad, Proton, AirVPN, IVPN):
     save it as `secrets/wg0.conf`, set the provider block to `custom`, and
     start with the `compose.wgfile.yml` overlay. `Endpoint` must be an IP.
2. `cp .env.example .env`, set `GLUETUN_CONTROL_API_KEY` to any random string.
3. Start:

```bash
docker compose up -d
```

   or, with a `.conf` file:

```bash
docker compose -f compose.yml -f compose.wgfile.yml up -d
```

4. First boot only: read the temporary admin password from the log, then in
   the WebUI at http://127.0.0.1:8090 set a password, generate an API key
   (Preferences > WebUI > API Key) and paste it into `.env` as `QB_API_KEY`,
   and bind the network interface (Preferences > Advanced > Network interface)
   to the tunnel interface. Install one search plugin (View > Search Engine).
   Then `docker compose up -d` again so the probe picks up the key.

```bash
docker compose logs qbittorrent | grep -i password
```

5. Run the scripts from Git Bash in order.

## Teardown

```bash
docker compose down -v
```

`qbittorrent-config/` and `media/` persist on disk and are gitignored; delete
them by hand to reset first-boot state.
