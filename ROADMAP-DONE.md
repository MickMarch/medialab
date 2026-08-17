# ROADMAP - completed items

Archive of finished roadmap and backlog items, moved out of `CLAUDE.md` so that
file carries only live work. Nothing here is actionable. Kept for the durable
lessons and for the record of why things are shaped the way they are.

Live backlog and ordering: `CLAUDE.md`. Current session state: `STATE.md`.

---

## MVP roadmap (items 1-7)

1. **medialab-jellyfin library endpoints** - scan trigger, add path, item search.
   COMPLETE. Library router live on main.

2. **torrent-downloader v1.1** - `media_type`-based save path resolution.
   COMPLETE. `media_type` on `POST /download` plus
   `GET /transfers/{torrent_hash}/info` live on main.

3. **engineering-standards backfill.** COMPLETE (2026-06-26). All three services
   merged ruff + mypy + pre-commit + dependabot + a full CI gate
   (lint/format/typecheck/test/project-dep audit); medialab-bot gained its first
   CI workflow. CVEs surfaced by the audit cleared (bumped
   starlette/pydantic-settings/idna/aiohttp; diskcache CVE-2025-69872 ignored by
   ID pending a fix). PRs: torrent-downloader #4, medialab-bot #11,
   medialab-jellyfin #2.

4. **medialab-contracts package** - shared Pydantic models. COMPLETE
   (2026-06-26), released v0.1.0. Ships `MediaType`, `ErrorResponse`,
   `CommonErrorCode` (six shared codes; services extend), `TransferInfo`,
   `TransferHashInfo`. Consumed as a tag-pinned uv git dependency
   (`[tool.uv.sources]` git + tag). Full design: `medialab-contracts-spec.md`.

5. **torrent-downloader v1.2** - thread `tmdb_id` through `POST /download`, cache
   `{media_type, host_path, tmdb_id}` vs hash, return `tmdb_id` from
   `GET /transfers/{hash}/info`. COMPLETE (2026-06-26), released v1.2.0.
   `tmdb_id` required end to end (no backward compat needed pre-release).
   Migrated onto medialab-contracts v0.2.0. Unblocked the orchestrator's
   canonical `Title (Year)` resolution.

