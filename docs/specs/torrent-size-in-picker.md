# Spec: torrent download size in the picker

Status: Shipped (2026-09-24)
Issue: MickMarch/medialab#17

## Problem

The torrent picker's option description reads `<n> seeders`. Size is the
other number a user weighs when choosing between results and it is already on
the wire: torrent-downloader returns `fileSize` (bytes) and the bot's
`TorrentResult` carries it as `file_size`. It is never shown.

## Goal and non-goals

**Goal.** Each Select option description shows seeders and size,
`123 seeders · 4.2 GB`, so size vs. seeders is a one-glance choice.

**Non-goals.** Sorting or filtering by size; a size column in `/transfers`;
any change to the search or download path.

## Design

- New `medialab_bot/format.py` with `format_size(size_bytes: int) -> str`:
  decimal units (`KB`, `MB`, `GB`, `TB`, 1000-based, matching what torrent
  sites display), one decimal for values under 10 of a unit, none above
  (`4.2 GB`, `847 MB`, `12 GB`). Zero or negative renders `0 B`.
- `TorrentSelectMenu` builds the description from both values through one
  helper, `option_description(result)`, so the string lives in one place.
  Truncation to the Discord limit stays as today.
- The existing sort test (bot #9) parses the description to recover seeder
  counts; it is rewritten to assert on the ordered results the view indexed,
  not on rendered text, and closes #9.

## Decisions

1. Decimal units, not binary. Torrent indexers and qBittorrent's UI show
   decimal; matching them avoids a "why does it say 3.9 when the site said
   4.2" question.
2. A separator character (`·`) between the two facts, not parentheses; the
   description field is short and the label already carries the file name.
3. Formatting lives in the bot only. It is Discord presentation, not a
   contract.

## Open questions

None.

## Test plan

`tests/test_format.py`: boundaries (0, 999 B, 1 KB, 9.9 MB, 10 MB, 1 GB, 1 TB),
negative input. `tests/cogs/test_search.py`: option description contains the
formatted size and the seeder count; the sort test asserts on indexed results.

## Rollout

One bot PR; `Added` changelog entry; minor release.
