# Spec: season packs for the complete seasons of a followed show

Status: Approved
Issue: MickMarch/medialab#104

## Problem

Following a show from a chosen episode submits every wanted episode as its
own search and its own torrent (`services/follow.py`, `_submit_wanted`).
For a show with nine finished seasons that is dozens of searches, dozens of
jobs and dozens of Discord notices, throttled to a few per tick, where a
handful of season packs would fetch the same episodes in one job each.
Packs are also better seeded than old single episodes.

The pipeline already handles a pack: a season-scoped job
(`season` set, `episode` unset) places every video file it contains
(`services/rename.py` parses season and episode per file) and
`services/shows.py` already treats such a job as queued for every episode
of that season. Only the follow poll and the pick rule are per episode.

## Goal and non-goals

Goal: when a follow has wanted episodes in a season that has finished
airing, the poll searches for that season's pack first, picks one by the
same rules it uses for an episode, and submits it as one job; this includes
the season the start point sits in (following from S03E04 fetches the S03
pack). The season still airing keeps the episode-by-episode path. When no
pack qualifies, nothing is fetched for that season; the user is told, on
the Watchlist and by Discord notice, and chooses per season: retry the pack
with a longer timeout, retry with fewer seeders, or fall back to episode by
episode.

Non-goals: multi-season or complete-series packs (a wrong parse would place
the wrong season); upgrading episodes already in the library; a pack for
a season where any episode is already in the library, queued or submitted
(the pack would duplicate it); making the decision from Discord (stateful
and multi-step, web-only per the UI scope rule); any change to how a pack
is renamed and placed.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `SeasonFollowMode`, `SeasonFollowState`, `SeasonDecisionRequest` |
| torrent-downloader | the pick rule for a season pack and the per-request timeout on `/search/torrents/pick` |
| medialab-orchestrator | per-season follow state, the pack-first plan in the poll, the decision endpoint, the not-found notice, the new settings |
| medialab-web | the per-season state and decision buttons on the Following card and the show page |
| medialab-bot | unchanged (the notice arrives through the existing webhook) |

### Vocabulary

- **Complete season**: every episode TMDB lists for the season has an air
  date at least `follow_delay_hours` ago. Specials (season 0) are never
  considered.
- **Pack-eligible season**: a complete season at or after the follow's
  start point in which no episode is in the library, queued, or recorded
  in `follow_submission`. A season with any of those falls back to
  episodes, since a pack would re-download them.
- **Season mode** (`SeasonFollowMode`): how the poll treats a season.

| Mode | Meaning |
|---|---|
| `pack` | default for a pack-eligible season; the poll searches the pack with the standard pack profile |
| `pack_not_found` | the pack search found nothing; the poll leaves the season alone until the user decides |
| `pack_retry_timeout` | user asked for one more pack attempt with the long timeout |
| `pack_retry_seeders` | user asked for one more pack attempt with the low seeder floor |
| `episodes` | user chose episode by episode; the poll treats the season as it does today |

A season with no row is in `pack` mode when pack-eligible and otherwise
takes the episode path with no state at all; rows are created only when
something happens.

### torrent-downloader

`GET /search/torrents/pick`:

- `episode` becomes optional. With `season` only, the scope is the season
  (already a valid `TorrentSearchScope`) and the pick rule is
  `is_exact_season_pack(name, season)`: PTN parses exactly that one season
  and no episode. Multi-season and complete-series names fail, as do
  single episodes. Everything else in `pick_best` (seeder floor, resolution
  bucket fallback, most seeded then largest) is unchanged.
