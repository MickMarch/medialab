# API keys and secrets map

Every credential the medialab stack uses: what it is, where you get it, where
it is set today (host-installed qBittorrent + Jellyfin), and where it moves when
the stack is containerized (backlog item 20, `containerized-stack-vpn-spec.md`).

Keep this current whenever a key is added, moved, or a service is containerized.
No actual key values live here - only where each one comes from and goes. All
`.env` files are gitignored; never commit a real key.

---

## The keys

There are several distinct credentials. They are easy to confuse because
several are called "API key". They are NOT interchangeable.

### 1. TMDB API key (v3)

- **What:** read access to themoviedb.org for title/metadata search.
- **Get it:** create a free account at https://www.themoviedb.org, then
  Settings -> API -> request a v3 API key. It is a ~32-char hex string.
- **Who uses it:** `torrent-downloader` only (it is the sole TMDB-key holder;
  the orchestrator and bot resolve metadata *through* torrent-downloader, never
  directly).
- **Set today:** `torrent-downloader/.env` -> `TMDB_API_KEY=`.
- **After containerization:** unchanged location (still `torrent-downloader`'s
  env), now supplied via the container's `env_file`. The setup wizard
  (item 8) collects it with guided instructions.

### 2. qBittorrent Web UI credential (`QB_API_KEY`)

- **What:** authenticates torrent-downloader to qBittorrent's Web API. Sent as
  a bearer token. This is qBittorrent's own Web UI auth, NOT a tracker/search
  key.
- **Get it:** qBittorrent -> Tools -> Options -> Web UI. Enable the Web UI, set
  a username/password (or a bypass/token depending on your qB version). The
  value torrent-downloader sends is configured here.
- **Who uses it:** `torrent-downloader` (to add torrents, list transfers, stop
  seeding, check VPN binding).
- **Set today:** `torrent-downloader/.env` -> `QB_API_KEY=`, with
  `QB_HOST=127.0.0.1` / `QB_PORT=8080` (host-installed qBittorrent).
- **After containerization:** qBittorrent becomes a container (item 20). The
  credential still lives in torrent-downloader's env, but `QB_HOST` changes
  from `127.0.0.1` to the qBittorrent **compose service name** (routed through
  the gluetun VPN container's network namespace). The value itself is set in
  the qBittorrent container's config on first run.

### 3. Jackett API key (optional search backend)

- **What:** authenticates qBittorrent's `jackett.py` search plugin to a
  separately-installed **Jackett** application. Jackett is a meta-indexer that
  proxies many trackers and returns magnets. It is NOT a qBittorrent-internal
  plugin - it is its own app/service.
- **Get it:** Jackett must be installed and running first
  (https://github.com/Jackett/Jackett). Open its web UI at
  `http://127.0.0.1:9117`; the **API Key** field is at the top-right. Jackett
  auto-generates it - you do not create it. A running Jackett also needs
  tracker **indexers** added inside its own UI, or it returns nothing.
- **Who uses it:** qBittorrent's search plugin, at search time. torrent-downloader
  never sees this key directly - it just runs qBittorrent's search.
- **Set today:** `%LOCALAPPDATA%\qBittorrent\nova3\engines\jackett.json`:
  ```json
  {
      "api_key": "<key from :9117>",
      "thread_count": 20,
      "tracker_first": false,
      "url": "http://127.0.0.1:9117"
  }
  ```
  Replace the default `YOUR_API_KEY_HERE`. The `api key error!` search row with
  `seed=-1` means this is still the placeholder (or Jackett is not running).
- **Status (2026-07-17):** Jackett is NOT running on this host (`:9117`
  unreachable), so there is no key to set yet and the plugin errors. Either
  install+run Jackett, or rely on backlog item 23 Tier A (`.torrent` URL
  passthrough) to recover torlock results without Jackett.
- **After containerization:** if Jackett is containerized, its `jackett.json`
  lives in the qBittorrent container's config volume, and `url` becomes
  Jackett's compose service name instead of `127.0.0.1:9117`.

### 4. Inter-service `X-API-Key`s (one per service)

- **What:** each medialab service protects its API with a static key sent in
  the `X-API-Key` header. Distinct from all of the above - these are secrets
  *we* choose, not obtained from a third party.
- **The pairs (caller must match callee):**
  - bot -> orchestrator: bot's `ORCHESTRATOR_API_KEY` == orchestrator's `API_KEY`
  - orchestrator -> torrent-downloader: orchestrator's
    `TORRENT_DOWNLOADER_API_KEY` == torrent-downloader's `API_KEY`
  - orchestrator -> medialab-jellyfin: orchestrator's
    `MEDIALAB_JELLYFIN_API_KEY` == medialab-jellyfin's `API_KEY`
  - `scripts/notify_complete.py` (qB completion hook) -> orchestrator: its
    `ORCHESTRATOR_API_KEY` == orchestrator's `API_KEY`
- **Get it:** you generate them (any strong random string).
- **Set today / after containerization:** each service's own `.env`
  (`API_KEY=` on the callee side, `<SERVICE>_API_KEY=` on the caller side).
  These are hand-synced across the pair - the config-duplication chore
  ([[chore_config_layout]], owned by setup wizard item 8). Locations do not
  change under containerization, only how the `.env` files are delivered
  (per-service `env_file:` in compose).

### 5. VPN WireGuard config (not a key, but a secret file)

- **What:** the WireGuard tunnel config the VPN container (gluetun) uses.
  Post-containerization (item 20), the user supplies a **WireGuard config
  file**, never a VPN password ([[feedback_vpn_no_password]]).
- **Set:** gluetun's env/volume in compose. Collected by the setup wizard.
- **Today:** not applicable - VPN is the host's `NordLynx` interface, checked
  by torrent-downloader's `is_vpn_bound`. No file needed until item 20.

---

## Host-vs-container relocation summary

| Secret | Today (host apps) | After containerization (item 20) |
|---|---|---|
| TMDB key | `torrent-downloader/.env` | same env, via compose `env_file` |
| qB Web UI cred | `torrent-downloader/.env` + host qB | qB container config; `QB_HOST` -> service name via gluetun |
| Jackett key | `jackett.json` in host qB `nova3\engines` | qB container config volume; `url` -> service name |
| `X-API-Key` pairs | each service `.env` | same, delivered via compose `env_file` |
| WireGuard config | n/a (host NordLynx) | gluetun env/volume |

The setup wizard (backlog item 8) is the intended one-stop collector for
TMDB / qBittorrent / Jellyfin keys and the WireGuard file, writing each into
the correct per-service `.env`. Until it exists, keys are set by hand in the
locations above.
