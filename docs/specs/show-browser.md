# Spec: browse a show's seasons and episodes, find torrents at every level

Status: Draft
Issue: MickMarch/medialab#91

## Problem

A show is a single card. Its seasons and episodes, what each is about, when
each aired, and which ones are already in Jellyfin are invisible. Searching
torrents for a season or an episode means going through the scope step every
time, and there is no way to search "this episode" from anything that shows
episodes, because nothing does. The watchlist (#24) needs an episode view
for its start picker and its per-episode flags.

## Goal and non-goals

Goal: in the web UI, open a show and walk it: series, seasons, episodes. Each
episode shows its TMDB details (title, air date, overview, still image). Each
level shows what is in the library and what is queued. A **Find torrents**
button at every level enters the existing torrent step with that scope:
series root searches the whole series, a season searches that season, an
episode searches that episode.

Non-goals: the same browser in the bot (the bot keeps its select-menu scope
picker, see the workspace rule on bot scope); episode playback or Jellyfin
deep links; cast, crew or ratings beyond what the episode object carries.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `Episode`, `Season`, `SeriesEpisodesResponse`, `LibraryEpisodesResponse`, `EpisodeState`, `ShowBrowseResponse`, `STILL_SIZE` |
| torrent-downloader | the series episode listing from TMDB, cached |
| medialab-jellyfin | episode presence per series by TMDB id |
| medialab-orchestrator | `GET /shows/{tmdb_id}`: episodes joined with library presence and queued jobs |
| medialab-web | the show page and its Find torrents buttons |

### Contracts

- `Episode`: `season`, `episode`, `title`, `air_date: date | None`,
  `overview`, `still_path: str | None`, `runtime_minutes: int | None`.
- `Season`: `season`, `name`, `episode_count`, `air_date: date | None`,
  `poster_path: str | None`, `overview`.
- `SeriesEpisodesResponse`: `tmdb_id`, `seasons: list[Season]`, `episodes:
  list[Episode]` (season 0 excluded from both), `next_episode: Episode |
  None`, `status: str` (TMDB show status, e.g. `Returning Series`,
  `Ended`).
- `LibraryEpisodesResponse`: `tmdb_id`, `episodes: list[EpisodeKey]` where
  `EpisodeKey` is `season`, `episode`.
- `EpisodeState`: `Episode` plus `aired: bool`, `in_library: bool`,
  `queued_job_id: str | None`.
- `ShowBrowseResponse`: `tmdb_id`, `title`, `year`, `poster_path`,
  `overview`, `status`, `seasons: list[Season]`, `episodes:
  list[EpisodeState]`, `next_episode: Episode | None`, `on_watchlist`,
  `in_library` (series level, as today).
- `STILL_SIZE = "w300"` beside `PosterSize`; `still_url()` mirrors
  `poster_url()`.

### torrent-downloader

| Method | Path | Behaviour |
|---|---|---|
| GET | `/search/tmdb/show/{id}/episodes` | `tv/{id}` for `seasons`, `status`, `next_episode_to_air`; then `tv/{id}/season/{n}` for every season except 0, flattened; cached with `app_cache.get/set`, TTL `discover_cache_seconds` (a season list changes rarely); `DELETE /cache` clears it |

TMDB calls stay in the downloader, the sole key holder. One call per season is
the TMDB shape; `append_to_response` takes at most 20 seasons per call and is
used when the show has 20 or fewer seasons, which is nearly all of them.

### medialab-jellyfin

| Method | Path | Behaviour |
|---|---|---|
| GET | `/library/episodes?tmdb_id=` | `/Items?IncludeItemTypes=Series&Fields=ProviderIds` filtered to the series with that TMDB id (reusing the id listing), then `/Items?ParentId=<series>&IncludeItemTypes=Episode&Recursive=true&Fields=ParentIndexNumber,IndexNumber`; returns `(season, episode)` keys; unknown series returns an empty list |

### orchestrator

| Method | Path | Behaviour |
|---|---|---|
| GET | `/shows/{tmdb_id}` | one downloader episodes call, one jellyfin episodes call (best effort, empty on failure), one store read of non-terminal jobs with this `tmdb_id`; returns `ShowBrowseResponse` |

`queued_job_id` is set when a non-terminal job exists whose scope covers the
episode. Job scope is not stored today: `pipeline_job` gains nullable
`season` and `episode` columns, written at `POST /download` from new optional
`DownloadRequest` fields `season` and `episode` (the web and bot already know
the scope they searched with). A whole-series job covers every episode; a
season job covers its season.

### medialab-web

- New page `GET /shows/{tmdb_id}` rendering the show header (poster, title,
  year, status, overview, badges), then the season list. Each season expands
  (HTMX partial) to its episodes: still, `S02E05 Title`, air date, overview
  (clamped), and badges **In Jellyfin**, **Queued**, or **Unaired**.
- **Find torrents** at three levels, all entering the existing
  `/partials/search/torrents` with the scope preset: series header (`season
  = all`), each season row, each episode row. The result renders in a
  `#stage` on the show page, as discover does.
- Entry points: the show's poster card in discover, search results and the
  watchlist gains **Browse**; the show title in a job row links here.
- Phone layout: season rows stack; stills hide below 400px.

### medialab-bot

Unchanged.

## Decisions

1. **Web only.** Rejected: a Discord tree of select menus. The bot is for
   remote downloading; multi-level browsing is a web job.
2. **Episodes joined in the orchestrator, one route.** Rejected: the web
   calling downloader and jellyfin routes and joining; that is business
   logic in the UI layer and would be repeated by the watchlist.
3. **Job scope stored as `season` and `episode` columns.** Rejected:
   parsing the release name with PTN on read; the scope the user chose is
   known at submit time and parsing is lossy for packs.
4. **Series-level cache TTL for episodes.** Rejected: the shorter search
   cache TTL; a season's episode list changes when TMDB adds the next
   episode, which is days apart. `Check now` paths that need fresh data can
   clear the cache.
5. **`append_to_response` for up to 20 seasons, per-season calls beyond.**
   Rejected: always per season; the common case is one round trip.

## Open questions

1. Should the show page be the click target of a show poster everywhere,
   with Download and Save moved into it, or a separate Browse button?
   Proposed: Browse button now; revisit once the watchlist ships.

## Test plan

- **contracts**: models round-trip; `still_url` mirrors `poster_url`.
- **torrent-downloader**: season 0 dropped; seasons and episodes flattened;
  `append_to_response` used at 20 seasons or fewer, per-season calls above;
  cached; TMDB mocked at the service boundary.
- **medialab-jellyfin**: unknown series returns empty; episodes keyed by
  `ParentIndexNumber` and `IndexNumber`; items without numbers skipped.
- **orchestrator**: `queued_job_id` set for an episode job, a season job
  (every episode of the season) and a series job (every episode); library
  failure yields `in_library` false with 200; `DownloadRequest` stores
  season and episode; existing callers without them still work.
- **web**: show page renders seasons; expanding a season lists episodes
  with the right badges; the three Find torrents buttons carry `all`, the
  season, and season plus episode; Browse appears on show cards only.

## Rollout

1. contracts PR and release.
2. torrent-downloader and medialab-jellyfin PRs, in either order.
3. orchestrator PR (`season` and `episode` columns are added by the existing
   `_ADDED_COLUMNS` mechanism; no manual migration).
4. web PR. No bot change.
5. Release each, bump root pins, redeploy. No host step.
