# Spec: discover popular titles, filter by genre, keep a wishlist

Status: Draft
Issue: MickMarch/medialab#81

## Problem

Every download starts with typing a title. There is no way to browse what is
popular right now, and no way to save a title for later when it is not worth
downloading yet (not released, no good torrent, no disk space). TMDB already
ranks titles and lists genres; medialab only needs to cache and present that.
`poster_path` is already carried on every TMDB search result and never
rendered.

## Goal and non-goals

Goal: a poster grid of trending movies and shows in the web UI, optionally
narrowed to one genre, where each title can be sent into the existing torrent
step or added to a wishlist. The bot offers the same actions in a condensed
list. Popular and genre lists are cached server side for at least a day. The
wishlist is one shared, persistent list viewable and editable from both UIs.

Non-goals: automatic downloading of wishlist items (that is #24, which can
consume the wishlist later); per-user wishlists (the suite has one shared
login); marking titles already in the Jellyfin library; recommendations
beyond what TMDB returns.

## Design

### Ownership

| Service | Owns |
|---|---|
| torrent-downloader | TMDB calls (it already owns the key and the cache): trending, discover-by-genre, genre lists, all cached |
| medialab-orchestrator | the wishlist table; the gateway routes; annotating discover results with `on_wishlist` |
| medialab-contracts | `DiscoverItem`, `DiscoverResponse`, `Genre`, `GenresResponse`, `WishlistItem`, `WishlistResponse`, TMDB image base URL and poster size constants |
| medialab-web | `/discover` page (poster grid) and `/wishlist` page |
| medialab-bot | `/popular` and `/wishlist` commands |

### TMDB sources (torrent-downloader)

| Request | TMDB endpoint |
|---|---|
| no genre | `trending/{movie\|tv}/week` |
| genre | `discover/{movie\|tv}?with_genres=<id>&sort_by=popularity.desc&vote_count.gte=<DISCOVER_MIN_VOTES>` |
| genre list | `genre/{movie\|tv}/list` |

All calls pass `language=target_language` like the existing search. TMDB
`tv` maps to contracts `MediaType.SHOW` inside the downloader, so every
consumer sees `movie` / `show` only.

Results are cached in the existing `diskcache` with `app_cache.get/set`
(not `memoize`, whose `expire` is fixed at import) so the TTL runtime setting
applies on the next write. Cache key: `(endpoint, media_type, genre, page,
language)`. `DELETE /cache` keeps clearing everything, discover included.

### Endpoints

Downloader (internal, API-key protected like the rest):

| Method | Path | Response |
|---|---|---|
| GET | `/discover/{media_type}?genre=&page=` | `DiscoverResponse` |
| GET | `/discover/{media_type}/genres` | `GenresResponse` |

Orchestrator gateway:

| Method | Path | Behaviour |
|---|---|---|
| GET | `/discover/{media_type}?genre=&page=` | proxy, then set `on_wishlist` per item from the wishlist table |
| GET | `/discover/{media_type}/genres` | proxy |
| GET | `/wishlist?media_type=` | all items, newest first |
| PUT | `/wishlist/{media_type}/{tmdb_id}` | body: title, year, poster_path, overview; idempotent upsert, 200 either way |
| DELETE | `/wishlist/{media_type}/{tmdb_id}` | idempotent, 204 even when absent |

### Models (contracts)

- `DiscoverItem`: `tmdb_id`, `media_type: MediaType`, `title`, `year: str | None`,
  `overview`, `vote_average`, `poster_path: str | None`, `on_wishlist: bool = False`.
- `DiscoverResponse`: `items`, `page`, `total_pages`, `cached_at`.
- `Genre`: `id`, `name`. `GenresResponse`: `genres`.
- `WishlistItem`: `tmdb_id`, `media_type`, `title`, `year`, `poster_path`,
  `overview`, `added_at`. `WishlistResponse`: `items`.
- `TMDB_IMAGE_BASE_URL`, `PosterSize` enum (grid and thumbnail sizes).

### Wishlist storage (orchestrator)

New table `wishlist_item` in the existing SQLite file, created with
`CREATE TABLE IF NOT EXISTS` at startup beside `pipeline_job`, primary key
`(media_type, tmdb_id)`. A small `WishlistStore` next to `JobStore`, same
connection and locking pattern. Title, year, poster and overview are stored
at add time so listing the wishlist never calls TMDB.

### Web

- Nav gains `Discover` and `Wishlist`.
- `/discover`: Movies / Shows toggle, genre `<select>` (from the genres
  route), poster grid of one TMDB page (20), `More` loads the next page with
  HTMX. Posters are `<img loading="lazy">` from the TMDB image CDN; a title
  with no poster shows a text card.
