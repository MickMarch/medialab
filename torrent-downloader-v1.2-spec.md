# torrent-downloader v1.2 spec (draft)

Status: design draft (2026-06-26). Roadmap item 5. Two coupled changes shipped
together: (A) thread `tmdb_id` through the download/transfer flow for the
orchestrator, and (B) migrate this service onto `medialab-contracts` v0.2.0.

No backward compatibility required - nothing is shipped to anyone but the
author. `tmdb_id` is **required** end to end (the bot always has it), and there
are no pre-v1.2 cached entries to tolerate.

## Goal A - tmdb_id threading

The orchestrator needs the TMDB id at torrent-completion time to resolve a
canonical `Title (Year)` instead of guessing from the release name. The bot
already knows the id (the user picked the search result), so thread it through:
bot -> `POST /download` -> cache against the torrent hash -> returned by
`GET /transfers/{hash}/info`.

### Changes

**`POST /api/v1/download`** - `DownloadRequest` gains a required `tmdb_id: int`.
Cache it alongside the existing `media_type` / `host_path`.

Current cache write:
```python
app_cache.set(f"media_type:{hash}", {"media_type": ..., "host_path": ...})
```
New cache write adds `tmdb_id`:
```python
app_cache.set(f"media_type:{hash}", {"media_type": ..., "host_path": ..., "tmdb_id": ...})
```

**`GET /api/v1/transfers/{hash}/info`** - returns the `TransferHashInfo`
contract (contracts v0.2.0), which now requires `tmdb_id: int`, read straight
from the cached entry. No pre-v1.2 entries exist, so no defaulting/None
handling.

## Goal B - migrate onto medialab-contracts v0.1.0

Replace this service's local copies of the shared models with imports from
`medialab_contracts`, eliminating the drift the package exists to prevent.

### Dependency

Add to `pyproject.toml`:
```toml
[project]
dependencies = [ ..., "medialab-contracts" ]

[tool.uv.sources]
medialab-contracts = { git = "https://github.com/MickMarch/medialab-contracts", tag = "v0.2.0" }
```

### Model replacements

- **`MediaType`**: drop the local `Literal["movie", "show"]` in
  `schemas/downloads.py`; import `MediaType` (enum) from contracts.
  `DownloadRequest.media_type` becomes the enum. Wire values stay
  `"movie"`/`"show"` so the API is unchanged. The host-path resolver's
  `MEDIA_TYPE_SUBDIRS` dict is keyed by the enum (or its `.value`) instead of
  raw strings.
- **`ErrorResponse`**: drop the local copy in `schemas/errors.py`; import from
  contracts. Update the `responses=` references and any import sites.
- **`TransferInfo`**: drop the local copy in `schemas/transfers.py`; import
  from contracts (identical shape).
- **`TransferHashInfo`**: drop the local copy; import from contracts. The
  contracts v0.2.0 version carries the required `tmdb_id`, which is exactly
  what Goal A needs - so Goal B supplies the return model for Goal A.

### ErrorCode

Keep this service's `ErrorCode` enum (it has service-specific codes
`QB_UNAVAILABLE`, `VPN_NOT_BOUND`, `TRANSFER_NOT_FOUND`). Python enums cannot
inherit members, so do not try to subclass `CommonErrorCode`. Instead:

- Define the six shared members using `CommonErrorCode`'s values as the source
  of truth (e.g. `UNAUTHORIZED = CommonErrorCode.UNAUTHORIZED.value`), plus the
  three service-specific members.
- Add a test asserting `ErrorCode` is a superset of `CommonErrorCode` (every
  common code present with the same value). This enforces the shared base
  without enum inheritance gymnastics and catches drift if a shared code is
  renamed in contracts.

`AppException` stays local (contracts is data-only, no behavior).

## Out of scope

- v1.2 TMDB trending/similar endpoints (separate, still roadmap backlog).
- Migrating other services onto contracts (jellyfin, bot) - their own PRs.

## Test plan (TDD - failing tests first)

1. **tmdb_id in download**: posting `/download` with `tmdb_id` caches it;
   `/transfers/{hash}/info` returns it. Posting **without** `tmdb_id` is a 422
   validation error (it is required).
2. **contracts MediaType**: `DownloadRequest` accepts `"movie"`/`"show"`,
   rejects others; host-path resolution still maps to `Movies`/`Shows`.
3. **ErrorCode superset**: `ErrorCode` contains every `CommonErrorCode` member
   with matching value.
4. Existing tests stay green, updated where the `tmdb_id` field is now required
   on download requests.

## CI / Docker note

The git-ref contracts dependency needs git + network during `uv sync`. CI
(GitHub Actions) already has both. The service's Dockerfile build stage must
also allow it (git installed, network available) - verify when the Dockerfile
is next touched; not blocking this PR since CI covers the test gate.