- New optional `timeout_seconds` (bounded by the setting's `min` and `max`)
  overrides `search_timeout_seconds` for this one search, so the pack
  search can wait longer without changing the global setting.

### orchestrator

**Settings** (`core/config.py`, exposed through the runtime settings like
the other follow knobs):

| Key | Default | Used for |
|---|---|---|
| `follow_pack_minimum_seeders` | 20 | the standard pack profile (packs seed less than new episodes) |
| `follow_pack_timeout_seconds` | 30 | the standard pack profile |
| `follow_pack_retry_timeout_seconds` | 90 | `pack_retry_timeout` |
| `follow_pack_retry_minimum_seeders` | 5 | `pack_retry_seeders` |

**Store**: table `follow_season (tmdb_id, season, mode, attempts,
last_tried_at, job_id)`, primary key `(tmdb_id, season)`. `job_id` is the
pack job once submitted. Unfollowing a show deletes its rows.

**Poll** (`check_show`), replacing the flat episode loop with a plan:

1. Compute the wanted episodes as today.
2. Group them by season. For each season, in air order:
   - If the season is pack-eligible and its mode is `pack`,
     `pack_retry_timeout` or `pack_retry_seeders`: call the downloader pick
     with `season` only, the follow's resolution, and the profile for the
     mode. Found: submit one `DownloadRequest` with `season` set and
     `episode` unset, record a `follow_submission` for every episode of
     that season with the new job id, set the row to `pack` with `job_id`,
     post the existing follow notice with the season code (`S03`). Not
     found: set the row to `pack_not_found`, bump `attempts`, stamp
     `last_tried_at`, post a pack-not-found notice ("Season 3 of Example
     Show: no season pack found; choose how to continue on the Watchlist"),
     and skip the season this tick.
   - If the mode is `pack_not_found`: skip the season.
   - Otherwise (`episodes`, or not pack-eligible): the per-episode path as
     today.
3. A pack counts as one submission against
   `follow_max_submissions_per_tick`.

A retry mode is consumed by the attempt: success leaves `pack` with the job
id, failure returns the row to `pack_not_found`.

**Endpoints**

| Method | Path | Does |
|---|---|---|
| GET | `/watchlist/show/{tmdb_id}/episodes` | the response gains `seasons_follow: list[SeasonFollowState]`, one per season that has a row |
| POST | `/watchlist/show/{tmdb_id}/seasons/{season}/decision` | body `SeasonDecisionRequest {mode}`, `mode` one of `pack_retry_timeout`, `pack_retry_seeders`, `episodes`, or `pack` (try the standard profile again); `409` unless the row is `pack_not_found`; returns the updated `SeasonFollowState`; the follow is checked on the next tick, or at once through the existing Check now |

`SeasonFollowState`: `season`, `mode`, `attempts`, `last_tried_at`,
`job_id`.

**Deletion and redo** need no change: `ignore_submission_for_job` and
`repoint_submission` already act on every `follow_submission` row carrying
the job id, so deleting a pack ignores the whole season and redoing it
repoints the whole season. Retry on one episode clears one row, which makes
the season no longer pack-eligible, so that episode is fetched alone.

### medialab-web

- The Following card's season rows and the show page's season rows show
  the season state when a row exists: a `Pack queued` badge linking to the
  job, or a `Season pack not found` notice with three buttons: `Retry,
  longer search`, `Retry, fewer seeders`, `Episode by episode`. Each posts
  the decision and re-renders the season row. A mode already chosen shows
  as a badge (`Retrying`, `Episode by episode`) until the next tick.
- The episode list already shows `Submitted` per episode; a submitted pack
  marks every episode of the season, which is the intended reading.
- Settings page: the four new keys appear through the existing runtime
  settings listing.

### medialab-bot

Unchanged. The pack-not-found notice is a Discord message pointing at the
web Watchlist.

## Decisions

1. **Pack only for a season with nothing fetched yet.** Rejected: a pack
   whenever most of the season is missing. Placing a pack over episodes
   already in the library duplicates files Jellyfin then lists twice, and
   deciding "most" is a judgment call the user did not ask for.
2. **Single-season packs only.** Rejected: complete-series packs. PTN's
   parse of multi-season names is unreliable and a wrong season number
   misfiles a whole series; nine single packs are still nine jobs instead
   of ninety.
3. **Stop and ask when the pack is missing, rather than falling back to
   episodes automatically.** The user asked for exactly this: a quiet
   fallback would fetch twenty single episodes overnight for a season a
   lower seeder floor would have found as one pack.
4. **Three explicit choices, each one attempt.** Rejected: a single "try
   harder" that relaxes both knobs at once. The two relaxations fail for
   different reasons (slow trackers versus rare content) and the user
   should not have to accept both to get one. A choice is consumed by the
   attempt so a missing pack cannot loop forever.
5. **Per-request timeout on the pick route, not a second global setting
   consumed by the downloader.** Rejected: raising `search_timeout_seconds`
   for everyone. Manual searches should stay fast.
6. **A pack is one submission against the tick cap.** Rejected: counting
   its episodes. The cap exists to throttle tracker load and qBittorrent
   adds, both of which a pack costs once.
7. **Rows only when something happens.** Rejected: materialising a row per
   season on follow. Seasons that take the episode path have nothing to
   record, and the start point can change the eligible set.
8. **Web only for the decision; Discord gets the notice.** The UI scope
   rule; the choice is per season and stateful.

9. **No automatic retry of a missing pack.** Rejected: trying the standard
   profile again every few days in case the pack appears. The user decides
   once per season, and Check now re-runs the chosen attempt at will.

## Open questions

None.

## Test plan

- **contracts**: `SeasonFollowMode` values; `SeasonDecisionRequest`
  rejects `pack_not_found`; `SeasonFollowState` round-trips.
- **torrent-downloader**: `is_exact_season_pack` accepts `S03`,
  `Season 3`, `S03.COMPLETE` and rejects `S03E04`, `S01-S03`,
  `Complete Series`; `pick_best` with `episode=None` uses it; the pick
  route accepts a season-only scope and `timeout_seconds` within bounds,
  422 outside; the override reaches the search and the global setting is
  untouched.
- **orchestrator**: pack-eligibility (complete, at or after start, nothing
  in library, queued or submitted; specials excluded; the start season
  with a mid-season start is eligible); the poll submits one season job
  and records a submission for every episode of the season; a missing pack
  sets `pack_not_found`, posts the notice, and the season is skipped on
  the next tick while others proceed; the airing season still goes episode
  by episode; each retry mode uses its profile and is consumed; `episodes`
  mode takes the episode path; the decision endpoint 409s unless
  `pack_not_found`; unfollow clears rows; deleting a pack job ignores every
  episode of the season; the tick cap counts a pack once; the episodes
  response carries `seasons_follow`; the four settings are listed.
- **web**: season row renders the not-found notice with three buttons that
  post the decision; `Pack queued` links to the job; a chosen mode renders
  as a badge; the client posts the expected body (mocked at the client
  boundary).

## Rollout

1. contracts PR and release.
2. torrent-downloader PR and release.
3. orchestrator PR and release (adds the table on startup like the others;
   add the four settings to `.env.example` and `docs/secrets.md` is not
   affected).
4. web PR and release. Redeploy. No host step.
