# CLAUDE.md - medialab workspace root

This file provides context for Claude Code when opened at the `medialab/` workspace root.

Each subdirectory is an independent git repo. This root repo tracks only workspace-level docs.

---

## Architecture

```
medialab/
├── CLAUDE.md                     (this file - workspace context)
├── .gitmodules                   (submodule registry - source of truth for service versions)
├── .gitignore                    (blocks unregistered future service dirs)
├── torrent-downloader/           (submodule - independent git repo)
├── medialab-bot/                 (submodule - independent git repo)
├── medialab-jellyfin/            (submodule - independent git repo)
├── medialab-contracts/           (submodule - shared Pydantic models, v0.1.0)
└── medialab-orchestrator/        (future submodule - not yet created)
```

```
Discord user
    | slash command
medialab-bot (discord.py)
    | HTTP + X-API-Key
torrent-downloader (FastAPI) ---- qBittorrent + TMDB (host)

Future (front-door gateway - orchestrator owns the whole lifecycle):
Discord user
    | slash command
medialab-bot ----------------> medialab-orchestrator --+--> torrent-downloader -> qBittorrent + TMDB (host)
   (one dependency)                    | (gateway)      |
                                       |                +--> medialab-jellyfin   -> Jellyfin (host)
                                       |
qBittorrent (host, run-on-completion script)
    | webhook (torrent finished)      |
    v                                 v
scripts/notify_complete.py --> medialab-orchestrator (advances job: stop-seed, resolve TMDB,
                                rename TV folder, register path, trigger scan)

Bot talks ONLY to orchestrator. torrent-downloader + medialab-jellyfin become
downstream workers, never client-facing. Orchestrator owns a SQLite job table
spanning search -> download -> seed-stop -> rename -> register -> scan.
```

## Architecture style

Named honestly (portfolio vocabulary): **orchestrated microservices behind an
API gateway, with a persisted job state machine.** Concretely:

- **Service-per-capability** - each service wraps one external system
  (qBittorrent+TMDB, Jellyfin) or one client surface (Discord). Small-N (3-4),
  service-oriented rather than fine-grained micro.
- **API Gateway** - the orchestrator front-doors all bot traffic; downstream
  services are never client-facing.
- **Orchestration, not choreography** - a central coordinator drives the
  workflow through an explicit job state machine (SQLite). No event bus.
- **Event-triggered ingress at the tail** - the qBittorrent completion webhook
  is the one event edge; everything else is request/response.
- **Forward-retry saga** - the job table advances through idempotent steps and
  retries forward on failure (no compensation/rollback).

Deliberate restraint (the senior signal, stated so reviewers see intent):
SQLite over Postgres, in-process asyncio worker over Celery/Redis, no message
broker - each chosen as the lightest thing that fits single-host, low-volume
scale. The scale-up path (broker-backed choreography, Postgres, external
workers) is the documented "at 100x load" answer, not the MVP.

## Roadmap order

1. **medialab-jellyfin library endpoints** - scan trigger, add path, item search.
   COMPLETE. PR merged, library router live on main.
2. **torrent-downloader v1.1** - `media_type`-based save path resolution.
   COMPLETE. PR merged, `media_type` on `POST /download` plus
   `GET /transfers/{torrent_hash}/info` live on main.
3. **engineering-standards backfill** - bring existing services up to the
   "Engineering standards" section below. COMPLETE (2026-06-26). All three
   services merged ruff + mypy + pre-commit + dependabot + full CI gate
   (lint/format/typecheck/test/project-dep audit); medialab-bot gained its
   first CI workflow. CVEs surfaced by the audit cleared (bumped
   starlette/pydantic-settings/idna/aiohttp; diskcache CVE-2025-69872 ignored
   by ID pending a fix). Root pins bumped. PRs: torrent-downloader #4,
   medialab-bot #11, medialab-jellyfin #2.
4. **medialab-contracts package** - shared Pydantic models (`MediaType`, error
   shape, job/transfer DTOs). COMPLETE (2026-06-26). Repo + submodule live,
   released **v0.1.0**, root pinned. Ships `MediaType` enum, `ErrorResponse`,
   `CommonErrorCode` (six shared codes; services extend), `TransferInfo`,
   `TransferHashInfo` (optional `tmdb_id` for v1.2). Consumed as a tag-pinned
   uv git dependency (`[tool.uv.sources]` git + tag). Full design:
   `medialab-contracts-spec.md`. Service migration folds torrent-downloader's
   into v1.2; jellyfin + bot follow opportunistically.
5. **torrent-downloader v1.2** - thread `tmdb_id` through `POST /download`,
   cache `{media_type, host_path, tmdb_id}` vs hash, return `tmdb_id` from
   `GET /transfers/{hash}/info`. COMPLETE (2026-06-26), released **v1.2.0**,
   root pinned. `tmdb_id` required end to end (no backward-compat needed
   pre-release). Migrated onto `medialab-contracts` v0.2.0 (shared `MediaType`,
   `ErrorResponse`, `TransferInfo`, `TransferHashInfo`; `ErrorCode` bases its
   shared members on `CommonErrorCode`). Unblocks the orchestrator's canonical
   Title (Year) resolution.