- Clicking a poster opens a detail card (overview, rating) with two actions:
  - **Download**: loads the existing search partials into a `#stage` on the
    same page (`/partials/search/torrents` for a movie,
    `/partials/search/scope` for a show). No new search logic.
  - **Wishlist / Remove from wishlist**: `hx-put` / `hx-delete`, swaps the
    button.
- `/wishlist`: the same grid over the wishlist, each card with Download and
  Remove.
- Grid is responsive: `repeat(auto-fill, minmax(<poster width>, 1fr))`, two
  columns on a phone.

### Bot

- `/popular type:<movie|show> genre:<autocomplete, optional>`: ephemeral
  embed listing the top `select_max_results` titles (`title (year) - rating`)
  and a select menu. Choosing a title shows its embed with the poster as a
  thumbnail and two buttons, Download (reuses the show scope menus and
  `run_torrent_search`) and Wishlist / Remove.
- `/wishlist`: list with a select menu; the chosen item offers Download and
  Remove.
- Genre autocomplete reads the cached genre list for the chosen type.
- Views keep state in memory like `TmdbSelectMenu`; no persistent views.

### Settings

New downloader runtime setting `discover_cache_seconds`, INT, default one
day, range one hour to seven days, applies on the next cache write.

## Decisions

1. **TMDB stays in torrent-downloader.** Rejected: moving TMDB to the
   orchestrator. It would duplicate the key and the cache, and the move is its
   own refactor; the rename (#25) is the natural point to revisit.
2. **No genre uses `trending/week`; a genre uses `discover` by popularity
   with a minimum vote count.** Rejected: `discover` for both, because
   unfiltered TV popularity is dominated by talk shows, news and soaps.
   Rejected: `{type}/popular`, which cannot filter by genre, so the list would
   change source anyway.
3. **Orchestrator annotates `on_wishlist`.** Rejected: each UI fetching both
   lists and joining them. That is logic in the UI layer, done twice.
4. **Wishlist is a table in the orchestrator's SQLite file.** Rejected: a JSON
   file, which needs its own locking; the downloader, which should not own
   user state.
5. **Posters hotlink the TMDB image CDN.** Rejected: proxying through the
   stack, which costs host bandwidth and cache space for no benefit. The
   browser contacting TMDB directly is acceptable.
6. **Download reuses the existing search partials and bot views.** Rejected:
   a new "download by tmdb_id" path; the torrent step already takes a TMDB id.
7. **One shared wishlist.** Rejected: per-user, since there is one login and
   Discord users are not otherwise tracked.

## Open questions

1. When a job for a wishlisted title reaches `DONE`, remove it from the
   wishlist automatically, or leave it and show a "downloaded" badge?
   Proposed: remove automatically.
2. Should the web grid hide titles already in Jellyfin? Proposed: not in
   this spec (non-goal), revisit with a follow-up issue.
3. Should `Discover` replace `Search` as the web home page? Proposed: no,
   the jobs page stays home.

## Test plan

- **medialab-contracts**: model round-trips; `MediaType` values on
  `DiscoverItem`; poster URL helper builds `base + size + path`.
- **torrent-downloader**: no genre calls `trending`, genre calls `discover`
  with `with_genres` and the vote floor; `tv` is mapped to `show`; a second
  call within the TTL does not hit TMDB; the TTL comes from the runtime
  setting at write time; `DELETE /cache` clears discover entries. TMDB mocked
  at the service function boundary.
- **medialab-orchestrator**: `WishlistStore` add is idempotent, remove of an
  absent item is a no-op, list is newest first; table creation on an existing
  DB leaves `pipeline_job` intact; discover route sets `on_wishlist` only on
  matching `(media_type, tmdb_id)`; PUT/DELETE status codes.
- **medialab-web**: `/discover` renders posters and a text card when
  `poster_path` is null; genre select lists genres; Wishlist button swaps to
  Remove; Download on a movie targets the torrents partial and on a show the
  scope partial; `/wishlist` lists and removes.
- **medialab-bot**: `/popular` passes type and genre to the client; genre
  autocomplete filters by typed text; selecting a title shows both buttons;
  Wishlist button calls PUT then flips to Remove; `/wishlist` Remove calls
  DELETE. Client class mocked.

## Rollout

1. medialab-contracts PR and release; consumers bump the tag pin.
2. torrent-downloader PR (discover routes, setting).
3. medialab-orchestrator PR (wishlist table and routes, discover proxy).
   The table is created on first start; no manual migration.
4. medialab-web and medialab-bot PRs, in either order.
5. Release each, bump root pins, redeploy. No host step.
