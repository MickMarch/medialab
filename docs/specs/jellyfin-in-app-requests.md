# Spec: request titles from inside Jellyfin clients

Status: Approved
Issue: MickMarch/medialab#142

## Problem

Requesting a title needs medialab-web or the Discord bot. Household members
watch in Jellyfin (web, Findroid, Swiftfin, Android TV) and never open either.
Jellyfin plugins can only extend jellyfin-web; native clients ignore plugin
UI, so a "Request" page inside Jellyfin reaches the browser only.

What every client does render: libraries of items with posters, and a
favorite (heart) toggle per item. JellyBridge proves the pattern: a library of
placeholder items where favoriting one files a request.

## Goal and non-goals

Goal: a **Discover** library in Jellyfin, filled with placeholder items for
popular titles that are already out at home, recommendations based on what
users favorite in the real library, and watchlist entries, none of which are
in the real library yet. An automatic pick never takes a cam or screener.
Favoriting a placeholder in any client files a request: the orchestrator runs
the automatic pick and submits the download with no further step. The
placeholder shows request state in its title and disappears once the real
item is in the library. Works with no Jellyfin plugin and no client changes.

Non-goals: free-form search inside native clients (Jellyfin search covers the
library only; search stays in web and the bot); choosing a torrent
interactively; per-user approval queues; a C# plugin in the first version
(see Decisions); choosing a follow start point from Jellyfin (a series
request always follows `new_only`; other start points stay in web).

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `JellyfinRequestEvent`, `PlaceholderState` enum, placeholder marker constants, the `DISCOVER_DIR` path contract entry |
| torrent-downloader | extending the pick rule to movie scope and rejecting pre-release captures (see Pick rule); the released-only discover filter and TMDB recommendations (see Discover sources) |
| medialab-jellyfin | writing and removing placeholder folders; reading per-user favorites, in the Discover libraries and in the real libraries; parsing the Jellyfin webhook payload |
| medialab-orchestrator | which titles get placeholders; the request flow (pick, submit, watchlist link); the favorites poll; placeholder state updates; allowed-user check |
| medialab-web | nothing new beyond a settings entry |
| medialab-bot | nothing |

### Placeholder library

A directory `DISCOVER_DIR`, declared as a path contract (decision 0001) with
a container path and a host path like the media directories, bind-mounted
into medialab-jellyfin and added to
Jellyfin as its own library ("Discover", one for movies, one for shows) with
`POST /library/paths` at setup. One folder per title, named by the existing
naming rules plus the TMDB id tag so Jellyfin matches metadata by id:

```
Discover Movies/<Title> (<Year>) [tmdbid-<id>]/
    movie.nfo          title, tmdb id, state suffix
    <Title> (<Year>).mp4   copy of the placeholder clip
Discover Shows/<Title> (<Year>) [tmdbid-<id>]/
    tvshow.nfo
    Season 01/<Title> S01E01.mp4
```

Jellyfin fetches posters, logos and overview from TMDB by the id, so no art
is written. Jellyfin will not create an item without a playable file; each
placeholder carries a copy of a bundled clip (8 seconds, about 26 KB) that
says "Not downloaded yet - tap the heart to request", which turns an
accidental play into an instruction.

### Discover sources

Trending is the wrong source: it is led by titles in theaters or days past
release, where the only torrents are cams. Every source below is limited to
titles that are out at home, so a good release plausibly exists.

| Source | What | Size |
|---|---|---|
| Popular, released | TMDB `discover/movie` with `with_release_type=4\|5` (digital or physical) and `release_date.lte=<today>`; `sort_by=popularity.desc`; shows from trending this week minus any not yet aired (popularity alone is led by decades-old procedurals, checked live) | one page (20) per type |
| Recommendations | TMDB `{movie\|tv}/{id}/recommendations` for each title any allowed user has favorited in the real Movies or Shows libraries; same released filter applied per result (movie: release dates include type 4 or 5 before today; show: first air date before today) | top `discover_recommendations_per_title` per favorite, default 5 |
| Watchlist | every saved and followed entry, including every request (each request is a watchlist entry, so a requested title keeps its placeholder until it lands) | all |

Desired set = union of the three, deduplicated by `(media_type, tmdb_id)`,
minus TMDB ids already in the real library (existing `/library/tmdb-ids`).

torrent-downloader adds a `released=true` flag to `GET /discover/{media_type}`
and `GET /discover/{media_type}/recommendations/{tmdb_id}`, both cached like
the existing discover lists. Real-library favorites come from the same
per-user favorites reader as requests, filtered to the real libraries instead
of Discover.

