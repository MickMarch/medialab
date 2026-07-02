# Spec: TV season/episode targeting for torrent search

Status: DRAFT (awaiting approval)
Date: 2026-06-30
Roadmap: new backlog item (slots near reliability work, items 10/11)

## Problem

For TV shows the download flow searches torrents by **show title only**, buckets
results by resolution, and sorts by seeders. The latest season's packs almost
always have the highest seeder counts, so older seasons and individual episodes
are buried or absent. A user cannot reliably download season 2 of a show whose
season 5 just aired.

Observed in `torrent-downloader/services/qbittorrent.py`:
`execute_plugin_search` passes the raw query straight to qBittorrent's plugin
search; `filter_and_sort_results` only filters on min-seeders and sorts desc by
seeders; `group_by_resolution` PTN-parses solely for resolution.

## Decisions (locked)

1. **Granularity: season + episode.** A show download targets whole-series, a
   specific season (`S0N`), or a single episode (`S0NE0M`).
2. **Season source: TMDB show detail.** The bot reads the real season list from
   the existing show-detail endpoint; no manual season entry, no nonexistent
   seasons.
3. **Filter strictness: strict.** Results are PTN-parsed and non-matching
   releases are dropped (full-series packs are always kept as a fallback). This
   directly removes the buried-old-season problem.

## Scope by repo

### medialab-contracts (bump v0.2.0 -> v0.3.0)

Add a shared request shape for a torrent search scope so all three services
agree on it. New model `TorrentSearchScope`:

```python
class TorrentSearchScope(BaseModel):
    media_type: MediaType            # movie | show
    season: int | None = None        # None for movie or whole-series
    episode: int | None = None       # None unless a single episode is targeted
```

Validation rules (enforced in the model):
- `media_type == "movie"` -> `season` and `episode` MUST be None.
- `episode is not None` requires `season is not None` (no orphan episode).
- `season`/`episode` are >= 1 when present.

Release as v0.3.0, root-pin bump, consumed by torrent-downloader + orchestrator.
(The bot can carry the season/episode as plain ints in component state; it does
not strictly need the contract model, but may import it for validation.)

### torrent-downloader (v1.2 -> v1.3)

**`GET /api/v1/search/torrents`** gains query params:
- `media_type: MediaType` - **required** (movie | show).
- `season: int | None` - optional; None = whole series.
- `episode: int | None` - optional; requires `season`.

Same validation as the contract model (422 on a bad combination, e.g.
movie+season, or orphan episode).

**Query refinement** (`services/qbittorrent.py`):
- Build the qBittorrent search `pattern` from the title plus a season/episode
  tag so trackers return the right packs:
  - whole series -> `"<query>"` (unchanged)
  - season only -> `"<query> S{season:02d}"`
  - episode -> `"<query> S{season:02d}E{episode:02d}"`
- New constant for the tag format (no magic strings; `PLR2004` clean).

**Result filtering** (`services/qbittorrent.py`):
- New function `filter_by_scope(results, season, episode)` run **before**
  `group_by_resolution` (and after `filter_and_sort_results`). For each result
  PTN-parse `fileName`:
  - target = single episode: keep if parsed `season == season` AND parsed
    `episode == episode`; also keep a release that is the matching **season
    pack** (parsed season matches, no episode field) and full-series packs.
  - target = season: keep if parsed season matches (int equal, or requested
    season is a member of PTN's season list for a range pack); complete-series
    and multi-season range packs are kept as labeled fallbacks.
  - target = whole series / movie: no scope filtering (current behavior).
- PTN parses `season`/`episode` as either an int or a list (multi-season/-episode
  packs). The matcher must handle both: membership test when PTN returns a list.
- Fallback grouping: a release is a primary match when its parsed season equals
  the request exactly (single-season pack or episode within it). A release is a
  fallback match when the requested season is a member of a multi-season range
  list, or the release is a complete-series pack (PTN yields no usable season
  field but the name hints `complete`/`series`). Primary matches rank above
  fallbacks; fallbacks ensure the result set is never empty.

**Endpoint wiring** (`routers/search.py`): thread the new params through
`search_torrents` -> `filter_and_sort_results` -> `filter_by_scope` ->
`group_by_resolution`.

**Cache key**: include season/episode in the torrent search cache key
(`torrent_search_{query}_{season}_{episode}`) so a season-2 search does not
return a cached season-5 result set.

### medialab-orchestrator (v0.1.0 -> v0.2.0)

Gateway passes the new params straight through on its `GET /search/torrents`
proxy. No job-table change - season/episode only steers search; the chosen
magnet still drives `POST /download` exactly as today. Update the proxy
signature + tests; bump the pinned contracts dep.

### medialab-bot (v1.0.0 -> v1.1.0)

New UI state between the title pick and the torrent pick, **only for shows**:

1. `/search` -> TMDB pick (unchanged). For a `movie`, flow is unchanged.
2. For a `show`, after the pick the bot calls
   `GET /api/v1/search/tmdb/show/{tmdb_id}`, reads `seasons[]`
   (`season_number`, `name`, `episode_count`), and shows a **scope Select**:
   - "Whole series"
   - one option per real season ("Season 2 - 10 episodes")
   - (episode targeting: a season pick can open a follow-up episode Select, or a
     "whole season" default - see open question 2).
3. The chosen `season`/`episode` is carried in the component `custom_id`
   alongside the existing `tmdb_id` + `media_type`, into the torrent search call
   and the torrent picker.
4. Torrent pick -> `POST /download` unchanged (magnet + media_type + tmdb_id).

`TORRENT_RESULTS_PER_RESOLUTION` and the size-in-picker work (backlog item 17)
are orthogonal and unaffected.

## Resolved decisions (was open questions)

1. **Full-series-pack fallback.** Both complete-series packs AND multi-season
   range packs are valid fallbacks. PTN returns a list for a season range
   (e.g. `[1, 2, 3]`); a release whose parsed season list *contains* the
   requested season is a fallback match. Render fallbacks as a secondary labeled
   group so a season-2 request never returns empty, without letting them
   outrank the season-specific matches.
2. **Episode UI depth.** Ship both season AND single-episode targeting in the
   first cut. Season pick -> follow-up "whole season vs. pick an episode" Select
   (episode list from the season's `episode_count`).
3. **`media_type` requirement.** `media_type` is **required** on the show
   torrent search. Make `media_type` a required query param on
   `GET /search/torrents`; `season`/`episode` stay optional (None = whole
   series). Movie searches pass `media_type=movie` with no season/episode. No
   back-compat flat-search path - the gateway always knows the type.

## Test plan (per repo, failing-first)

- contracts: model validation table (movie+season rejected, orphan episode
  rejected, valid combos accepted).
- torrent-downloader: `filter_by_scope` unit table (season pack matches, wrong
  season dropped, multi-season list membership, episode match, full-series
  fallback never-empty); pattern-builder unit; cache-key includes scope;
  endpoint 422 on bad combo; endpoint threads params.
- orchestrator: proxy forwards params; passthrough integration mock.
- bot: show pick triggers detail fetch + scope Select; movie pick skips it;
  scope threaded into torrent search; custom_id round-trips season/episode.

## Sequencing

contracts v0.3.0 first (others depend on it) -> torrent-downloader v1.3 ->
orchestrator v0.2.0 -> bot v1.1.0. Each its own repo PR, root-pin bump per the
submodule workflow.
