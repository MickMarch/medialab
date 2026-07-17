# Item 23 spec - per-plugin `fileUrl` handling + surrogate job key

Status: DRAFT for approval. Spec-first per workspace workflow; no code until
this is approved. Do NOT predict version numbers here (choose at release from
the last tag + change kind).

## Problem

qBittorrent search plugins return three different `fileUrl` shapes, but the
pipeline assumes every result is a magnet and drops the rest, so content only
indexed by the non-magnet plugins (older/niche TV) returns an empty picker even
when viable, well-seeded torrents exist. Diagnosed live 2026-07-17. See root
`CLAUDE.md` item 23 and `API-KEYS.md`; memory `plugin_fileurl_shapes`.

Observed shapes:

| Engine | `fileUrl` | Handling |
|---|---|---|
| piratebay | `magnet:?xt=...` | use directly (works today) |
| torlock | `.torrent` file URL, serves `application/x-bittorrent` | qBittorrent `torrents_add(urls=...)` fetches it natively |
| limetorrents | HTML details page (`fileUrl == descrLink`) | scrape `magnet:?xt=urn:btih:...` from page (Tier B, later) |
| jackett | error row (skipped - Jackett not run here) | n/a |

The magnet-only filter (`filter_and_sort_results`) is the drop point. But the
deeper coupling is that the job's identity IS the info-hash, known up front only
from a magnet - so even if the filter let a `.torrent` URL through, the
orchestrator could not create its job. Fixing the filter without fixing the key
would only move the failure downstream.

## Scope of THIS spec

Tier A (`.torrent` URL passthrough) + the job-keying change that unblocks it.
Tier B (details-page scrape) and jackett are explicitly OUT and stay in item 23
backlog for a follow-up. Tier C (resolution-`Other` bucket) already shipped
(torrent-downloader v1.3.3).

## Locked decisions (2026-07-17)

1. **Surrogate job id + backfilled hash.** The `pipeline_job` primary key
   becomes a locally-generated `job_id` (uuid4 hex). `torrent_hash` becomes a
   nullable, indexed column, backfilled once qBittorrent knows the hash. This
   decouples job identity from how the torrent was sourced, so magnet /
   `.torrent` URL / (future) scraped page all create a job the same way.
2. **`magnet_uri` -> `source_url`.** The download request field is renamed and
   widened to accept a magnet OR an http `.torrent` URL. torrent-downloader
   classifies by shape. Pre-release, so no backward compatibility is kept.

## The hash-timing problem (why keying changes)

Today: gateway `_extract_hash(magnet_uri)` -> `create_job(torrent_hash=...)`.
The hash is the PK and the join key for: the completion webhook (`%I`),
every worker step, `GET /jobs/{hash}`, `POST /jobs/{hash}/retry`,
`transfer_info(hash)`, and torrent-downloader's `media_type:{hash}` cache.

For a `.torrent` URL the info-hash is not known until qBittorrent fetches and
bdecodes the file - after the add, asynchronously. So the hash cannot be the
creation-time key. The surrogate `job_id` fixes this: the job is created keyed
by `job_id`, and the hash is stamped in when it becomes known.

### When the hash becomes known

- **magnet source:** immediately (parse btih from the URI, as today). Stamp at
  submit.
- **`.torrent` URL source:** after `torrents_add`. torrent-downloader reads the
  hash back from qBittorrent (match the just-added torrent) and returns it in
  the `POST /download` response. Gateway stamps it onto the job.
- **fallback / either case:** the completion webhook always carries the real
  hash (`%I`). If a job still has a null hash at completion (add-readback
  failed), the webhook backfills it. This makes the readback best-effort, not a
  hard dependency - the webhook is the backstop.

## Changes by repo

### medialab-contracts (shared models - bump minor)

- `DownloadRequest`-shaped DTO (if present here) / the download field: rename
  `magnet_uri` -> `source_url: str`. If a `url_kind` enum is wanted later it is
  additive; this spec sniffs shape in the downloader and does NOT add the enum
  (keep contract surface small).
- Job/transfer DTOs that expose `torrent_hash` must allow it to be `None`
  (a job may exist before its hash is known). `JobView` / `TransferInfo`
  reviewed for `torrent_hash: str | None`.
- Tag a new minor; every consumer repins.

### torrent-downloader (downloader - bump minor)

- **`schemas/downloads.py`**: `magnet_uri` -> `source_url`.
- **`filter_and_sort_results`** (`services/qbittorrent.py`): stop requiring
  `magnet:?`. Accept a result whose `fileUrl` is a magnet OR ends in `.torrent`
  (Tier A). Details-page HTML still dropped in this tier (Tier B later). Keep
  the seeder floor + sort.