The orchestrator reconciles on a schedule (`discover_refresh_minutes`):
medialab-jellyfin adds missing folders, removes stale ones, then triggers one
scan of the Discover libraries. A placeholder with a non-`available` state is
never removed by reconcile, whatever its source does.

### Request detection

Two paths, per decision 0003 (webhook fast path, poll safety net):

1. **Webhook.** The official Jellyfin Webhook plugin sends `UserDataSaved`
   to `POST /jellyfin/events` on the orchestrator with a shared secret
   header. Events for items outside the Discover libraries, or where
   `IsFavorite` is false, are ignored.
2. **Poll.** Every `discover_poll_seconds`, medialab-jellyfin lists
   `GET /Users/{id}/Items?Filters=IsFavorite&ParentId=<discover>` for each
   allowed user. New favorites become requests. Works with no plugin at all.

A favorite is a request once. The orchestrator stores `(media_type, tmdb_id)`
with the requesting Jellyfin user; repeat favorites, or the same title from a
second user, attach to the existing request.

Unfavoriting cancels a request that has not been submitted to the torrent
client (state `REQUESTED`, `picking` or `NO_CANDIDATE`): the request and its
watchlist entry are dropped and the placeholder returns to `available`.
After submission an unfavorite is ignored; the download is deleted through
web or the bot as today. A request with several users cancels only when the
last one unfavorites.

### Request flow

```
favorite -> REQUESTED -> picking -> SUBMITTED (job id) -> DONE: placeholder removed
                           \-> NO_CANDIDATE: saved to watchlist, title shows "Not found yet"
```

- Movie: pick route with movie scope; submit through the existing pipeline.
- Show: pick route with season scope for every aired season (specials
  excluded), one job per season, then the show becomes a `following` watchlist
  entry with start `new_only`, so future episodes arrive through the existing
  follow poll. A season with no candidate is left for the watchlist retry;
  per-episode fallback inside a season is not attempted.
- A movie request upserts a `saved` watchlist entry, so it is visible in web
  and the bot and survives a failed pick.
- `NO_CANDIDATE` items are retried by the watchlist's existing schedule.

### Pick rule

The automatic pick (`GET /search/torrents/pick`, watchlist spec) already
covers episode scope and season scope (`episode` unset picks an exact
single-season pack via `is_exact_season_pack`). It gains movie scope:
`media_type=movie`, no season or episode, keeping only releases that parse
with no season or episode. Same rule otherwise: resolution bucket with
fallback, `follow_minimum_seeders` floor, most seeders then largest file.

Every automatic pick (movie, season, episode, so follows too) rejects
pre-release captures: releases whose PTN quality is Cam, Telesync, Telecine
or Screener (HDCAM, HDTS, TS, PDVD, TC, DVDSCR). A cam named `HDCAM 1080p`
otherwise sits in the 1080p bucket and wins on seeders. Manual search in web
and the bot is unchanged; a cam is only ever chosen by hand.

### State feedback

`PlaceholderState`: `available`, `requested`, `downloading`, `not_found`.
The state is written as a title suffix in the `.nfo` (for example
`Dune (2021) - Requested`) and the item is refreshed. Native clients show the
title, so this is the only feedback channel that reaches all of them. The
Discord notice already sent on submit is unchanged.

### Access

`jellyfin_request_users`: runtime setting listing Jellyfin user ids allowed
to request. Empty means nobody, so installing the feature grants nothing until
set. Favorites from other users are ignored and logged.

### Host steps

- Add the two Discover libraries (setup CLI, `POST /library/paths`).
- Per user, exclude Discover from "Continue Watching" and "Latest" (Jellyfin
  Home settings). Documented in `docs/host-setup.md`.
- Optional: install the Jellyfin Webhook plugin and point `UserDataSaved` at
  the orchestrator.

### Secrets

`JELLYFIN_WEBHOOK_SECRET`: shared header value between the Webhook plugin and
the orchestrator. Added to `.env.example` and `docs/secrets.md`.

## Decisions

1. **Placeholder library, not web UI injection.** Rejected: a jellyfin-web
   request page (seerr-bridge style). It reaches the browser only, breaks on
   Jellyfin web updates, and the target users are on native clients.
2. **Favorite means request.** Rejected: play-to-request (a `.strm` URL hitting a
   medialab URL). Clients prefetch and retry streams, so a play is not a
   reliable single intent, and an accidental play would download.
3. **No C# plugin in the first version.** The official Webhook plugin plus a
   poll covers detection. Rejected: a custom plugin hooking
   `IUserDataManager.UserDataSaved`; it adds a .NET build, a plugin repo and
   Jellyfin version coupling for a few seconds of latency. Revisit if the
   placeholder files need replacing with virtual items.
