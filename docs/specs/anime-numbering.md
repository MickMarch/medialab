# Spec: Anime episode numbering and dual audio

Status: Approved
Issue: MickMarch/medialab#162

## Problem

Release groups and TMDB can number the same episodes differently. JUJUTSU
KAISEN (TMDB 95479) shows the problem:

| Source | First Culling Game episode | Shape |
|---|---|---|
| TMDB default | S01E48 | one season, 59 episodes |
| Scene and web groups (ToonsHub) | S03E01 | seasons of 24, 23 and 12 |
| Fansubs (SubsPlease) | `- 48` | absolute number, no season |

A follow from S01E48 went through these steps:
1. It treated TMDB Season 1 as finished and searched for an `S01` pack.
2. It picked release-group Season 1, a pack of only 24 episodes.
3. It placed those 24 episodes correctly as S01E01-24, but none of them was
   wanted.
4. It then searched for `S01E48`. No release is named that way, so every
   later poll finds nothing.

TMDB already holds the missing mapping. JUJUTSU KAISEN has episode groups of
type 6 ("TV") named "Seasons" and "季". Each one splits the 59 regular
episodes into 24, 23 and 12, matching the release names.

Anime releases are also often available as dual audio: one file carrying
Japanese and English tracks. Jellyfin switches between tracks during playback,
but a follow has no way to prefer such a release.

## Goal and non-goals

Goal: a follow of a show whose release numbering differs from TMDB downloads
the right episodes, whichever style a release uses:
- release seasons (`S03E01`);
- absolute numbers (`- 48`);
- release-season packs.

Each file is placed where Jellyfin expects it. The numbering is detected
automatically and can be overridden in the web follow form. A follow can also
prefer dual or multi audio releases.

Non-goals:
- Showing the show in Jellyfin as Season 1/2/3. Jellyfin 12.3.0 has no
  `TmdbEpisodeGroup` provider id; its `ExternalIdInfos` lists only `Imdb`,
  `Tmdb` and `Zap2It`. See Open questions.
- Manual search and pick in the web UI or bot. Rename still benefits, because
  it applies the show's numbering to any job of that show.
- Movies.
- Re-downloading an existing library to switch audio.

## Design

### Numbering

```
canonical   TMDB default (season, episode)         S01E48   library layout, presence, follow start
release     episode-group (order, position)        S03E01   search terms, release-season packs
absolute    position across non-special groups     48       search terms, fansub names
```

A **numbering** is one TMDB episode group of type 6. It holds the full map:
canonical `(season, episode)` -> release `(season, episode)` plus an absolute
number.
- A group's `order` is its release season; `order` 0 is specials.
- The absolute number counts regular episodes in group order.

**Auto selection** takes the first type-6 group, in TMDB's listing order,
that meets all three conditions:
1. It covers every regular canonical episode exactly once.
2. It has at least two non-special groups.
3. Its split differs from TMDB's own season split.

When no group qualifies, the numbering is TMDB, the identity map, and today's
behaviour is unchanged.

### Repos

| Repo | Change |
|---|---|
| medialab-contracts | Two enums: `NumberingMode` (`auto`, `tmdb`, `group`) and `ReleaseNumberingSource` (`release`, `absolute`). Two models: `EpisodeNumber` (`season`, `episode`, `release_season`, `release_episode`, `absolute`) and `ShowNumbering` (`tmdb_id`, `group_id: str \| None`, `group_name`, `episodes: list[EpisodeNumber]`). `FollowRequest` gains `numbering: NumberingMode = auto`, `episode_group_id: str \| None` (required when `group`), and `prefer_multi_audio: bool = False`. |
| torrent-downloader | Read routes: `GET /search/tmdb/show/{id}/episode-groups` lists the type-6 candidates and marks the auto choice; `GET /search/tmdb/show/{id}/numbering?group=<id\|auto\|tmdb>` returns a cached `ShowNumbering`. The pick endpoint takes an optional `group` and works in canonical numbering. For a wanted episode it searches in three forms: `Title S03E01`, `Title 48`, and the canonical form. A candidate matches on parsed release `(season, episode)`, on episode alone with no season parsed and equal to the absolute number, or on canonical `(season, episode)`. A pack pick for a release season searches `Title S03` and matches parsed season 3. `prefer_multi_audio=true` ranks `multi_audio` releases first inside the resolution bucket. Seeders and size still break ties, and the existing seeder floor still applies. |
| medialab-orchestrator | Follow storage keeps `numbering`, `episode_group_id` and `prefer_multi_audio`. The follow poll fetches the show's `ShowNumbering` once per check. `wanted_episodes` and the follow start stay canonical. A pack season is now a release season: `pack_eligible` and the pack search group canonical episodes by `release_season`, and a release-season pack covers exactly its own canonical episodes. Rename parses each video file to release, absolute or canonical form, maps it through the show's numbering, and places it under the canonical name (`Season 01/Title S01E48`). The show's numbering is the follow's choice, or auto when the show is not followed, cached per show. A file that matches nothing goes to `extras/` as today. Changing a follow's numbering clears that show's `follow_season` rows, because their season numbers change meaning. |
| medialab-web | Show follow form: a Numbering select offering Auto (it shows the group it resolved to), TMDB, and each listed group by name. A "Prefer dual audio" checkbox. The show browser lists each canonical episode with its release code beside it (`S01E48 · S03E01`), so a user can see the mapping. This is web-only under the UI scope rule, because it is part of a stateful follow form. |