6. **medialab-orchestrator MVP** - front-door orchestrating gateway, NOT a
   post-download relay. Bot talks only to the orchestrator; it brokers
   search/download/status and the post-download pipeline, fanning out to
   torrent-downloader + medialab-jellyfin (both become downstream workers).
   SQLite job table spanning the full lifecycle, in-process asyncio worker,
   qBittorrent completion webhook via a relay script, shared media-dir volume
   for TV folder renames, `GET /jobs` observability. Core value prop.
   Full design now lives in `medialab-orchestrator/CLAUDE.md` (the frozen-draft
   spec was folded in at build time and removed). Depends on item 5 (v1.2). This MVP also absorbs the medialab-bot tech-debt cleanup
   below (bot rewritten onto the single gateway dependency) and forces the root
   `docker-compose.yml` (shared network + media mount) to land now.
   **SERVICE COMPLETE (2026-06-26), released v0.1.0, submodule live + root
   pinned.** Repo + submodule created (public, branch-protected on the `quality`
   CI check, matching the other services). Ships the full gateway surface
   (search proxies, `POST /download`, `GET /transfers` read-through merge,
   `GET/POST /jobs*`, `GET /storage`, public aggregated health), the SQLite
   `pipeline_job` store, the forward-retry asyncio worker, the keyed
   `POST /webhooks/torrent-complete` + `scripts/notify_complete.py` relay, and
   the PTN-season-only TV rename. Standards from commit one; consumes
   `medialab-contracts` v0.2.0. Root `docker-compose.yml` + README landed.
   Implementation decisions resolved from the spec's open questions: webhook is
   keyed, DOWNLOADING is a read-through (no polling), PTN parses season only.
   **ITEM 6 COMPLETE: the medialab-bot rewrite onto the gateway also landed**
   (bot PR #15) - the bot now talks only to the orchestrator, dropped the
   torrent-downloader/jellyfin URLs+keys, save-path config, and the direct
   health check; `/torrent` removed, `/jobs` added, `tmdb_id`+`media_type`
   threaded through download. Root pin bumped. The first whole-project
   `docker compose build` + live verify is the user's next step.
7. **medialab-bot Dockerfile** - so all services are containerized per Deployment.
   COMPLETE (2026-06-26). Dockerfile + .dockerignore merged (bot PR #16),
   two-stage uv with git for the contracts git-ref dep, non-root, no EXPOSE
   (outbound-only client). Root pin bumped and the compose `medialab-bot`
   service enabled. All four services are now Docker images. Next: the user's
   first whole-project `docker compose build` + live verification.
8. **medialab-setup CLI wizard** (new tool, not a microservice) - one-time
   pre-deployment setup: collects TMDB/Jellyfin/qBittorrent API keys with
   guided instructions for obtaining each, creates/selects movie+TV
   directories, registers them as Jellyfin libraries, writes per-service
   `.env` files (each service keeps its own `.env`/`.env.example`, not a
   shared root `.env` - root compose references them via per-service
   `env_file:` paths), optionally runs `docker compose up`. Express mode
   (defaults) and custom mode (every config value editable). Lives in its
   own directory/repo, run locally before containers exist - not a
   long-running service.
9. **medialab-bot `/settings` cog** - runtime config viewing/editing via Discord
   slash commands (`/settings get`, `/settings set key value`), calling each
   service's settings endpoint (torrent-downloader already has
   `core/settings_manager.py` - check its current surface before designing this).
   Bot reports whether a changed setting hot-reloads or requires a container
   restart. No separate GUI - Discord is the existing user-facing surface.

Items 8-9 are fast-follows after the MVP (1-7); do not block the MVP on them.

### Backlog (added 2026-06-29, unordered - sized but not yet sequenced)

10. **Stuck / failed download remediation.** Detect and recover downloads that
    stall, error, or go corrupt in qBittorrent (stalled, missing files, metadata
    timeout, error state). torrent-downloader already exposes per-transfer
    `state` via `GET /transfers`; the orchestrator should surface unhealthy
    transfers (a new job signal or a derived `STALLED`/`ERRORED` view) and offer
    a remedy - re-announce, recheck, re-add, or cancel-and-cleanup - via a bot
    command. Touches the orchestrator job state machine + a bot surface. Decide:
    a new job status vs. a derived health flag joined onto the live read.
    Medium.
11. **Full Jellyfin naming convention.** The orchestrator's RENAME step already
    does TV `Series Name (Year)/Season NN/`. Extend to Jellyfin's complete spec
    for both libraries so Jellyfin's own tooling (metadata match, versions,
    editions) works cleanly. Movies:
    `Movie (Year)/Movie (Year) [tags].ext` (see
    https://jellyfin.org/docs/general/server/media/movies). Shows: episode-level
    naming `Series (Year)/Season NN/Series SNNEMM.ext` and specials handling
    (see https://jellyfin.org/docs/general/server/media/shows). Currently movies
    get no rename and TV stops at the season-folder level. Refines the existing
    `services/rename.py`; PTN already parses episode/season. Small-medium.
12. **RSS watchlist + auto-download.** A user adds a show or movie to a watchlist;
    the app monitors RSS feeds for matching releases and auto-downloads the first
    that meets a target resolution (and other filters). Biggest item - needs a
    persistent watchlist store, a periodic feed-poll loop, release-name matching
    (PTN + the TMDB id already threaded), and an auto-submit into the existing
    download pipeline. Likely its own subsystem or service rather than bolted
    onto the gateway; the orchestrator's in-process asyncio worker is a natural
    host for the poll loop, but the watchlist is new persisted state. Per-show
    resolution/quality filters tie into the settings store (item 9). Large;
    spec-first, sequence after the remediation + naming items.
13. **`/stop-seeding` bot command.** Surface torrent-downloader's existing
    `POST /transfers/stop-seeding` through the gateway and a bot command. That
    endpoint already stops only *seeding* (i.e. completed) torrents and never
    touches in-progress downloads, so the "completed only" requirement is the
    current behaviour - this is mostly wiring: gateway passthrough + a
    `/stop-seeding` cog command. Small.
14. **Storage-threshold warning.** Before confirming a download, warn the user if
    it would push disk usage past a user-set threshold. torrent-downloader
    already exposes `GET /storage`; the gateway compares projected size against
    the threshold and the bot surfaces the warning at the confirm step. The
    threshold is a user-adjustable setting, so this depends on the settings
    surface (item 9). Small-medium.
15. **Rename `torrent-downloader` -> `medialab-downloader`.** Align the naming
    with the rest of the suite. Wide but mechanical blast radius: GitHub repo
    rename, the Python package (`torrent_downloader` -> `medialab_downloader`),
    the submodule path + `.gitmodules` URL, the image name in
    `docker-compose.yml`, every consumer's downstream URL/service-name
    (orchestrator + the compose network), the contracts/CLAUDE references, and
    the memory notes. Do it as a single focused chore with all consumers updated
    in lockstep (the orchestrator targets it by compose service name, so the
    service rename and the orchestrator `.env`/compose update must land
    together). Note: keeping the historical "torrent-downloader" name is also
    defensible (it names what the service *does*); the rename is cosmetic
    alignment, low priority. Mechanical, medium blast radius.

16. **Wire the qBittorrent completion webhook (job pipeline advance).** The
    orchestrator's post-download pipeline (STOP_SEEDING -> RESOLVE_META -> RENAME
    -> REGISTER -> SCAN -> DONE) only advances when qBittorrent runs
    `scripts/notify_complete.py` on torrent completion, POSTing to
    `/webhooks/torrent-complete`. That hook is not configured, so every job sits
    at `DOWNLOAD_SUBMITTED` forever even after the download finishes (observed
    live via `/jobs`). The relay script and endpoint already exist - this is
    deployment wiring: configure qBittorrent's "Run external program on torrent
    completion" to invoke the relay with `%I`/`%N` and the orchestrator URL+key,
    inside the container topology. Decide the relay's runtime home (qBittorrent
    runs on the host, the script needs network to the gateway). This is the
    automation keystone - without it the pipeline never runs end to end. A poll
    fallback (orchestrator polls `/transfers`, advances on completion) is the
    documented alternative if the host hook is impractical; the spec chose
    webhook-over-poll but a poll is the pragmatic homelab option. Medium; high
    priority (unblocks the whole post-download flow).
