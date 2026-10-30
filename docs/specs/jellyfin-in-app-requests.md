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
trending titles and watchlist entries that are not in the real library.
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
| torrent-downloader | extending the pick rule to movie and season scopes (see Pick rule) |
| medialab-jellyfin | writing and removing placeholder folders; reading per-user favorites inside the Discover library; parsing the Jellyfin webhook payload |
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

The orchestrator reconciles on a schedule (`discover_refresh_minutes`):
desired set = trending movies and shows (existing discover cache) plus
watchlist entries, minus TMDB ids already in the real library (existing
`/library/tmdb-ids`). medialab-jellyfin adds missing folders, removes stale
ones, then triggers one scan of the Discover libraries.

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

The automatic pick (`GET /search/torrents/pick`, watchlist spec) is episode
scope only. It gains movie scope (no season or episode) and season scope
(season, no episode). Same rule otherwise: resolution exact match on
`DEFAULT_FOLLOW_RESOLUTION`, `follow_minimum_seeders` floor, existing ranking.
Season scope accepts only results that pass the existing
`is_exact_season_pack` check; a single-episode result never satisfies a
season request.

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

## Open questions

None.

## Test plan

- **medialab-contracts**: `JellyfinRequestEvent` parses a real Webhook plugin
  `UserDataSaved` payload; `PlaceholderState` round-trips.
- **torrent-downloader**: pick rule returns one result for movie scope and
  season scope, honours the seeder floor, 404 `NO_CANDIDATE` otherwise;
  season scope rejects single-episode results.
- **medialab-jellyfin**: placeholder writer creates the folder layout and
  `.nfo` with the tmdb id; remove is idempotent; state suffix rewrite; the
  favorites reader filters to the Discover parent id. Filesystem in
  `tmp_path`, Jellyfin mocked at the client class.
- **medialab-orchestrator**: reconcile computes the desired set (trending
  plus watchlist minus library); a favorite from an allowed user files one
  request; a duplicate attaches; a disallowed user is ignored; webhook rejects
  a wrong secret; `NO_CANDIDATE` lands on the watchlist; `DONE` removes the
  placeholder; poll and webhook for the same favorite file one request; a
  series request files one job per aired season and creates a `new_only`
  follow; unfavorite before submit cancels and restores `available`,
  after submit is ignored, and with two requesters cancels only on the last.

## Rollout

1. medialab-contracts PR (models, constants), release.
2. torrent-downloader PR (pick scopes), release.
3. medialab-jellyfin PR (placeholder writer, favorites reader, clip), release.
4. medialab-orchestrator PR (reconcile, request flow, webhook, poll), release.
5. medialab-setup: create Discover libraries; `docs/host-setup.md` and
   `docs/secrets.md` updated in the root repo.
