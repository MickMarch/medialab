# 0001 - Cross-service path contracts need a live test

Date: 2026-07-17. Context: TV season targeting (torrent-downloader v1.3.x,
orchestrator, bot).

## What happened

torrent-downloader's TV detail route was `/tmdb/tv/{id}` while the orchestrator
built `/tmdb/show/{id}` from `MediaType.SHOW.value`. Every show-detail call
404'd. The bot silently fell back to whole-series search, hiding the season
picker. Both suites were green: each side mocks the other at the client
boundary, so no unit test exercises the path string the two sides must agree on.

## Decision

- Route segments that encode a shared enum are built from the enum value on
  both sides (`MediaType.value`), never typed as literals.
- Shared path constants (`/api/v1` prefix, header names) live in
  `medialab-contracts`.
- A change to any cross-service route is verified live against the running
  stack before release. Mock-boundary tests cannot catch this class of bug.
