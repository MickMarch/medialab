# Spec: Mood collections

Status: Draft
Issue: MickMarch/medialab#160

## Problem

Jellyfin has no way to browse by genre or mood the way a streaming service
does. Its Home screen has fixed sections (Continue Watching, Next Up, Latest
per library). The Discover libraries hold 87 movies and 63 shows in one flat
poster wall each, apart from the real libraries, which makes them clunky to
browse.

Jellyfin already stores what grouping needs, for real items and Discover
placeholders alike. TMDB genres are in `Genres`, and TMDB keywords are in
`Tags`. The keywords include TMDB's mood terms (`hilarious`, `intense`,
`foreboding`, `adoring`, `philosophical`). There are no collections today.

## Goal and non-goals

Goal: a small set of curated mood collections, such as "Feel-good", "Edge of
your seat" and "Mind-bending". Each mixes owned titles with requestable
Discover placeholders and is kept in step automatically. A heart on a
placeholder inside a collection files a request exactly as it does in the
Discover library. Collections are a standard Jellyfin item type, so the web
client, Findroid and the TV apps all show them without a plugin.

Non-goals:
- Home screen rows. Those need the community Home Screen Sections plugin,
  which only works in the web client.
- Per-user moods, and editing moods from the web UI.
- Ordering inside a collection, which is the client's sort.
- Changing how many Discover placeholders exist.
- Bot or web UI surfaces.

## Design

| Repo | Change |
|---|---|
| medialab-contracts | `MoodCollectionSync` (`name: str`, `item_ids: list[str]`) and `MOOD_COLLECTION_TAG = "medialab-mood"`. Also `TaggedItem` (`item_id`, `media_type`, `tmdb_id`, `genres`, `tags`, `community_rating`, `is_placeholder`) and `TaggedItemsResponse`. |
| medialab-jellyfin | `GET /library/tagged-items`: every Movie and Series in the real and Discover libraries, with genres, tags, community rating and `is_placeholder`, read with `Fields=Genres,Tags`. `PUT /collections/mood`, body `MoodCollectionSync`: finds the collection by name among those tagged `MOOD_COLLECTION_TAG`, creates it when absent (`POST /Collections`, then tags it), adds missing ids and removes extra ids, which makes it idempotent. `DELETE /collections/mood/{name}` removes a tagged collection, never its items. |
| medialab-orchestrator | `services/moods.py`: the `MOODS` table (below) and a pure `mood_members(items, mood) -> list[str]`. `MoodReconciler` runs at the end of every Discover reconcile tick, so placeholders added or removed that tick are reflected. It reads tagged items once, computes each mood, PUTs each collection, and DELETEs tagged collections whose name is no longer in `MOODS`. A runtime INT setting, `mood_collection_size` (default 40, 0 disables the feature), caps each collection. |

### Mood rule

A mood is a frozen dataclass with these fields:
- `name`
- `genres`: a frozenset; any one of them qualifies a title
- `tags`: a frozenset of TMDB keywords
- `exclude_genres`

A title is a member when all of these hold:
1. It has at least one of the mood's genres.
2. It has at least one of the mood's tags.
3. It has none of the excluded genres.

Matching ignores case. Members are ranked as follows:
1. More matching tags first.
2. Then owned titles before placeholders.
3. Then community rating.

The ranked list is cut to `mood_collection_size`. A title can sit in several
moods.

Initial table (tuned during implementation against the live library, see
Open questions):

| Mood | Genres | Tags (any) | Exclude |
|---|---|---|---|
| Feel-good | Comedy, Family, Animation, Romance | hilarious, adoring, cheerful, joyful, lighthearted, feel-good, enthusiastic, wholesome | Horror |
| Edge of your seat | Thriller, Action, Crime | intense, suspenseful, tense, frantic, gripping | |
| Mind-bending | Science Fiction, Mystery, Fantasy | philosophical, mind-bending, surrealism, time travel, bewildered, complex | |
| After dark | Horror, Thriller | foreboding, ominous, disturbing, psychological horror, creepy | |
| Big adventure | Adventure, Fantasy, Science Fiction | epic, bold, space adventure, quest, swashbuckler | Horror |
| Heartfelt | Drama, Romance | emotional, melancholy, inspirational, sentimental, tearjerker | Horror |

## Decisions

1. **Collections, not home rows.** Rejected: the Home Screen Sections plugin,
   because Findroid and the TV apps ignore it. Rejected: Netflix-style rows in
   medialab-web, because that is another app to open on the TV. Collections
   are core Jellyfin and show in every client.
2. **Membership comes from Jellyfin's own genres and tags.** Rejected: calling
   TMDB keyword endpoints from torrent-downloader. Jellyfin has already
   fetched the same TMDB data for every item, so this costs no extra calls and
   needs no TMDB key outside torrent-downloader.
3. **A mood needs both a genre and a tag.** Rejected: genre only, which is
   what Jellyfin's Genres tab already gives. Rejected: tag only, because a
   keyword like "intense" also appears on dramas and would blur the mood.
4. **Moods are a code table in the orchestrator.** Rejected: a runtime
   setting, because the settings contract has no list or object type, and
   moods change rarely enough to ship as a minor release.
5. **Ownership by collection tag.** medialab-jellyfin only creates, edits or
   deletes collections tagged `MOOD_COLLECTION_TAG`. A collection the user
   made by hand is never touched, even when its name matches a mood.
6. **Sync on the Discover reconcile cadence.** Rejected: a third loop, and
   syncing on every request poll. Membership changes when the library or the
   placeholder set changes; downloads finish into the library between
   reconciles, and a 6-hour lag is acceptable for browsing.
7. **Owned before placeholder at equal tag score.** A mood row should feel
   like your library with suggestions mixed in, not a request catalogue.

## Open questions

1. **Tag vocabulary.** TMDB mood keywords are sparse on older titles. If a
   mood ends up with fewer than about 10 members on the live library, widen
   its tags before Approved. Resolve by running `mood_members` against a
   tagged-items dump during implementation; record the final table here.
2. **Findroid collection display.** Confirm on the device that Findroid lists
   collections and that a heart on a placeholder inside one files a request.
   If it does not list them, add a host-setup note on enabling the
   Collections view.

## Test plan

- **medialab-contracts:**
  - `MoodCollectionSync` and `TaggedItem` round trip.
  - The tag constant's value.
- **medialab-jellyfin:**
  - Tagged items cover both real and Discover libraries, and set
    `is_placeholder` from the Discover library ids.
  - The PUT creates and tags a missing collection.
  - It adds only missing ids and removes extras.
  - A second identical PUT makes no Jellyfin calls beyond the reads.
  - An untagged collection with the same name is not touched; a tagged one
    is created beside it.
  - The DELETE refuses an untagged collection.
- **medialab-orchestrator:**
  - `mood_members`: genre without tag excluded, tag without genre excluded,
    excluded genre wins, case-insensitive match, ranking order, the size cap.
  - The reconciler PUTs every mood and deletes a stale tagged mood.
  - A size of 0 skips the sync.
  - A medialab-jellyfin error is logged and never stops the Discover tick.

## Rollout

1. medialab-contracts PR and release.
2. medialab-jellyfin PR and release.
3. medialab-orchestrator PR and release, after pin bumps in both.
4. Deploy. The first Discover reconcile after startup creates the
   collections. No migration and no manual host step, apart from the possible
   Findroid note in open question 2.
