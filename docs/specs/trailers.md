# Spec: watch a trailer for a title or a season

Status: Approved
Issue: MickMarch/medialab#96

## Problem

Deciding whether to download a title means leaving medialab to look up a
trailer. TMDB already lists every title's and every season's videos with a
YouTube key, a type and an official flag.

## Goal and non-goals

Goal: a **Watch trailer** button on the discover and search detail card
(movie or show) and on each season row of the show page. Nothing is fetched
until it is pressed. Then the trailers and teasers are listed, official
first; picking one plays it in the standard embedded YouTube player. When
there is exactly one, it plays at once.

Non-goals: clips, featurettes and behind-the-scenes videos; non-YouTube
sites (Vimeo is rare on TMDB); trailers in the bot; caching video metadata
beyond the existing discover TTL; episode-level trailers (TMDB has none).

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-contracts | `Video`, `VideosResponse`, `VideoType`, `YOUTUBE_EMBED_BASE_URL` and `youtube_embed_url()` |
| torrent-downloader | the TMDB videos call, filtered and cached |
| medialab-orchestrator | proxy route |
| medialab-web | the button, the list partial and the player |

### Contracts

- `VideoType` enum: `trailer`, `teaser`.
- `Video`: `key` (YouTube id), `name`, `type: VideoType`, `official: bool`,
  `published_at: datetime | None`, `language: str`.
- `VideosResponse`: `videos: list[Video]`, official first, then trailers
  before teasers, then newest first.
- `YOUTUBE_EMBED_BASE_URL = "https://www.youtube-nocookie.com/embed"`;
  `youtube_embed_url(key)` builds the iframe source. The privacy-enhanced
  host sets no cookies until playback starts.

### torrent-downloader

| Method | Path | Behaviour |
|---|---|---|
| GET | `/search/tmdb/{movie\|show}/{id}/videos?season=` | `movie/{id}/videos`, `tv/{id}/videos`, or `tv/{id}/season/{n}/videos` when `season` is given (shows only; a season on a movie is 422); keeps `site == YouTube` and `type` in Trailer or Teaser; sorted as the contract says; cached with `app_cache.get/set` under the discover namespace, TTL `discover_cache_seconds`; `language=target_language` plus `include_video_language=<target>,en,null` so a non-English target still finds English trailers |

### orchestrator

| Method | Path | Behaviour |
|---|---|---|
| GET | `/search/tmdb/{media_type}/{id}/videos?season=` | proxy, relaying `TMDB_UNAVAILABLE` and `INVALID_INPUT` like discover |

### medialab-web

- **Button**: `Watch trailer` on the detail card (`partials/discover_detail.html`)
  and on each season `<summary>` row of the show page. It is an `hx-get` of
  `/partials/trailers?media_type=&tmdb_id=&season=` targeting a `#trailer`
  slot in the same card or season. No request before the click.
- **List partial**: one video -> render the player directly. Several ->
  a list of `name` with an `Official` badge and the type; each is an
  `hx-get` of the player partial for that key, swapping into the same slot.
  None -> "No trailer on TMDB". Downstream failure -> the existing error
  fragment.
- **Player partial**: a responsive 16:9 `<iframe>` from `youtube_embed_url`
  with `allow="autoplay; encrypted-media; picture-in-picture"`,
  `loading="lazy"`, `referrerpolicy="strict-origin-when-cross-origin"`,
  and a **Close** that empties the slot (stopping playback). Only one player
  open per page: opening another slot's player empties the others.
- Phone: the iframe fills the card width; no fixed pixel sizes.

### medialab-bot

Unchanged.

## Decisions

1. **Trailers and teasers only.** Rejected: everything grouped by type; The
   Last of Us season 2 has 24 videos and Dune 60, most of them clips.
2. **Play directly when there is one.** Rejected: always list; one extra
   click for the common case.
3. **Nothing loads before the click.** Rejected: fetching videos with the
   card; the TMDB call and the YouTube iframe are the heaviest things on
   the page and most cards are never played.
4. **youtube-nocookie embed.** Rejected: the standard `youtube.com/embed`
   host, which sets cookies on load.
5. **Filtering in the downloader, sorting in the contract's words.**
   Rejected: raw pass-through with the web filtering; the bot or another UI
   would repeat it.
6. **Web only.** The bot is for remote downloading; watching video belongs
   in the browser.

## Open questions

None.

## Test plan

- **contracts**: `Video` round-trip; `youtube_embed_url` builds
  `<base>/<key>`.
- **torrent-downloader**: keeps only YouTube trailers and teasers; official
  first, trailer before teaser, newest first; the season path is used when
  `season` is given; season on a movie is 422; cached; language params sent;
  TMDB mocked at the service boundary.
- **orchestrator**: proxy passes `season` through and relays 503.
- **web**: the button does not fetch on render; one video renders the
  iframe with the nocookie URL; several render the list with the Official
  badge; picking one renders the player; none renders the empty notice;
  season rows on the show page carry the season; failure shows the error
  fragment.

## Rollout

1. contracts PR and release.
2. torrent-downloader PR and release.
3. orchestrator PR and release.
4. web PR and release. Redeploy. No host step.