- **`POST /download`** (`routers/transfers.py`):
  - Classify `source_url`: magnet -> `torrents_add(urls=magnet)` as today;
    `.torrent` URL -> `torrents_add(urls=source_url)` (qBittorrent fetches it).
  - Hash: for magnet, parse btih up front (as today). For `.torrent` URL, read
    the hash back from qBittorrent after add (look up the newly-added torrent;
    `torrents_add` does not return it). Return the hash in the response so the
    gateway can stamp the job.
  - Cache `{media_type, host_path, tmdb_id}` keyed by the resolved hash, same as
    today, but AFTER the hash is known (post-add for the URL case). If the
    readback fails, log and continue - the completion webhook backfills.
  - `DownloadResponse` gains `torrent_hash: str | None` (the resolved hash, or
    null if not yet known).
- Tests: `.torrent`-URL add path (mock qBittorrent add + readback), filter
  accepts `.torrent`, response carries the hash. Existing magnet path unchanged.

### medialab-orchestrator (gateway/job store - bump minor)

- **`store/jobs.py`**: schema change. `id` becomes the uuid `job_id` PK;
  `torrent_hash` becomes `TEXT NULL UNIQUE` (unique when present), indexed.
  New/changed methods: `create_job()` returns a job with a `job_id`, no hash
  required; `get_job_by_id(job_id)`; `stamp_hash(job_id, torrent_hash)`;
  `get_job_by_hash(hash)` stays (webhook path). Since this is pre-1.0 and the
  DB is a local homelab file, do a clean schema (no migration script; document
  that an existing `orchestrator.db` is discarded/recreated - note in CHANGELOG).
- **`routers/gateway.py` `POST /download`**: no `_extract_hash` at submit.
  Create the job by `job_id`. Forward `source_url` to torrent-downloader; if the
  response carries a hash, `stamp_hash(job_id, hash)`. Return the job (its
  `job_id`, and hash if known).
- **`routers/gateway.py` `/jobs/{...}` + retry**: address jobs by `job_id`
  (path becomes `/jobs/{job_id}`). `GET /jobs` keyed by `job_id`.
- **`routers/webhooks.py`**: unchanged join by hash (`%I`) - if it finds a job
  with that hash, advance it; if it finds a hash-less job that matches by other
  means it stamps it; if none, orphan-insert as today. (Detail: matching a
  hash-less in-flight job to the webhook - simplest is that the readback already
  stamped the hash at submit for the common case, so the webhook match works;
  the orphan path covers the rest.)
- **`worker.py`**: steps address the job by `job_id` internally; the hash is
  read from `job.torrent_hash` where a downstream call needs it
  (`transfer_info`, stop-seeding). All those run post-completion, so the hash is
  always present by then.
- Tests: create job without hash, stamp hash, address by job_id, webhook still
  matches by hash. `store` in-memory fixture updated.

### medialab-bot (bot - bump minor)

- Client `download(...)` sends `source_url` instead of `magnet_uri` (value is
  still `result.file_url` from the picked torrent - now possibly a `.torrent`
  URL, which is fine).
- `/jobs` and the retry view address jobs by `job_id` (display can still show a
  short hash when known).
- The torrent picker already forwards whatever `file_url` the result carries -
  no picker logic change beyond the field rename.
- Tests: download sends `source_url`; jobs/retry use `job_id`.

## Sequence

contracts (rename + nullable hash) -> torrent-downloader (source_url + `.torrent`
add + hash readback) -> orchestrator (surrogate key + stamp) -> bot (field +
job_id). Each is its own PR + release + root pin bump, tested green, then a live
verify: `/search` The Simpsons -> season 23 -> a torlock `.torrent` result now
appears in the picker (Tier C already lets untagged in) -> download -> `/jobs`
shows the job, hash stamped, pipeline advances on completion.

## Explicitly out of scope (stay in item 23 backlog)

- Tier B: limetorrents details-page magnet scraping.
- Jackett (operational, user chose to skip).
- `url_kind` enum in the contract (sniff shape in the downloader instead).

## Open questions

1. Webhook-to-hashless-job match: in the rare case the `.torrent` readback fails
   at submit (job has null hash) AND the webhook fires, how does the webhook
   find the right job? Options: (a) orphan-insert keyed by hash and reconcile
   later (accept a possible duplicate row); (b) match on `release_name` from
   `%N`; (c) accept that the readback is reliable enough that this is a
   log-and-orphan edge. Leaning (c) for MVP - the readback is a synchronous
   qBittorrent call right after add and should almost always succeed.
2. `GET /jobs/{job_id}` vs keeping a hash lookup too - do we need both address
   forms, or is `job_id` sufficient for the bot (which holds the id it was
   returned)? Leaning job_id-only; webhook uses the internal by-hash store
   method, not the HTTP path.
