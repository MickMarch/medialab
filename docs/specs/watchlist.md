# Spec: watchlist, saved titles and followed shows that auto-download new episodes

Status: Draft
Issue: MickMarch/medialab#24

## Problem

The wishlist (#81) is a bookmark. A show on it still needs someone to notice
that an episode aired, run the search, and pick a torrent, every week. The
data to do that automatically already exists: TMDB series details carry
`next_episode_to_air`, `last_episode_to_air` and the season list; the torrent
search already takes a season and episode scope; downloads already enter the
pipeline by TMDB id. Nothing joins them.

The original #24 planned RSS feed matching. That needs feed URLs per tracker,
its own matcher, and never knows what aired; TMDB does.

## Goal and non-goals

Goal: the wishlist becomes a **watchlist** with two kinds of entry. A
**saved** entry is today's behaviour, any title kept for later. A **followed**
entry is a show whose episodes medialab downloads by itself, from a start
point chosen when the follow is created: only episodes airing from now on,
from a chosen season and episode onward, or from the beginning. Aired
episodes not yet in Jellyfin and not already queued are searched on a
schedule; the best result by fixed rules is submitted with no human step, and
a Discord notice reports it. Single user, one shared list.

Non-goals: RSS or tracker feeds; following movies (a saved movie is enough);
per-user lists; upgrading an episode already in the library to a better
release; choosing among candidates interactively (a follow is automatic or it
is not a follow).

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `WatchlistKind`, `FollowStart`, `WatchlistItem`, `WatchlistAddRequest`, `FollowRequest`, `Episode`, `SeriesEpisodesResponse`, `LibraryEpisodesResponse`, `DEFAULT_FOLLOW_RESOLUTION` |
| torrent-downloader | aired-episode listing per series from TMDB; the automatic pick rule over its own search results |
| medialab-jellyfin | episode presence per series (season and episode numbers) |
| medialab-orchestrator | `watchlist_item` table (renamed from `wishlist_item`), follow state, the follow poll, auto-submit, the Discord notice hook |
| medialab-web | Watchlist page with Saved and Following tabs; the follow flow with the start picker |
| medialab-bot | `/watchlist`, Follow button with the start picker, follow notices |

### Vocabulary

- **Saved**: `kind = saved`. Any media type. Removed when a download for it
  reaches `DONE`, as today.
- **Following**: `kind = following`. Shows only. Never removed automatically;
  the user unfollows.
- **Start point** (`FollowStart`): `new_only` (episodes whose air date is on
  or after the follow date), `from` (a season and episode, inclusive), or
  `beginning` (season 1 episode 1). Stored on the follow. Specials (season 0)
  are never followed.
- **Wanted episode**: aired (air date on or before today, TMDB local date),
  on or after the start point, not in Jellyfin, not already the scope of a
  non-terminal job, not already recorded as submitted by this follow.

### Wire changes (contracts)

- `WatchlistKind` enum: `saved`, `following`.
- `FollowStart` model: `mode: new_only | from | beginning`, `season: int |
  None`, `episode: int | None`; `from` requires both.
- `WatchlistItem` replaces `WishlistItem`, adding `kind`, `follow: FollowState
  | None` where `FollowState` has `start: FollowStart`, `resolution: str`
  (`4K`, `1080p`, `720p`), `last_checked_at`, `last_submitted: str | None`
  (`S02E05`), `paused: bool`.
- `WatchlistAddRequest` replaces `WishlistAddRequest` (same fields).
- `FollowRequest`: `start: FollowStart`, `resolution: str =
  DEFAULT_FOLLOW_RESOLUTION` (`1080p`).
- `Episode`: `season`, `episode`, `air_date: date | None`, `title`.
- `SeriesEpisodesResponse`: `tmdb_id`, `episodes: list[Episode]` (all
  seasons except 0), `next_episode: Episode | None`.
- `LibraryEpisodesResponse`: `tmdb_id`, `episodes: list[tuple[int, int]]` as
  `(season, episode)` pairs.
- `DiscoverItem.on_wishlist` and search-result `on_wishlist` are renamed
  `on_watchlist`; a `watchlist_kind: WatchlistKind | None` is added so a badge
  can say Saved or Following.

### torrent-downloader

| Method | Path | Behaviour |
|---|---|---|
| GET | `/search/tmdb/show/{id}/episodes` | one `tv/{id}` call for the season list, then one `tv/{id}/season/{n}` call per season (except 0), flattened to `SeriesEpisodesResponse`; cached like discover, TTL `discover_cache_seconds`; `next_episode` from `next_episode_to_air` |
| GET | `/search/torrents/pick?query&season&episode&resolution=` | runs the normal episode search, then the pick rule; returns one `TorrentResult` or 404 `NO_CANDIDATE` |

Pick rule, in order: results in the episode scope only (no season packs,
no complete-series packs); audio filter as configured; resolution bucket
equal to the requested one, else the next lower bucket (`4K` -> `1080p` ->
`720p`), never `Other`; then highest seeders. Below `minimum_seeders`, no
candidate. The rule is a pure function over the grouped results so the web
and bot could show "what would be picked" later.

### medialab-jellyfin

| Method | Path | Behaviour |
|---|---|---|
| GET | `/library/episodes?tmdb_id=` | finds the Series by TMDB provider id, then `/Items?ParentId=<series>&IncludeItemTypes=Episode&Recursive=true&Fields=ParentIndexNumber,IndexNumber`; returns `(season, episode)` pairs; unknown series returns an empty list, not 404 |

### orchestrator

**Storage.** `wishlist_item` becomes `watchlist_item` at startup: `ALTER
TABLE ... RENAME`, guarded by `PRAGMA table_info`, then `ALTER TABLE ADD
COLUMN` for `kind TEXT NOT NULL DEFAULT 'saved'`, `follow_mode`,
`follow_season`, `follow_episode`, `follow_resolution`, `follow_paused
INTEGER NOT NULL DEFAULT 0`, `last_checked_at`, `last_submitted`, and
`followed_at`. A second table `follow_submission (tmdb_id, season, episode,
job_id, submitted_at)` with primary key `(tmdb_id, season, episode)` records
what a follow has already submitted, so a deleted or failed job is not
re-queued forever and a retry is deliberate.

**Routes.** All `/wishlist` routes are renamed `/watchlist` with the same
verbs, and:

| Method | Path | Behaviour |
|---|---|---|
| PUT | `/watchlist/show/{tmdb_id}/follow` | body `FollowRequest`; upserts the row with `kind = following`, stores the start and resolution; idempotent |
| DELETE | `/watchlist/show/{tmdb_id}/follow` | back to `kind = saved` (keeps the row), 204 |
| POST | `/watchlist/show/{tmdb_id}/follow/pause` and `/resume` | flips `paused` |
| POST | `/watchlist/show/{tmdb_id}/follow/check` | runs one follow check now; returns what was submitted |
| GET | `/watchlist/show/{tmdb_id}/episodes` | the wanted-episode view: every aired episode with `in_library`, `queued`, `submitted`, `wanted` flags, for the UIs |

`GET /watchlist?kind=` filters by kind.

**Follow poll.** A second loop beside the health poll, `services/follow.py`,
interval `follow_poll_interval_seconds` (runtime setting, default 6 hours, 0
pauses). One tick: for each unpaused follow, fetch the episode list and the
library episodes, compute wanted episodes, and for each in air order call the
downloader's pick route; on a candidate, submit through the same code path
as `POST /download` (a real job, release name from the result) and insert a
`follow_submission`; on `NO_CANDIDATE`, stop this show for the tick (older
first, so a missing early episode does not starve later ones next tick: the
tick tries every wanted episode, and only stops early on a downloader error).
Update `last_checked_at`. Per follow, at most `follow_max_submissions_per_tick`
(setting, default 3) submissions per tick so a `beginning` follow on a long
show does not flood qBittorrent. Failures of one follow never stop the sweep.

**Notice.** When a follow submits, the orchestrator posts to a Discord webhook
URL (`DISCORD_NOTIFY_WEBHOOK_URL`, optional; documented in `docs/secrets.md`)
with `Following <title>: submitted S02E05 (<release name>)`. No webhook, no
notice. The bot is not involved; a webhook is one HTTP call and works while
the bot is down.

**Existing behaviour.** `DONE` removes a `saved` row and never a `following`
row. The health poll and pipeline are unchanged; follow submissions are
ordinary jobs.

### medialab-web

- `/wishlist` becomes `/watchlist` (old path redirects) with tabs **Saved**
  and **Following**; nav label "Watchlist".
- On a show card (discover, search, watchlist): a **Follow** button beside
  Save. Follow opens a picker: "New episodes only", "From season N episode M"
  (reusing the season and episode selects from the search scope step, seeded
  from the episodes route), "From the beginning"; a resolution select
  defaulting to 1080p.
- A Following card shows the start point, resolution, last check, last
  submitted episode, and Pause / Resume / Check now / Unfollow. Expanding it
  lists episodes with their flags (the episodes route).
- Badges: **Saved** or **Following** replace "Wishlisted".

### medialab-bot

- `/wishlist` becomes `/watchlist [kind]`. The title card gains **Follow**
  (shows only): a select for the start mode, then the existing season and
  episode selects when "From" is chosen, then a resolution select.
- A followed title's card shows Pause / Resume / Check now / Unfollow.
- Markers: `saved` or `following` replace `wishlisted`.

### Settings

New orchestrator runtime settings: `follow_poll_interval_seconds` (INT, 0 to
one week, default 6 hours), `follow_max_submissions_per_tick` (INT, 1 to 20,
default 3). New orchestrator `.env` value `DISCORD_NOTIFY_WEBHOOK_URL`
(optional).

## Decisions

1. **TMDB air dates, not RSS.** Rejected: RSS feed matching. Feeds need per-
   tracker URLs, a matcher, and cannot tell that an episode exists until
   someone uploads it; TMDB tells us what aired, and the existing search
   finds it.
2. **Automatic pick by rule, no confirmation.** Rejected: posting candidates
   to Discord for a click; then a follow is a reminder, not automation.
   Rejected: auto with a fallback question; the rule already covers "nothing
   good yet" by waiting for the next tick.
3. **Pick rule lives in torrent-downloader.** Rejected: the orchestrator
   choosing from grouped results; the downloader owns search filtering and
   the resolution buckets, and a pure function there is testable against
   fixtures the search tests already have.
4. **Start point chosen at follow time.** Rejected: default to new episodes
   and edit later; the user's own case is "from this season on", which is
   the follow itself.
5. **Episode presence from Jellyfin, by series.** Rejected: trusting only
   medialab's own jobs; episodes added by hand would be downloaded again.
6. **One table, a `kind` column, rename in place.** Rejected: a separate
   `follow` table; a followed show is also a saved one, and one row per title
   keeps badges and lists simple. The rename is one guarded `ALTER TABLE`.
7. **`follow_submission` records what was tried.** Rejected: inferring from
   jobs; a deleted job would make the episode wanted again and loop.
8. **Cap per tick.** Rejected: unbounded; a `beginning` follow on a ten-
   season show would submit a hundred torrents at once.
9. **Discord webhook for notices, not the bot.** Rejected: the orchestrator
   calling the bot; the bot is a client of the orchestrator, not a service,
   and a webhook survives bot restarts.
10. **Following is shows only.** Rejected: following a movie until a release
    exists; the saved list plus discover covers it, and movie release timing
    on TMDB (theatrical vs digital) is unreliable for this.

11. **`new_only` includes the follow day.** Rejected: strictly later air
    dates; the user usually follows because of the episode airing today.
12. **The bot has a one-tap "Follow, new episodes only" shortcut** beside the
    full picker. Rejected: always the picker; the common case is one tap.
13. **Pick falls back one resolution bucket lower, never `Other`.** Rejected:
    exact only; having the episode beats waiting for a release that may not
    come.

## Open questions

None.

## Test plan

- **contracts**: `FollowStart` validation (`from` needs season and episode,
  `new_only` and `beginning` reject them); round trips; the rename of
  `on_wishlist` to `on_watchlist` with `watchlist_kind`.
- **torrent-downloader**: episodes route flattens seasons and drops season
  0; caches; `next_episode` mapped; pick rule: episode scope only, resolution
  exact then one lower, never `Other`, highest seeders, `NO_CANDIDATE` below
  the floor; TMDB and qBittorrent mocked at the service boundary.
- **medialab-jellyfin**: episodes route resolves the series by TMDB id,
  returns `(season, episode)` pairs, empty for an unknown series.
- **orchestrator**: migration renames the table and adds columns on an
  existing DB with rows intact, and is a no-op on a fresh DB; follow routes;
  wanted-episode computation across start modes, library, queued jobs and
  submissions; the tick submits in air order, caps per tick, records
  submissions, skips paused follows, survives one follow raising, and posts
  the notice only when a webhook URL is set; `DONE` leaves a following row;
  `check` runs one tick for one show.
- **web**: tabs filter by kind; Follow opens the picker; `from` posts season
  and episode; Following card shows state and actions; old `/wishlist`
  redirects; badges read Saved / Following.
- **bot**: `/watchlist` kinds; Follow select flow posts `FollowRequest`;
  Pause / Resume / Unfollow call the routes; markers.

## Rollout

1. contracts PR and release (breaking rename of wishlist models; consumers
   pin the new tag in their own PRs).
2. torrent-downloader and medialab-jellyfin PRs, in either order.
3. orchestrator PR: migration runs at first start; `.env.example` and
   `docs/secrets.md` gain the webhook URL.
4. web and bot PRs, in either order.
5. Release each, bump root pins, redeploy. Host step: create a Discord
   webhook in the target channel and set `DISCORD_NOTIFY_WEBHOOK_URL`
   (optional).