17. **Show torrent download size in the picker.** The bot's resolution picker
    shows seeder count but not size. torrent-downloader's torrent search already
    returns `fileSize`; the bot's `TorrentResult` already carries `file_size`.
    Just surface it (human-readable GB/MB) in the Select option description next
    to seeders, so the user weighs size vs. seeders when choosing. Bot-only,
    ~no new data. Small; quick win.

18. **Uptime / autostart the whole stack.** Maximize availability so the remote
    Discord control surface is always reachable. Two layers: (a) **containers** -
    the compose services already declare `restart: unless-stopped` (survive
    crashes and Docker-daemon restarts), but the Docker runtime itself must
    launch on host boot (Docker Desktop "start on login", or a boot-managed
    engine); document/configure it. (b) **host apps** - qBittorrent and Jellyfin
    run on the host, not in containers, so their autostart is a host concern
    (Windows startup / Task Scheduler / run-as-service). This overlaps the
    orchestrator spec's deferred "Jellyfin host availability" note (power-on /
    WoL / smart-plug when the host is asleep) - fold that in here. Define what
    "the stack is up" means and make each layer self-start. Mostly
    config + docs + a host-app autostart recipe; the WoL/wake piece is larger if
    pursued. Medium; do alongside or just after the webhook (16), since an
    always-on pipeline needs an always-on stack.

19. **TV season/episode targeting in torrent search.** The show download flow
    searches torrents by show title only, buckets by resolution, sorts by
    seeders - so the latest season's packs (highest seeders) bury older seasons
    and individual episodes are unreachable. Add season/episode targeting: the
    bot reads the real season list from the existing TMDB show-detail endpoint
    and presents a scope picker (whole series / a season / a single episode);
    torrent-downloader refines the qBittorrent search `pattern` with an
    `S0NE0M` tag and strictly drops PTN-parsed results that do not match the
    requested season (complete-series and multi-season range packs kept as
    labeled fallbacks so the set is never empty). `media_type` becomes a
    required query param on `GET /search/torrents`. Spans four repos:
    `medialab-contracts` (v0.3.0 - new `TorrentSearchScope` model), then
    torrent-downloader (v1.3 - params + `filter_by_scope` + scope-aware cache
    key), orchestrator (v0.2.0 - pass params through the proxy, no job-table
    change), bot (v1.1.0 - the new scope-picker UI state for shows). Full design:
    `tv-season-targeting-spec.md`. Decisions locked (granularity = season +
    episode, season list from TMDB detail, strict drop-non-matching). Medium;
    high user value - this is a real correctness gap in the core download path.
    **COMPLETE (2026-07-02).** Shipped across all four repos: contracts v0.3.0
    (`TorrentSearchScope`), torrent-downloader v1.3.0 (params + `filter_by_scope`
    + scope-aware cache key + category from media_type), orchestrator v0.3.0
    (proxy passthrough), bot v2.1.0 (`views/scope.py` season/episode pickers +
    `run_torrent_search` helper). Root pins bumped. First live test (2026-07-17)
    caught a cross-service path bug: torrent-downloader's TV detail route was
    `/tmdb/tv/` while the orchestrator builds `/tmdb/show/` from
    `MediaType.SHOW.value`, 404ing every show-detail call - the bot silently
    fell back to whole-series search, hiding the scope picker. Fixed in
    torrent-downloader v1.3.1 (route renamed to `/tmdb/show/`), verified
    through the gateway (season list returns). Scope-picker UI still awaits a
    live Discord pass. Lesson: mock-boundary tests never exercise cross-service
    path contracts - each side's suite passed while the pair was broken.

