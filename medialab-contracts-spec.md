# medialab-contracts spec (draft - pre-repo)

Status: design draft (2026-06-26). No repo/code yet. Once approved, this moves
into `medialab-contracts/CLAUDE.md` and the repo/submodule get created.
Roadmap item 4 - precedes torrent-downloader v1.2 so v1.2 consumes shared
models rather than redefining them.

## Purpose

A small, versioned package of Pydantic models + enums shared across the
medialab services, so a cross-service contract is defined once instead of
copy-pasted into each repo. Eliminates the drift already present in the
codebase (see "Evidence" below). Each service depends on a pinned version;
bumping it is a deliberate, reviewable step.

## Evidence (real duplication/drift found 2026-06-26)

- **`ErrorResponse`** is defined three times - identical in torrent-downloader
  and medialab-jellyfin (both with a `json_schema_extra` example), and a bare
  copy in medialab-bot. Pure duplication.
- **`MediaType`** has already drifted: torrent-downloader defines it as
  `Literal["movie", "show"]`; medialab-jellyfin defines it as a
  `class MediaType(str, Enum)`. Same concept, two incompatible types.
- **`TransferInfo`** in medialab-bot is a byte-for-byte copy of
  torrent-downloader's. The bot mirrors a contract it does not own.
- **`ErrorCode`** enums in torrent-downloader and medialab-jellyfin share six
  identical codes and diverge on the rest.

This is exactly the drift the package prevents as the surface grows (v1.2,
orchestrator).

## What goes in (MVP scope)

### `MediaType` (enum)
Canonical form is `class MediaType(str, Enum)` with members `MOVIE = "movie"`,
`SHOW = "show"` - matches the suite's `(str, Enum)` convention (the UP042
decision) and jellyfin's existing shape. torrent-downloader migrates its
`Literal` alias to this enum (its `DownloadRequest.media_type` and the
host-path resolver switch to the enum; wire/JSON values stay `"movie"`/`"show"`
so the API is unchanged).

### `ErrorResponse` (model)
The single structured-error shape used by every service:
`{status: str, code: str, detail: str}` plus the `json_schema_extra` example.
`code` stays a plain `str` on the wire (so any service's ErrorCode serialises
in without contracts needing to know every code).

### `CommonErrorCode` (enum)
The six codes shared by all HTTP services:
`UNAUTHORIZED`, `RATE_LIMITED`, `INVALID_INPUT`, `INTERNAL_ERROR`,
`PATH_NOT_FOUND`, `PERMISSION_DENIED`. Each service defines its own `ErrorCode`
that re-exports/includes these plus its service-specific codes (e.g.
torrent-downloader adds `QB_UNAVAILABLE`, `VPN_NOT_BOUND`, `TRANSFER_NOT_FOUND`;
jellyfin adds `LIBRARY_NOT_FOUND`, `LIBRARY_AMBIGUOUS`). Shared codes single-
sourced; services keep autonomy over their own vocab. No forced coupling to
each other's error sets.

### Transfer DTOs (models)
`TransferInfo` (the per-torrent runtime snapshot) and `TransferHashInfo` (the
cached `media_type` + `host_path`, gaining `tmdb_id` in v1.2). Owned by
torrent-downloader's contract, consumed by the bot and the orchestrator -
belongs in the shared package. `TransferHashInfo.media_type` becomes the shared
`MediaType` enum.

## What stays out (deliberately not shared)

- **Service-internal schemas** with no cross-service consumer (TMDB detail
  shapes, torrent search-result grouping, Jellyfin VirtualFolder DTOs,
  Discord embed models). These are implementation detail of one service.
  Only models that genuinely cross a service boundary go in contracts - per
  the DRY-with-judgment standard (never abstract across domains just to
  dedupe).
- **Each service's full `ErrorCode` enum** - only the common base is shared.
- **`AppException`** and other behavior - contracts is data models only, no
  logic, no framework deps beyond pydantic.

## Package shape

```
medialab-contracts/           (independent repo / submodule)
├── pyproject.toml            (hatchling + hatch-vcs, pydantic only; full
│                              engineering standards from commit one)
├── CLAUDE.md
├── CHANGELOG.md
├── src/medialab_contracts/
│   ├── __init__.py           (re-export the public surface)
│   ├── media.py              (MediaType)
│   ├── errors.py             (ErrorResponse, CommonErrorCode)
│   └── transfers.py          (TransferInfo, TransferHashInfo)
└── tests/                    (model parse/serialise/round-trip tests)
```

Runtime dependency: `pydantic` only. No FastAPI, no httpx - it must be
importable by any service (and by the Discord bot) without pulling a web
framework.

## Versioning & consumption

- Own `vX.Y.Z` tags via hatch-vcs, like every service.
- Each consumer pins a version in its `pyproject.toml`
  (`medialab-contracts>=0.1,<0.2` style) and imports from `medialab_contracts`.
- Distribution: **uv git dependency, tag-pinned.** Each consumer declares it
  via `[tool.uv.sources]` with a git URL + tag:
  ```toml
  [project]
  dependencies = ["medialab-contracts"]

  [tool.uv.sources]
  medialab-contracts = { git = "https://github.com/MickMarch/medialab-contracts", tag = "v0.1.0" }
  ```
  Bumping the version = changing the tag (deliberate, reviewable). No registry
  needed.
- **Docker build wrinkle:** a git-ref dep needs git + network access during
  `uv sync` in the image build. Each consumer's Dockerfile must allow this
  (git installed in the build stage, network available), or switch to a
  local path source / vendored copy in the build context. Resolve per service
  when its Dockerfile is touched; document the chosen approach.
- A breaking model change is a major bump; consumers update their pin
  deliberately. This is the controlled-drift seam.

## Migration sequence (after the package exists)

1. Stand up `medialab-contracts` with the MVP models + tests + standards.
2. torrent-downloader: replace local `ErrorResponse`, `MediaType` (Literal ->
   enum), `TransferInfo`, `TransferHashInfo` with contracts imports; keep its
   own `ErrorCode` but base it on `CommonErrorCode`. (Fold into v1.2 since v1.2
   already touches these schemas.)
3. medialab-jellyfin: replace local `ErrorResponse` and `MediaType` with
   contracts; base its `ErrorCode` on `CommonErrorCode`.
4. medialab-bot: replace its copied `ErrorResponse` and `TransferInfo` with
   contracts imports.
5. orchestrator (item 6): consume contracts from the start.

Each migration is a small per-service PR pinning the contracts version. Done
opportunistically - v1.2 carries torrent-downloader's migration; the others
can follow without blocking the orchestrator.

## Open questions for implementation phase

- Docker: confirm git+network in each consumer's build stage for the uv git
  source, or switch that service to a path/vendored source. Decide per
  Dockerfile.
- Whether `CommonErrorCode` membership should be enforced (e.g. a test that
  each service's ErrorCode is a superset) or left as convention.
