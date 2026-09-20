# 0002 - Plugin fileUrl shapes: the cheap tier was not the valuable one

Date: 2026-07-20. Spec: `docs/specs/plugin-fileurl-handling.md`.

## What happened

qBittorrent search plugins return three `fileUrl` shapes: a magnet
(piratebay), a `.torrent` file URL (torlock), and an HTML details page
(limetorrents). The search pipeline kept only magnets, so older or niche TV,
indexed only by the non-magnet plugins, produced an empty picker despite
roughly two dozen raw hits. This, not the search pattern, was the root cause
of "shows return nothing".

The fix was tiered. Tier A (`.torrent` URL passthrough) was sequenced first as
the low-risk slice. Tier B (scrape the magnet from the details page) turned out
to be load-bearing: for real shows every seeded result was a limetorrents page,
and the torlock results Tier A recovered were near-zero-seed.

## Decisions

- Any addable source (magnet, `.torrent` URL, details page) passes the filter;
  the downloader classifies it in `services/source.py`.
- Hash caching moved from "extract from the magnet before add" to "snapshot
  `torrents_info()` before and after `torrents_add`; the new hash is the added
  torrent". A URL source carries no hash up front. Chosen over `added_on`
  timestamps or name matching because it is deterministic under concurrent
  adds and yields qBittorrent's own info-hash, matching the completion `%I`.
  Readback is best-effort; the completion webhook always carries the real hash
  and backfills a null.
- The orchestrator job key is a surrogate id, not the torrent hash, because
  the hash is not known at submit time for URL sources.

## Lesson

Sequence tiers by expected value measured against real data, not by
implementation risk. A five-minute check of which plugin actually returned the
seeded results would have put Tier B first.