6. **medialab-orchestrator MVP** - front-door orchestrating gateway. SERVICE
   COMPLETE (2026-06-26), released v0.1.0. Ships the full gateway surface (search
   proxies, `POST /download`, `GET /transfers` read-through merge,
   `GET/POST /jobs*`, `GET /storage`, public aggregated health), the SQLite
   `pipeline_job` store, the forward-retry asyncio worker, the keyed
   `POST /webhooks/torrent-complete` + `scripts/notify_complete.py` relay, and
   the PTN-season-only TV rename. Standards from commit one.

   Implementation decisions resolved from the spec's open questions: the webhook
   is keyed, DOWNLOADING is a read-through (no polling), PTN parses season only.

   > The "no polling" decision was later **deliberately reversed** by backlog
   > item 10 - a webhook-only design cannot detect a download that errors before
   > completing, because the completion hook never fires. See item 10 in
   > `CLAUDE.md`.

   The medialab-bot rewrite onto the gateway landed as part of this item (bot
   PR #15): the bot now talks only to the orchestrator, dropped the
   torrent-downloader/jellyfin URLs and keys, the save-path config, and the
   direct health check; `/torrent` removed (see item 21), `/jobs` added,
   `tmdb_id` + `media_type` threaded through download. The root
   `docker-compose.yml` (shared network + media mount) landed here too.

7. **medialab-bot Dockerfile.** COMPLETE (2026-06-26), bot PR #16. Two-stage uv
   with git for the contracts git-ref dep, non-root, no `EXPOSE` (outbound-only
   client). Compose `medialab-bot` service enabled. All four services are now
   Docker images.

---

## Backlog items completed

### 16. Wire the qBittorrent completion webhook

COMPLETE (2026-07-20), verified live end to end.

The relay's runtime home was decided by the question "why build host roots we
migrate away in item 20?" - `scripts/notify_complete.py` was rewritten
**standalone and stdlib-only** (`urllib`, no httpx, no package imports;
orchestrator v0.4.1) so it runs as a dropped-in single file on the host today and
unchanged inside the qBittorrent container after item 20. Migration is then just
re-pointing one qB setting, with no throwaway infrastructure.

The user wired qBittorrent's "Run external program on torrent completion" to
`python "<path>\notify_complete.py" "%I" "%N"` (with `ORCHESTRATOR_URL` and
`ORCHESTRATOR_API_KEY` in the qB process env). A real movie downloaded, the hook
fired, and the pipeline advanced to DONE (SCAN = Jellyfin `Media/Updated` 204).
Full setup instructions and the Windows Defender write-lock note are in the
orchestrator README.

Two fallout fixes were needed and shipped:
- medialab-jellyfin's `.env` had `JELLYFIN_HOST=127.0.0.1` (itself) instead of
  `host.docker.internal` (the host's Jellyfin). Config fix; this was the original
  500.
- The per-download REGISTER step 404'd because the library root is already
  registered. Removed it (orchestrator v0.4.2); the pipeline is now
  RENAME -> SCAN.

Known cosmetic gap, still open: a webhook that finds no matching job
orphan-inserts with `tmdb_id=0`, so RESOLVE_META resolves an empty title. Only
observable because the DB was recreated mid-test - in normal operation the
`/download` submit creates the job with the real `tmdb_id` and the webhook
matches it. The orphan title fallback (PTN-parse the release name when
`tmdb_id=0`) is a nice-to-have tied to item 21.

### 19. TV season/episode targeting in torrent search

COMPLETE (2026-07-02). Full design: `tv-season-targeting-spec.md`. Decisions
locked: granularity = season + episode, season list from the TMDB detail
endpoint, strict drop of non-matching results (range and complete-series packs
kept as labeled fallbacks so the set is never empty).

Shipped across four repos: contracts v0.3.0 (`TorrentSearchScope`),
torrent-downloader v1.3.0 (params + `filter_by_scope` + scope-aware cache key +
category from `media_type`), orchestrator v0.3.0 (proxy passthrough), bot v2.1.0
(`views/scope.py` season/episode pickers + `run_torrent_search` helper).
`media_type` became a required query param on `GET /search/torrents`.

**Lesson (cross-service path contracts).** The first live test (2026-07-17)
caught a bug no suite could: torrent-downloader's TV detail route was
`/tmdb/tv/` while the orchestrator builds `/tmdb/show/` from
`MediaType.SHOW.value`, 404ing every show-detail call. The bot silently fell back
to whole-series search, hiding the scope picker. Fixed in torrent-downloader
v1.3.1 (route renamed to `/tmdb/show/`). Mock-boundary tests never exercise
cross-service path contracts - each side's suite passed while the pair was
broken.

### 23. Per-plugin `fileUrl` handling (magnet / .torrent URL / details page)

COMPLETE (2026-07-20), verified live. Spec: `item-23-plugin-fileurl-spec.md`.

The root cause of "shows return nothing": the search pipeline assumed every
qBittorrent search plugin returns a magnet in `fileUrl`, but plugins return three
different shapes and `filter_and_sort_results` dropped anything that was not
`magnet:?`. Popular movies worked because piratebay indexes them with magnets;
older or niche TV returned only torlock and limetorrents, 100% of which the
magnet-only filter discarded - an empty picker despite roughly 24 raw hits.

| Engine | `fileUrl` shape | Handling |
|---|---|---|
| piratebay | `magnet:?xt=...` | none - already worked |
| torlock | `.torrent` file URL | pass straight to `torrents_add(urls=...)` |
| limetorrents | HTML details page | fetch page, scrape `magnet:?xt=urn:btih:...` |

Shipped: downloader v1.4.0 (Tier A - `.torrent` URL passthrough, snapshot-diff
hash readback, `source_url` rename), orchestrator v0.4.0 (surrogate `job_id` PK,
nullable backfilled `torrent_hash`, hash stamping), bot v2.2.0 (`source_url` +
job-id addressing), downloader v1.5.0 (Tier B - HTML details-page magnet scraping
via `services/source.py`). Tier C (resolution `Other` bucket) had already shipped
in v1.3.3. The DB volume was recreated for the schema change.

**Lesson (the cheap tier was not the valuable one).** Tier A was sequenced first
as the low-risk high-value slice, but Tier B turned out to be load-bearing. For
real shows every seeded result was a limetorrents HTML page; the torlock
`.torrent` results Tier A recovers are near-zero-seed. The picker went from empty
to three seeded results only after Tier B landed.

**Design note (hash caching was the real work, not the add).** Previously
`POST /download` extracted the BTIH hash from the input magnet to cache
`{media_type, host_path, tmdb_id}` against it, which the orchestrator looks up at
completion. A `.torrent` URL or a scraped page carries no hash up front, so
caching moved to after the add: capture the set of torrent hashes via
`torrents_info()` before and after `torrents_add`, and the newly-present hash is
the added torrent. Chosen over `added_on` timestamps or name matching because it
is deterministic under concurrent adds and is qBittorrent's own computed
info-hash, so it matches the completion `%I` exactly. Readback is best-effort,
not load-bearing - the completion webhook always carries the real hash and
backfills a null.

A jackett plugin row also appeared as an error during diagnosis. Jackett is a
separate app not running on this host; deliberately out of scope and not on the
backlog.
