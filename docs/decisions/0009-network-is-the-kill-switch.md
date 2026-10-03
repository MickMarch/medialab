# 0009 - The network is the kill-switch; the app check is the message

Date: 2026-10-03. Context: containerized qBittorrent behind gluetun
(`docs/specs/containerized-stack-vpn.md`, MickMarch/medialab#28).

## What happened

For a year the VPN guarantee was an application assertion: torrent-downloader
read qBittorrent's bound interface name and refused a download when it was
not on the allowlist. The guarantee held only as far as the host's routing
table did. With two VPN tunnels on the host, the one with the lower route
metric carried the traffic regardless of which adapter qBittorrent was bound
to (MickMarch/medialab#30), and a flapping host resolver broke container DNS
for minutes after every restart.

Moving qBittorrent and the downloader into gluetun's network namespace made
the property structural: with the tunnel down there is no route, so nothing
leaks because nothing can be sent. The lab proved it by stopping the tunnel
through gluetun's control server and watching egress fail outright. The
downloader's check stayed, because a refused request with `VPN_NOT_BOUND` is
a better experience than a stalled download, but it is no longer what keeps
the traffic inside the tunnel.

## Decision

- Enforce invariants at the layer that cannot be bypassed, and keep an
  application check only to produce a clear error.
- Anything that must not leave the home IP (torrent traffic, tracker lookups,
  details-page scraping, DNS for all of these) runs inside the VPN namespace.
  Services that have no business there (the gateway, the bot, the web UI,
  the Jellyfin worker) stay outside and address the namespace through the
  gluetun service name.
- Provider configuration is one env file. The tunnel interface name and the
  downloader's address are constants, so the rest of the stack never learns
  which provider is in use.

## Lessons from the cutover

- qBittorrent runs its autorun command without a shell. Quoted JSON in an
  inline `curl` arrives mangled; a script file beside the config is the
  reliable shape. A test harness that accepts any body (the lab's echo
  server) will not catch this; the real consumer has to be in the loop.
- A gluetun start can take over a minute while a provider rotates servers.
  Anything that waits on it needs its own patience, not compose's.
- Git Bash rewrites POSIX-looking arguments before native programs see them.
  Scripts that hand container paths to `python` or `docker exec` on Windows
  must set `MSYS_NO_PATHCONV=1`.
