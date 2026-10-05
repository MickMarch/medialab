# Spec: real torrent search progress in the web UI

Status: Approved
Issue: MickMarch/medialab#80

## Problem

A torrent search runs up to `search_timeout_seconds` (15 s by default) and
the web UI shows a bar that fills on a CSS timer bounded by that timeout. The
bar is a guess: it reaches the end at the same moment whether the plugins
finished in three seconds or are still hanging, and it says nothing about
how many patterns ran or how many results are already in. On a 15 s wait that
reads as "stuck" more often than "working".

The downloader does know the real state. `run_pattern_searches` runs one
qBittorrent search job per pattern, concurrently, and `execute_plugin_search`
polls each job's status every `POLL_INTERVAL_SECONDS`; that status carries
the running result count. Nothing exposes it.

## Goal and non-goals

**Goal.** While a search is in flight, the web bar shows real progress:
patterns finished out of patterns started, results found so far, and a fill
that advances with those numbers rather than with the clock. The existing
timed fill stays as the fallback when progress cannot be read.

**Non-goals.** A job-style search (start, poll, fetch results) with a search
id and stored results: the synchronous `GET /search/torrents` keeps its
contract and the bot keeps using it unchanged. Per-plugin progress: qBittorrent
reports a job's status and result count, not which plugins are done. Progress
for `/search/torrents/pick` (the follow poller has no UI). Cancelling a search.

## Design

The search identity is the request itself: `query`, `media_type`, `season`,
`episode`, `alt_query`. The downloader already reduces that to a list of
patterns and a category, and caches raw results per pattern. Progress is read
by the same parameters, so the web asks "how is the search I just started
doing" without any id round trip.

### torrent-downloader

- `services/search_progress.py`: an in-process registry keyed by
  `(pattern, category)`, the cache key's own identity. `execute_plugin_search`
  marks a pattern started, updates its result count on every status poll, and
  marks it finished (completed or timed out). Entries expire after
  `search_timeout_seconds` past finish, so the registry never grows. One
  uvicorn worker owns the search threads, so one dict behind a lock is the
  whole store.
- `GET /search/torrents/progress` with the five search parameters returns a
  `TorrentSearchProgress`: `state` (`idle`, `running`, `done`),
  `patterns_total`, `patterns_done`, `results_so_far`, `elapsed_seconds`,
  `timeout_seconds`. A pattern served from the result cache counts as done
  with its cached result count. `running` when any pattern is in flight,
  `done` when every pattern is cached or finished, `idle` when none has
  started. Not rate-limited with `RATE_LIMIT_SEARCH` (it is polled once a
  second); it uses `RATE_LIMIT_DEFAULT`. It never touches qBittorrent.

### medialab-contracts

- `TorrentSearchProgress` and its `SearchProgressState` enum, next to
  `TorrentSearchScope`. The gateway relays it and the web renders it.

### medialab-orchestrator

- `GET /search/torrents/progress`: a proxy like `GET /search/torrents`,
  same scope validation, `RATE_LIMIT_DEFAULT`.

### medialab-web

- `client/_torrents.py`: `search_progress(...)` with the search's parameters,
  `None` on any failure.
- `GET /partials/search/progress`: renders the bar's inner block (the line of
  text and the fill) from one progress read. Fill fraction is
  `(patterns_done + in_flight_fraction) / patterns_total`, where
  `in_flight_fraction` is `min(elapsed / timeout, 1)` for the running
  patterns, so the bar advances between pattern completions too. Text:
  `2 of 3 patterns done, 57 results so far`. `idle` renders the current
  fallback text; `done` renders a full bar.
- `partials/searching.html`: the inner block carries
  `hx-get="/partials/search/progress"`, the search parameters as `hx-vals`,
  and `hx-trigger="every 1s [this.closest('.searching').classList.contains('htmx-request')]"`,
  so it polls only while the bar is shown. The CSS timer animation stays on
  the fill as the fallback: a polled response sets an inline width that
  overrides it; if polling fails the animation keeps running.
- The bar needs the search parameters at render time. Every place that
  includes `partials/searching.html` already has them in scope (the scope
  form, the title card, the show and jobs pages pass them to the torrents
  request); the include takes them explicitly.

| Service | Change |
|---|---|
| torrent-downloader | progress registry; `GET /search/torrents/progress` |
| medialab-contracts | `TorrentSearchProgress`, `SearchProgressState` |
| medialab-orchestrator | proxy route |
| medialab-web | client method, progress partial route, polling bar |
| medialab-bot | none |

## Decisions

1. Progress by search parameters, not by a search id. Rejected: a job-style
   search changes the one search contract three clients depend on, needs
   result storage and expiry, and only the web wants progress. The parameters
   already identify the patterns, and the pattern cache already proves that
   identity is stable.
2. An in-process registry, not the diskcache. Rejected: diskcache writes on
   every status poll (several per second per pattern) for a value that is
   stale in a second; the registry lives in the same process as the search
   threads and dies with it, which is the right lifetime.
3. The timed fill stays as fallback. Rejected: removing it would make a
   polling hiccup look like a frozen bar, which is the complaint this spec
   answers.
4. Patterns, not plugins, are the unit. qBittorrent's search status carries a
   state and a count per job; which plugins finished is not on the wire.
   Patterns are what the downloader starts and waits for, so they are the
   honest unit.
5. `in_flight_fraction` from elapsed over timeout. Within one pattern there is
   no better signal than time; blending it with the done count keeps the bar
   moving without claiming more than is known.

## Open questions

None.

## Test plan

**torrent-downloader** `tests/test_search_progress.py`: registry start,
update, finish, expiry; aggregation across patterns including cached ones
(`idle`, `running`, `done`, counts). `tests/test_routes_torrent_search.py`:
the progress route validates the scope like the search route, returns the
aggregate, does not call qBittorrent.

**medialab-contracts**: model round-trips and the state enum values.

**medialab-orchestrator** `tests/test_gateway.py` or `tests/test_search.py`:
proxy forwards the five parameters and returns the body.

**medialab-web** `tests/test_client.py`: `search_progress` path, parameters,
`None` on failure. `tests/test_search_page.py`: the progress partial renders
the counts and a width from the fractions; `idle` renders the fallback text;
the searching bar carries the polling attributes and the search parameters.

## Rollout

contracts first (tag), then downloader (depends on the tag), then
orchestrator, then web. Minor release each. No host step.