20. **Fully containerized, self-hostable stack.** Today the suite assumes
    host-installed qBittorrent + Jellyfin reached over `host.docker.internal`,
    with VPN enforcement bound to the host's `NordLynx` interface. Containerize
    the four medialab services + qBittorrent + a gluetun VPN container so the
    stack - minus the media directories - comes up from compose alone. This is
    the path to a real prod/staging/dev environment model (base compose +
    overlays, see "Environments") and to letting others self-host without a
    bespoke host setup. **Full design + locked decisions:
    `containerized-stack-vpn-spec.md` (reviewed DRAFT).** Key decisions:
    (1) containerize services + qBittorrent + gluetun; **Jellyfin stays EXTERNAL**
    (native or the user's own container) reached by URL - the app never owns its
    lifecycle (native GPU transcoding on Windows is easy, containerized is not).
    (2) **VPN is a hard, non-bypassable invariant** - no torrent traffic
    (download or seed) without a bound VPN, no dev exception. gluetun holds a
    WireGuard tunnel; qBittorrent routes through it; gluetun's firewall is the
    automatic leak-proof kill-switch. (3) **User supplies a WireGuard config
    file, never a VPN password** (comfort + safety). (4) torrent-downloader's
    hardcoded `NordLynx` check becomes configurable (never relaxable). (5) seed
    stops N minutes after 100% (configurable, default 0). Overlaps item 8 (setup
    wizard collects the WireGuard file + keys) and item 18 (autostart/uptime).
    Spec-first; medium-large; 4 open questions remain in the spec. A dev/staging
    environment model folds into this item (see "Environments" - deferred for a
    solo user for now).

21. **Re-add `/torrent` (custom torrent search, no TMDB).** Bring back a bot
    command that searches torrents by raw query, completely skipping TMDB -
    for content TMDB does not know or where the user knows the exact release
    name. Removed in the item-6 rewrite because the gateway's `POST /download`
    requires `tmdb_id` + `media_type` and the pipeline's RESOLVE_META/RENAME
    steps depend on a TMDB identity for the canonical `Title (Year)` naming.
    That is the design problem to solve before code: a TMDB-less job breaks
    the current job model. Options to weigh in the spec: (a) nullable
    `tmdb_id` on the job + a degraded pipeline that skips RESOLVE_META and
    falls back to a PTN-parsed rename (or no rename), flagged so the user
    knows Jellyfin matching may be worse; (b) a distinct job kind
    (`manual` vs `tmdb`) with its own step sequence; (c) an optional
    after-the-fact TMDB match step (search TMDB with the PTN-parsed
    title/year, attach if confident, else leave manual). Touches contracts
    (job/transfer DTOs currently require `tmdb_id`), torrent-downloader
    (cache entry requires `tmdb_id`), orchestrator (job table + pipeline
    branching), bot (new command + picker reuse). `media_type` still required
    (user picks movie/show in the command). Motivating edge case (2026-07-17):
    TMDB titles are sometimes unusable as torrent queries - the 2026 "The
    Mummy" is titled "Lee Cronin's The Mummy" on TMDB, which returns zero
    torrent hits; a manual query is the escape hatch. Spec-first; medium.

22. **Torrent search pattern: year as bare number.** The torrent search
    pattern built after `/search` must use `Title YYYY` ("Calvary 2014"),
    never `Title (YYYY)` - parenthesized years poison release-name matching.
    Verified 2026-07-13: `run_torrent_search` already builds
    `f"{title} {year}"` (bot `views/torrent.py`), parentheses appear only in
    Discord display strings, so current behavior is correct. Keep as a guard:
    when touching the search-pattern path (items 19 follow-ups, 21), preserve
    the bare-year form; consider a regression test asserting the pattern
    contains no parentheses. Tiny.

23. **Per-plugin `fileUrl` handling (magnet / .torrent URL / details page).**
    **COMPLETE (2026-07-20), verified live.** All three tiers shipped:
    downloader v1.4.0 (Tier A: `.torrent` URL passthrough + snapshot-diff hash
    readback + `source_url` rename), orchestrator v0.4.0 (surrogate `job_id` PK
    + nullable backfilled `torrent_hash` + hash stamping), bot v2.2.0
    (`source_url` + job-id addressing), downloader v1.5.0 (Tier B: HTML
    details-page magnet scraping via `services/source.py`). Tier C (resolution
    `Other` bucket) was already v1.3.3. Root pins bumped, stack rebuilt, DB
    volume recreated for the schema change. **Live finding: Tier B was the
    load-bearing tier, not Tier A.** For real shows (Rick and Morty S8) every
    seeded result is a limetorrents HTML page; the torlock `.torrent` results
    Tier A recovers are near-zero-seed. Picker went from empty to 3 seeded
    results (123/111/37 seeders) after Tier B; a real S8 page scrapes a valid
    magnet. Original diagnosis retained below.

    The core correctness bug behind "shows return nothing": the search
    pipeline assumes every qBittorrent search plugin returns a magnet in
    `fileUrl`, but the plugins return three different shapes, and
    `filter_and_sort_results` drops anything that is not `magnet:?`. Observed
    live (2026-07-17):

    | Engine | `fileUrl` shape | Handling needed |
    |---|---|---|
    | piratebay | `magnet:?xt=...` | none - works today |
    | torlock | `.torrent` file URL (`/tor/NNN.torrent`, `application/x-bittorrent`) | pass URL straight to `torrents_add(urls=...)` - qBittorrent fetches it |
    | limetorrents | HTML details page | fetch page + scrape `magnet:?xt=urn:btih:...` (confirmed present) |

    (A jackett plugin row also appeared as an error - Jackett is a separate app
    not running on this host; it is deliberately NOT part of this item and not
    on the backlog. Ignore its rows.)

    Popular movies work because piratebay indexes them (magnets); older/niche
    TV (e.g. The Simpsons S23) returns only torlock+limetorrents, 100% of which
    the magnet-only filter discards - empty picker despite ~24 raw hits.

    Three independent tiers, each shippable alone, sequence by value/risk:
    - **Tier A - `.torrent` URL passthrough** (biggest win, lowest risk). Stop
      dropping `fileUrl`s that are `.torrent` links; pass them to
      `torrents_add`. Recovers torlock. Alone this unblocks the Simpsons case.
    - **Tier B - details-page scrape** (fragile). For an HTML `fileUrl`, fetch
      the page (behind the VPN, inside torrent-downloader) and regex the
      magnet. Recovers limetorrents. Generic `magnet:?xt=` scrape covers both
      scraper sites; no per-site parser needed so far.
    - **Tier C - resolution-`Other` bucket.** DONE (torrent-downloader v1.3.3):
      untagged/SD results no longer dropped by `group_by_resolution`. This
      alone was necessary but not sufficient - the magnet filter upstream still
      dropped everything for the TV case.

    **The real design work is hash caching, not the add itself.** Today
    `POST /download` extracts the BTIH hash from the input magnet to cache
    `{media_type, host_path, tmdb_id}` against it (the orchestrator looks it up
    at completion). A `.torrent` URL or scraped page does not carry the hash up
    front, so caching must move to *after* the add - read the hash back from
    qBittorrent (`torrents_add` does not return it; look it up by the just-added
    torrent) and cache then. This is the crux and why it is spec-first, not an
    inline patch. Likely threads `engineName`/url-kind through search results so
    the download side knows how to handle the chosen `fileUrl`. Spans
    contracts (download DTO field for the URL kind), torrent-downloader
    (filter + add + post-add hash cache), possibly the gateway/bot if the
    picker must carry the kind. Medium; high value - this is the true root
    cause of the show-download gap, of which items 19's route/pattern fixes
    and Tier C were only the surface. Spec-first. **Spec drafted
    (`item-23-plugin-fileurl-spec.md`), decisions locked:** surrogate `job_id`
    PK with a nullable backfilled `torrent_hash` (decouples job identity from
    the torrent source), and `magnet_uri` -> `source_url` (accepts magnet or
    `.torrent` URL). That spec covers Tier A + the keying change only; Tier B
    (page scrape) stays backlog. Awaiting approval before code.

### Backlog ordering (agreed 2026-06-29)

The backlog items above are numbered by when they were raised, not by priority.
Execution order:

1. **16 - wire the qBittorrent completion webhook.** Do next, immediately. Not a
   feature - the post-download pipeline never runs end to end without it, so the
   whole orchestration value is untested live. Treat as a blocker.
2. **18 - uptime / autostart.** Pair with 16: an always-on pipeline needs an
   always-on stack (containers on boot + host apps up).
3. **17 - show torrent size**, then **13 - `/stop-seeding` command.** Two small,
   isolated quick wins to clear after the keystone. Note 17 edits the same bot
   torrent-picker Select that 19 reworks - if 19 is in flight, fold 17's
   size-in-description into 19's picker pass rather than doing it twice.
4. **Reliability: 19 - TV season/episode targeting**, then **11 - full Jellyfin
   naming**, then **10 - stuck/failed remediation.** Make the core download +
   organize loop correct and robust before adding features. (19 fixes which
   torrent the user can even get; 11 refines the post-download rename; 10
   hardens it.) 19 spans four repos (contracts -> downloader -> orchestrator
   -> bot) and is the largest of the three; sequence it first because a wrong
   download makes the downstream naming/remediation moot.
5. **Setup polish: 9 - `/settings` cog**, then **14 - storage-threshold
   warning** (14 depends on 9's settings store), then **8 - medialab-setup
   wizard.** Build 8 before sharing the project / portfolio use - it owns the
   config-duplication chore ([[chore_config_layout]]) and makes the suite
   installable by others. Not urgent for personal use (working `.env` files
   already exist).
6. **12 - RSS watchlist + auto-download.** The marquee feature and the largest;
   the last big push. Wants 9's settings store for per-show quality filters.
7. **15 - rename torrent-downloader -> medialab-downloader.** Cosmetic alignment,
   lowest priority; do when quiet (or not at all - the historical name is
   defensible).

Soft prerequisites: item 9 (settings store) precedes 14 and 12's per-show
filters. Otherwise items are independent and the order is preference, not
hard dependency.

Added 2026-07-13, not yet sequenced: **21 - `/torrent` re-add** (spec-first,
job-model question; natural slot is after the reliability block, since it
branches the pipeline that 10/11 harden) and **22 - bare-year search pattern**
(verify-only guard, fold into whichever item next touches the search-pattern
path).

Added 2026-07-17: **23 - per-plugin `fileUrl` handling** jumps near the front
of the reliability block, alongside/just after item 19 - it is the true root
cause of the show-download gap (item 19's route + pattern fixes and the
resolution-`Other` bucket were only the surface; the magnet-only filter still
drops all torlock/limetorrents TV results). Do Tier A (`.torrent` URL
passthrough) as the immediate high-value slice - it unblocks TV downloads for
the common case with the lowest risk.

## Session start - check submodule state

Run this at the start of every session to see which services have changed since last pinned:

```bash
git submodule status
```

Output format: `[+]<sha> <path> (<tag or branch>)`

- No prefix - submodule matches pinned SHA, no changes since last session
- `+` prefix - service has new commits, context in that service's CLAUDE.md may be stale; read it before working on that service
- `-` prefix - submodule not initialized, run `git submodule update --init`

To update the root repo's pin to a service's latest commit:

```bash
git submodule update --remote torrent-downloader
git add torrent-downloader
git commit -m "chore: update torrent-downloader submodule pin"
```

## Services

### torrent-downloader (v1.1 - complete)

FastAPI REST API. GitHub: https://github.com/MickMarch/torrent-downloader

Endpoints:
- `GET /api/v1/health` - public, no auth
- `GET /api/v1/search/tmdb` - TMDB multi-search
- `GET /api/v1/search/tmdb/movie/{tmdb_id}` - movie detail
- `GET /api/v1/search/tmdb/show/{tmdb_id}` - show detail
- `GET /api/v1/search/torrents` - qBittorrent plugin search, grouped by
  resolution. `media_type` required (selects the plugin category); shows accept
  optional `season`/`episode` that refine the search pattern (`S0N`/`S0NE0M`) and
  strictly filter results to the requested season (range/complete-series packs
  kept as fallbacks). v1.3.
- `POST /api/v1/download` - submit magnet URI (VPN enforced); accepts `media_type`
  (movie|show) and resolves the save path itself under `MEDIA_HOST_PATH`, no
  genre subfolders, caches `media_type`/`host_path` against the torrent hash
- `GET /api/v1/transfers` - active transfers
- `GET /api/v1/transfers/{torrent_hash}/info` - cached `media_type` and
  `host_path` for a hash, looked up by the orchestrator at completion time
- `POST /api/v1/transfers/stop-seeding` - stop seeding completed transfers
- `GET /api/v1/storage` - disk usage
- `DELETE /api/v1/cache` - evict cache

Auth: `X-API-Key` header on all endpoints except `/health`.
Error shape: `{"status": "error", "code": "<ErrorCode>", "detail": "..."}`.
Rate limits: 60 req/min general, 20 req/min search. 429 includes `Retry-After` header.
Request tracing: every response includes `X-Request-ID` UUID header.

v1.2 roadmap (not yet built):
- `GET /api/v1/search/trending?type=movie|show&window=day|week`
- `GET /api/v1/search/similar?tmdb_id=123&type=movie|show`

### medialab-bot (v1.0.0 shipped; rewired onto the gateway)

Discord bot. Tech stack: `discord.py`, `uv`, `hatchling + hatch-vcs`,
`pydantic-settings`, `medialab-contracts`. Full design in
`medialab-bot/CLAUDE.md`.

**Talks only to the medialab-orchestrator gateway** (one URL + one key, no
placement config) since the item-6 rewrite (bot PR #15). Live slash commands:
- `/search query` - TMDB search via the gateway; the **sole download path**. The
  picked `tmdb_id` + `media_type` thread through the torrent-resolution pick into
  `POST /download` (the gateway requires both and does no title guessing).
- `/transfers` - live transfers merged with pipeline job rows
- `/storage` - disk usage
- `/jobs [status]` - pipeline lifecycle view with a retry control for failed jobs

`/torrent` was removed (could not supply `tmdb_id`+`media_type`). `/trending` +
`/similar` stay deferred until the gateway proxies torrent-downloader's TMDB
roadmap. State lives in Discord message components - no server-side session.

Containerized (item 7 complete): Dockerfile + .dockerignore mirror the other
services' two-stage uv install (git in the build stage for the contracts git-ref
dep, non-root user, hatch-vcs `APP_VERSION` build arg, no `EXPOSE`). Enabled in
the root `docker-compose.yml`.

Tech debt in this service to resolve when orchestrator is built - see
"medialab-bot tech debt" under medialab-orchestrator below.

### medialab-jellyfin (v1 - complete)

FastAPI REST API wrapping the Jellyfin media server API. GitHub:
https://github.com/MickMarch/medialab-jellyfin (private)

Endpoints:
- `GET /api/v1/health` - public, no auth, reports Jellyfin reachability
- `POST /api/v1/library/scan` - trigger Jellyfin library scan (`POST /Library/Media/Updated`)
- `POST /api/v1/library/paths` - add local directory to a Jellyfin library; resolves
  target library dynamically via `GET /Library/VirtualFolders` filtered by CollectionType
  (no env-var config); optional `library_name` override for ambiguous multi-library setups
- `GET /api/v1/library/items` - search library contents (`GET /Items`)

Same conventions as torrent-downloader: `X-API-Key` auth, structured error
shape, rate limiting, `X-Request-ID` tracing, `hatch-vcs` versioning.

Stays a thin proxy - assumes Jellyfin already reachable. No power-management
or workflow logic here; that belongs to the orchestrator.

### medialab-orchestrator (v0.1.0 - complete)

Front-door orchestrating gateway. GitHub:
https://github.com/MickMarch/medialab-orchestrator (public, branch-protected).

> **Source of truth is `medialab-orchestrator/CLAUDE.md`.** The full design
> (gateway surface, SQLite `pipeline_job` lifecycle, idempotency rules, the
> resolved implementation decisions) lives there; the frozen-draft spec was
> folded in at build time and the standalone spec file removed. The orchestrator
> is a **front-door orchestrating gateway** - the bot talks only to it; it fronts
> the whole lifecycle and owns the job table - not the post-download-only relay
> the historical notes below describe. The notes below are retained only for the
> TV-folder-naming and Jellyfin-availability detail; the service CLAUDE.md wins
> where they conflict.

Add when event-driven cross-service workflows are needed. Owns:

1. **Download-complete handling.** qBittorrent supports "Run external program
   on torrent completion" (a script invoked once per finished torrent, no
   polling). That script calls a webhook on the orchestrator
   (e.g. `POST /webhooks/torrent-complete` with hash/name from `%I`/`%N`).
   On receipt, orchestrator:
   - calls torrent-downloader `POST /api/v1/transfers/stop-seeding`
   - calls torrent-downloader `GET /api/v1/transfers/{hash}/info` to
     get `media_type` and `host_path`
   - for TV: renames/restructures the downloaded folder into Jellyfin's
     required convention (`Series Name (Year)/Season NN/`) before any
     Jellyfin call - see "TV folder naming" below. Movies need no rename
     (Jellyfin matches movie folders more loosely).
   - calls medialab-jellyfin `POST /library/paths` (movies/TV root only
     needs registering once at setup time, not per-download, since Jellyfin
     recursively scans an already-registered root) and `POST /library/scan`
     with the renamed path
2. **TV folder naming.** Jellyfin's TV library requires exact convention:
   `Series Name (Year)/Season NN/` (season zero-padded, never abbreviated
   to `S01`). Torrent release names almost never match this
   (`Show.Name.S01.1080p.GROUP/...`). Orchestrator must parse the release
   name (PTN, already a torrent-downloader dependency) and move/rename
   files into the correct structure before triggering a Jellyfin scan.
   Movies are more forgiving of folder naming and likely need no rename step.
3. **Jellyfin host availability.** Power-on Jellyfin host when down
   (mechanism TBD - WoL / smart plug / SSH, depends on host setup). Runs
   before any medialab-jellyfin call if the host might be asleep.

Orchestrator owns preconditions (is the dependency reachable/awake) and
multi-service state; the wrapper services (torrent-downloader,
medialab-jellyfin) stay stateless proxies assuming their dependency is up.

**medialab-bot tech debt to fold into this work:**

- `AppConfig.torrent_save_path` and `AppConfig.tmp_docker_save_path`
  (`medialab-bot/src/medialab_bot/config.py`) are passed by the bot into
  `download()` and `get_storage()`
  (`client/_torrents.py`, `client/_status.py`). Save-path policy is a
  workflow/placement concern, not something the Discord UI layer should own.
  Resolved by torrent-downloader's v1.1 `media_type`-based path resolution
  (see torrent-downloader roadmap above) - bot passes `media_type` instead of
  a path, and these config fields are removed from medialab-bot.
- `medialab-bot/src/medialab_bot/main.py` checks torrent-downloader's
  `/health` (incl. VPN binding) at startup and logs warnings. Once orchestrator
  exists, consider whether cross-service health aggregation (torrent-downloader
  + medialab-jellyfin + Jellyfin/qBittorrent reachability) belongs there
  instead, surfaced to the bot via a single orchestrator health check.

## Shared conventions

- Language: Python 3.12+
- Package manager: `uv` (not pip, not poetry)
- Build backend: `hatchling` + `hatch-vcs` (version from git tags, never hardcoded)
- Settings: `pydantic-settings` loading from `.env`
- Tests: `pytest` style only, run via `uv run pytest`
- Commits: Conventional Commits (`feat`, `fix`, `chore`, etc.)
- Workflow: spec approval → failing tests → implementation (never skip to code)
- No hardcoded secrets - `.env` for local dev, gitignored always
- No em dash character anywhere
- No "Claude Code" or AI attribution in commit messages or code comments
  (exception: CLAUDE.md files and .claude/ directories)

## Engineering standards

Workspace-wide standards every service inherits. New services adopt all of
these from their first commit; existing services backfill (see roadmap item
"engineering-standards backfill").

### Linting & formatting
- **Ruff** is the single linter + formatter (`uv run ruff check`,
  `uv run ruff format`). Config lives in each service's `pyproject.toml` under
  `[tool.ruff]`, kept identical across services. Baseline rule set: `E`, `F`,
  `I` (import sort), `UP` (pyupgrade), `B` (bugbear), `SIM` (simplify),
  `PLR2004` (magic value used in comparison). The magic-number/-string ban is
  enforced as the `PLR2004` lint rule, not left to review judgment - use named
  constants/enums/config instead.
- No separate `black`/`isort`/`flake8` - ruff replaces all three.

### Static typing
- Full type hints required (the code already has them). `mypy` (or `pyright`)
  runs in CI as a gate. Config in `pyproject.toml`.

### Pre-commit
- `.pre-commit-config.yaml` in every service: ruff (check + format),
  trailing-whitespace, end-of-file-fixer, yaml/toml checks. Local gate before
  a commit reaches CI. (The em-dash prohibition is an assistant authoring rule,
  not a pre-commit gate - do not add a hook for it.)

### CI (GitHub Actions)
- Every service has `.github/workflows/ci.yml` running, in order:
  `ruff check` -> `ruff format --check` -> `mypy` -> `uv run pytest`
  (with coverage). Tests-only CI is insufficient - lint + typecheck are gates.
- **medialab-bot currently has no workflow** - add one (backfill).
- Coverage reported; a floor is enforced once each service's suite is mature
  (target documented per service, not a blanket number).
- **Dependabot** (`.github/dependabot.yml`) for `uv`/pip + GitHub Actions
  updates. **`pip-audit`** step in CI for dependency CVEs - audit the resolved
  project deps (`uv export ... | pip-audit -r`), not a bare `uvx pip-audit`
  (which audits only the isolated tool env and finds nothing useful).
  Unfixable CVEs are ignored by explicit ID with a comment, not by dropping the
  gate.

### Changelog
- Keep a Changelog format (https://keepachangelog.com): `Unreleased` section
  at top, grouped `Added`/`Changed`/`Fixed`/`Removed`, moved under a dated
  `vX.Y.Z` heading at release time. All three current services already have a
  `CHANGELOG.md` - enforce the format.

### DRY with judgment
- Extract a shared abstraction on the **third** real repetition, not the
  second, and never abstract across **domain** boundaries purely to dedupe
  (a coincidental code match in two services is not shared logic). Genuinely
  shared cross-service contracts live in `medialab-contracts` (see below), not
  copy-paste and not a forced base class. Prefer a little duplication over the
  wrong abstraction.

### Tests must run without `.env` (CI isolation)

CI runs on GitHub Actions with **no `.env` file and no real secrets**. Tests
that depend on real config or live external services fail there as false
negatives. Mitigation (already the pattern in medialab-jellyfin /
torrent-downloader - keep it uniform):

1. **Config defaults everywhere.** Every `pydantic-settings` field has a
   default (`None` for secrets, sensible literals otherwise) so the app
   imports cleanly with no `.env` present. Fields are "optional at import time,
   required at runtime" - never make a field mandatory at import or CI import
   fails before a test even runs.
2. **Unit tests never read real config.** `conftest.py` uses `autouse=True`
   fixtures to patch the config object (e.g. mock `core.auth.config` with a
   `TEST_API_KEY` constant). Tests assert against the injected test value, not
   a real key.
3. **External dependencies are mocked.** No unit test makes a real network call
   (qBittorrent, TMDB, Jellyfin, Discord, the downstream services). Mock at the
   client-class boundary (see the Discord-mocking convention), not at
   `httpx` internals, except in the dedicated client test module.
4. **Live-credential tests are marked and skipped.** Anything that genuinely
   needs real secrets or a live service is marked
   `@pytest.mark.integration` and skipped in CI (run only locally with a real
   `.env`). CI runs the default (non-integration) suite. Register the
   `integration` marker in `pyproject.toml` so it is not an unknown-marker
   warning.

Net rule: a fresh checkout with zero `.env` and no network must pass
`uv run pytest` green. If a test needs a secret or a live endpoint to pass,
it is either mis-scoped (mock it) or an integration test (mark + skip).

### Shared contracts (`medialab-contracts`)
- A small versioned package of Pydantic models shared across services
  (`MediaType`, the structured error shape, job/transfer DTOs, common enums).
  Single source of truth - editing a shared field happens once, not in three
  schemas. Each service depends on a pinned version; bumping it is a
  deliberate, reviewable step. Prevents schema drift as the surface grows.
  Lives in its own repo/submodule like the services.

## Git workflow

Each service is an independent repo with its own tags and releases.
Version tags: `vX.Y.Z` annotated tags pushed to GitHub, GitHub Release created from tag.
Branch strategy: feature branches off main, PR to merge.

### Versioning: never predict a version number

Each service versions independently on its own semver line - there is no shared
counter and no central version manifest (that would be a second source of truth
that drifts from the tags). The **git tag is the single source of truth** for a
service's version; `hatch-vcs` derives everything from it, so nothing is
hardcoded.

Because of that, do NOT write a predicted version into the roadmap, a spec, a
branch name, or a PR title. Reference work by **item number + feature name**
("item 19: TV season targeting"), not "bot v1.1.0". The concrete version is
chosen only **at release time**, from the actual last tag plus the change kind
(Keep-a-Changelog: `Added`/`Changed` -> minor, `Fixed` -> patch, breaking ->
major). Predicting a version before the tag exists is what caused the item-19
drift (orchestrator was guessed v0.2.0 but that tag existed, so it shipped
v0.3.0; bot was guessed v1.1.0 but was already at v2.0.0, so it shipped v2.1.0).

## Deployment

All microservices (torrent-downloader, medialab-bot, medialab-jellyfin,
medialab-orchestrator) are intended to run as Docker containers on the host
PC. They reach host-installed applications - qBittorrent, Jellyfin, and any
future host apps - over the network via `host.docker.internal`, the same
pattern torrent-downloader already uses for qBittorrent (see its
`.env.example` `QB_HOST` notes). Each service's Dockerfile and `.env.example`
already account for this (host vs. container `*_HOST` values).

Containers communicate with each other over HTTP + `X-API-Key`, same as they
would un-containerized - no service-to-service magic beyond normal REST calls
(plus a shared Docker network/compose file once orchestrator exists).

## Version tracking & rebuild (`bin/`)

The root `docker-compose.yml` tags each image `medialab/<svc>:${<SVC>_VERSION}`
and passes that version as the `APP_VERSION` build arg, which the Dockerfile
bakes in two ways: `hatch-vcs` version (via `SETUPTOOLS_SCM_PRETEND_VERSION`)
and an `org.opencontainers.image.version` OCI label. Versions come from each
pinned submodule's `git describe --tags` - the git tag stays the single source
of truth (see "Versioning: never predict a version number").

Three scripts (repo-local, run by explicit path - they install nothing global):

```bash
bin/medialab-versions.sh   # write .versions.env from submodule tags (gitignored, transient)
bin/medialab-build.sh [svc...]  # regen versions, then docker compose build (subset by name, or all)
bin/medialab-status.sh     # 5-way skew table: local / pinned / built / running / latest-tag
```

`bin/medialab-status.sh` is how you see version skew: LOCAL (submodule working
tree) vs PINNED (root submodule SHA) vs BUILT (OCI label on the local image) vs
RUNNING (label on the live container) vs LATEST-TAG (newest tag on origin). A
clean stack has local == built == running == newest tag.

To run compose with the real version tags, load BOTH env files:
`docker compose --env-file .env --env-file .versions.env up -d`. Passing any
`--env-file` disables compose's automatic `.env` load, so the root `.env`
(`MEDIA_HOST_DIR`) must be passed explicitly alongside the versions file (a
bare `docker compose ...` still works - `.env` auto-loads and the `:-dev`
fallbacks keep it running unversioned).

**Baseline pre-rework:** the stack running before this tooling was built with the
old compose (no `APP_VERSION` arg), so those images carry `0.0.0` internally and
`status` shows them `unlabeled`. Their real versions were reconstructed from
image-build-date vs tag-history and recorded in `WORKING-STATE.md` +
`bin/last-known-good.env` as the last-known-good rollback point. Post-rework
builds carry the true version, so this inference is a one-time thing.

## Design debt (observed, not yet scheduled)

Running list of poor or fragile design choices noticed during operation. Fold
each into a backlog item when it starts costing time; none is urgent alone.

- **Single magnet assumption across all search plugins** (now scheduled as
  backlog item 23). `filter_and_sort_results` requires `fileUrl` to be
  `magnet:?`, but qBittorrent's plugins return three shapes (magnet / `.torrent`
  URL / HTML details page). Non-magnet results are silently dropped, so
  content only indexed by the non-magnet plugins (older/niche TV) returns an
  empty picker despite raw hits. Root cause of the show-download gap. See item
  23 for the tiered fix and the post-add hash-caching design change.
- **Two-flag compose invocation.** Any versioned compose command needs
  `--env-file .env --env-file .versions.env` because passing one `--env-file`
  kills the automatic `.env` load. Forgetting a flag silently degrades (`:dev`
  image tags or a blank `MEDIA_HOST_DIR`). Fix: a `bin/medialab-up.sh` wrapper
  (mirroring `medialab-build.sh`) so no human types the flags; or fold
  `MEDIA_HOST_DIR` handling into the generated file's flow.
- **Version-grammar collision (fixed 2026-07-13, watch for recurrence).** One
  string feeds two grammars: Docker image tags (no `+`) and PEP 440
  `SETUPTOOLS_SCM_PRETEND_VERSION` (no raw git-describe `-N-gHASH`).
  `bin/medialab-versions.sh` now maps describe output into the intersection
  (`X.Y.Z.postN`, dirty -> `.dev0`), losing the commit hash from the image tag
  (recoverable via the root submodule pin). Underlying smell: building
  untagged commits at all. Cleaner habit: tag (patch bump) before building a
  deploy, so images are always exact-tag versions.
- **Pins routinely sit past the last tag.** Post-release `chore` commits (OCI
  label stamps, template add/remove) leave every submodule N commits ahead of
  its tag, which is what exercised the collision above. Either tag after such
  chores or batch them into the next release PR.
- **Config duplication across per-service `.env` files** - shared values
  (API keys both sides of a pair, `MEDIA_HOST_DIR` vs each service's mount
  expectations) are hand-synced. Already tracked: [[chore_config_layout]],
  owned by the setup wizard (backlog item 8).
- **`WORKING-STATE.md` is a one-shot document.** The inferred-baseline
  rollback table is obsolete once a post-rework stack is verified live;
  prune or archive it then so it does not read as current truth.

## Environments (prod / dev)

Deferred. A dev/staging environment model (base compose + overlays, namespaced
by `COMPOSE_PROJECT_NAME`, a separate dev Discord bot in a separate dev guild) is
not built - it is not earning its keep for a solo user with tagged releases to
revert to. Build-and-test happens on the single prod stack for now. When a dev
environment is wanted, it is folded into the full-containerization work (backlog
item 20, `containerized-stack-vpn-spec.md`), which is also the self-hostable
path.

## Environment

Host: Windows 10, main PC (also gaming machine - avoid CPU/GPU-heavy local services).
Media server: Jellyfin (REST API available for future integration).
VPN: active VPN required (torrent-downloader enforces VPN binding).