### Dual audio in Jellyfin

Jellyfin keeps every audio track of a file and switches between them in the
player's audio menu. This works in web, Findroid and the TV apps. The default
track follows each user's Playback setting "Preferred audio language". These
are client settings, so medialab only has to pick the release. The
host-setup note gains one line about that preference.

Simulcast releases are usually Japanese with subtitles; the dub arrives weeks
later. `prefer_multi_audio` is therefore a preference, never a filter. An
episode with no multi audio release takes the best single-audio one. The
existing redo flow can replace it once a dual audio release exists.

## Decisions

1. **The library keeps TMDB default numbering.** Rejected: laying files out
   in release seasons. Jellyfin 12.3.0 matches episodes by TMDB default
   numbering and cannot use episode groups yet, so release-season folders
   would get no metadata. Canonical placement means downloads and the
   existing S01E01-24 stay correct with no migration.
2. **The mapping comes from TMDB episode groups.** Rejected: TheXEM and
   anime-lists. Those key on TVDB and AniDB, and torrent-downloader is
   already the single TMDB key holder. A wrong community group is fixed by
   choosing another group in the follow form.
3. **Auto takes the first group that qualifies.** Rejected: matching group
   names ("Seasons"), because names are free text in any language (one
   JUJUTSU KAISEN group is "季"). The rule is structural, and the follow form
   lets a user correct it.
4. **The pick searches all three forms and matches any of them.** Rejected:
   letting the user choose a single release style. One episode's best release
   can be a scene `S03E06` (3328 seeders) while another's is a SubsPlease
   `- 58`. Ranking stays the shared pick rule.
5. **Rename uses the show's numbering, not the job's.** Rejected: storing a
   group id on each job. That would leave manual downloads of `S03E01`
   misplaced. One per-show lookup covers follow, request and manual jobs alike.
6. **Prefer multi audio, never require it.** Rejected: a filter, because
   airing anime rarely has a dub in time. Redo already covers upgrading an
   episode later.
7. **Release-season packs.** Packs follow the release split, because that is
   how pack releases are named. Rejected: canonical-season packs, the cause
   of this bug, which can never be found for a show like this.

## Open questions

1. **Jellyfin episode groups.** Upstream merged `TmdbEpisodeGroup` series
   support in October 2026 (jellyfin/jellyfin PR #16052), after the running
   12.3.0. Once a Jellyfin release carries it, a follow-up can set the series
   provider id from the follow's group, so Jellyfin shows the show as
   Season 1/2/3. That would need a layout migration from canonical to
   release seasons. It is out of scope here.
2. **Specials.** Group `order` 0 sometimes holds the movie or recap episodes
   (5 to 10 for JUJUTSU KAISEN). They stay excluded from follows, as specials
   already are, and get no absolute number. Confirm against the live groups
   during implementation.
3. **Absolute number collisions.** A show can have absolute fansub numbers
   and also seasons in its release names. A release name with no season and
   episode 12 then matches absolute 12 only. Check that this holds against
   real release samples in the downloader tests.

## Test plan

- **medialab-contracts:**
  - Round trips of `ShowNumbering` and `FollowRequest` with the new fields.
  - `group` mode without `episode_group_id` is a validation error.
- **torrent-downloader:**
  - Auto selection:
    - picks the first qualifying type-6 group;
    - skips groups with missing or duplicate episodes, groups with only one
      non-special group, and groups identical to TMDB seasons;
    - falls back to the identity map.
  - Absolute numbers skip specials.
  - Pick matching:
    - `[ToonsHub] Jujutsu Kaisen S03E06` and `[SubsPlease] Jujutsu Kaisen - 53`
      both match canonical S01E53;
    - `Jujutsu Kaisen S01` packs do not match release season 3;
    - an `S03` pack matches release season 3.
  - `prefer_multi_audio` ranks a lower-seeded dual audio release first in the
    same bucket, and the seeder floor still applies.
- **medialab-orchestrator:**
  - The JUJUTSU KAISEN fixture: a follow from S01E48 never asks for the
    S01-24 pack, and asks for the release-season 3 pack once E48-59 have
    aired.
  - Rename places `S03E01`, `- 48` and `S01E48` files all at `S01E48`.
  - Changing the numbering clears `follow_season` for the show.
  - A show with no qualifying group behaves as it does today.
- **medialab-web:**
  - The follow form posts numbering, group and multi audio.
  - The episode view shows release codes.

## Rollout

1. medialab-contracts PR and release.
2. torrent-downloader PR and release.
3. medialab-orchestrator PR and release. A migration adds the three follow
   columns with defaults, so existing follows become `auto` with no
   preference.
4. medialab-web PR and release.
5. Deploy. The existing JUJUTSU KAISEN follow resolves to auto on the next
   poll, and its S01-24 is already in the library. It then fetches release
   Season 3 (S01E48-59 canonical). Release Season 2 (E25-47) is before the
   follow start, so it is not fetched.
6. Root `docs/host-setup.md`: one line about the per-user preferred audio
   language.