4. **Placeholders are real folders on disk.** Rejected: a Jellyfin Channel
   plugin with virtual items. Channels need C#, and client support for
   favoriting channel items is uneven.
5. **Allowed users are opt-in.** Rejected: any Jellyfin user may request. A
   Jellyfin account would silently gain the power to start torrent downloads.
6. **Every request is also a watchlist entry.** Rejected: a separate request
   table only. The watchlist already has the retry schedule, the UI, and the
   removal on `DONE`.

7. **A series request downloads every aired season and follows `new_only`.**
   Rejected: season 1 only or the latest season only, which leave the user
   to finish the request in web, the flow this feature exists to avoid.
   Rejected: no follow, which makes a show request stale the next week.
8. **`DISCOVER_DIR` is a path contract.** Rejected: nesting it under the
   media root, which mixes placeholders into the real libraries' scan paths
   and risks Jellyfin matching a placeholder as a real item.
9. **Unfavorite cancels only before submission.** Rejected: never cancelling,
   which turns a mis-tap into a download. Rejected: cancelling a running
   download, which lets a heart toggle delete data; deletes stay explicit.
10. **The pick rule extension lives in this spec.** Rejected: a separate
    spec; this feature is its only consumer and the change is one scope
    parameter on an existing route.

11. **Placeholders render and favorite in native clients (spike).** Two
    folders (one movie, one show, `.nfo` + clip) in two new libraries
    outside the media root. Jellyfin matched both by TMDB id, fetched
    posters and logos, kept the `.nfo` title with its state suffix over the
    TMDB title, and created the stub episode with real episode metadata. A
    heart tapped in a client appeared in
    `GET /Users/{id}/Items?Filters=IsFavorite`. Rejected: a `.strm` holding
    the clip's local host path; Jellyfin treated the `.strm` itself as the
    media (container `strm`, no streams) and nothing played. A real file
    copy probes and plays, and swapping the file kept the item id and the
    favorite.

12. **Popular-and-released, not trending.** Rejected: TMDB trending, which
    is led by titles in theaters with only cam releases available.
13. **Recommendations come from favorites in the real library.** Rejected:
    TMDB `/similar`, which matches on keywords and genres and returns weaker
    lists than `/recommendations`, which is built from viewing behaviour.
    Rejected: recommendations from watch history, which includes titles a
    user disliked; a heart is an explicit signal.
14. **Automatic picks never take a cam or screener.** Rejected: a
    resolution-only rule, which picked `HDCAM 1080p` on seeders. Manual search
    keeps them so a user can still choose one deliberately.

## Open questions

None.

## Test plan

- **medialab-contracts**: `JellyfinRequestEvent` parses a real Webhook plugin
  `UserDataSaved` payload; `PlaceholderState` round-trips.
- **torrent-downloader**: pick rule returns one movie release for movie
  scope, rejects TV-named releases, rejects cam, telesync, telecine and
  screener releases in every scope, honours the seeder floor and bucket
  fallback, 404 `NO_CANDIDATE` otherwise; `released=true` passes the release
  type and date filters to TMDB; recommendations drop unreleased results;
  both cached.
- **medialab-jellyfin**: placeholder writer creates the folder layout and
  `.nfo` with the tmdb id; remove is idempotent; state suffix rewrite; the
  favorites reader filters to the Discover libraries or to the real
  libraries. Filesystem in
  `tmp_path`, Jellyfin mocked at the client class.
- **medialab-orchestrator**: reconcile computes the desired set (popular
  released plus recommendations for real-library favorites plus watchlist,
  deduplicated, minus library) and never removes a non-`available`
  placeholder; a favorite from an allowed user files one
  request; a duplicate attaches; a disallowed user is ignored; webhook rejects
  a wrong secret; `NO_CANDIDATE` lands on the watchlist; `DONE` removes the
  placeholder; poll and webhook for the same favorite file one request; a
  series request files one job per aired season and creates a `new_only`
  follow; unfavorite before submit cancels and restores `available`,
  after submit is ignored, and with two requesters cancels only on the last.

## Rollout

1. medialab-contracts PR (models, constants), release.
2. torrent-downloader PRs: pick movie scope, then cam rejection (both
   shipped); released filter and recommendations, release.
3. medialab-jellyfin PR (placeholder writer, favorites reader, clip), release.
4. medialab-orchestrator PR (reconcile, request flow, webhook, poll), release.
5. medialab-setup: create Discover libraries; `docs/host-setup.md` and
   `docs/secrets.md` updated in the root repo.
