# Spec: Pick resolution setting

Status: Approved
Issue: MickMarch/medialab#153

## Problem

A Jellyfin request picks at `DEFAULT_FOLLOW_RESOLUTION` (1080p), a constant
in code. Every automatic pick (follows and requests) also falls back to each
lower resolution when the preferred one has no candidate, so a user who wants
1080p or nothing cannot say so. The resolution list itself is written out
three times: torrent-downloader's `PICK_RESOLUTION_ORDER`, medialab-web's
`FOLLOW_RESOLUTIONS`, and now the orchestrator would need it as setting choices.

## Goal and non-goals

Goal: a runtime setting for the resolution a Jellyfin request picks at, and a
runtime switch that stops automatic picks from falling back to a lower
resolution. Both are set from the web settings page like every other tunable.

Non-goals: a per-follow fallback switch (follows already carry their own
resolution, picked in the web follow form); changing manual search, which
lists every resolution; changing the language filter or the pre-release
block.

## Design

| Repo | Change |
|---|---|
| medialab-contracts | `PICK_RESOLUTIONS = ("4K", "1080p", "720p")`, best first. `DEFAULT_FOLLOW_RESOLUTION` stays. |
| torrent-downloader | `PICK_RESOLUTION_ORDER` becomes the contracts tuple. New runtime setting `pick_resolution_fallback`, CHOICE `lower` (default, today's behaviour) or `none`. `pick_best` takes `fallback: bool`; with `none` it reads only the requested bucket. The pick endpoint reads the setting; no new query parameter. |
| medialab-orchestrator | New runtime setting `jellyfin_request_resolution`, CHOICE over `PICK_RESOLUTIONS`, default `DEFAULT_FOLLOW_RESOLUTION`. The movie pick uses it, and a show request follows at it. |
| medialab-web | `FOLLOW_RESOLUTIONS` is replaced by the contracts tuple. |

With `none`, a request whose resolution has no candidate goes to
`not_found` and is retried every `jellyfin_request_retry_hours`, as it is
today when nothing qualifies at all; a follow leaves the episode wanted for
the next poll.

## Decisions

1. **The fallback switch lives in torrent-downloader and covers every
   automatic pick.** Rejected: an orchestrator setting passed as a pick query
   parameter; the pick rule is owned by torrent-downloader, and one switch
   for follows and requests matches how the user thinks about it ("never a
   lower resolution").
2. **The request resolution is its own orchestrator setting.** Rejected:
   reusing a follow's resolution; a request has no follow form to choose one
   in, and a movie request has no follow at all.
3. **The resolution list moves to medialab-contracts.** It is the third
   repetition (downloader, web, orchestrator setting choices), and a value
   outside the list is a 422 from the pick endpoint, so the copies must agree.
4. **CHOICE `lower`/`none`, not a boolean.** The settings contract has no
   boolean type; a two-value CHOICE renders as a select in the web settings
   page with no contracts change.

## Open questions

None.

## Test plan

- **medialab-contracts:** `PICK_RESOLUTIONS` order and that it contains
  `DEFAULT_FOLLOW_RESOLUTION`.
- **torrent-downloader:** `pick_best` with `fallback=False` returns `None`
  when only a lower bucket has a candidate, and the requested-bucket pick when
  it has one; the pick endpoint passes the setting through; the setting
  rejects values outside the choices.
- **medialab-orchestrator:** the movie pick and the show follow use
  `jellyfin_request_resolution`; the setting's choices are `PICK_RESOLUTIONS`.
- **medialab-web:** the follow form lists the contracts tuple.

## Rollout

1. medialab-contracts PR and release.
2. torrent-downloader, medialab-orchestrator and medialab-web PRs, each
   bumping the contracts pin; independent of each other.
3. Releases, then `bin/medialab-setup.sh update`. No migration: both settings
   default to today's behaviour.
