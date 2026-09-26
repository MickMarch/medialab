# Spec: audio language in the torrent picker

Status: Draft
Issue: MickMarch/medialab#49

## Problem

The picker shows resolution, seeders and size. It shows nothing about
language, so several non-English releases were chosen by accident, the latest
being `Obsession.2026.2160p...MULTi.FRE.LAT...`. Release names almost always
carry the language when it is not English (`FRENCH`, `ITA.ENG`, `HINDI`,
`MULTi`, `VOSTFR`), and English releases almost never carry a tag. PTN
parses these: `language` is a name or a list of names, `subtitles` likewise.

Probed 2026-09-25 on real names: `FRENCH`, `TRUEFRENCH`, `ITA.ENG`, `HINDI`,
`SPANISH.LATINO`, `GERMAN`, `KOREAN`, `RUS.ENG`, `MULTi.FRE.LAT` all yield the
right language(s); `VOSTFR` and `ENG.SUBS` land in `subtitles`; `DUAL`,
`DUAL-AUDIO` and a bare `MULTi` yield nothing (they mean "includes the
original audio", usually English alongside another).

## Goal and non-goals

**Goal.** A user never picks a foreign-audio release by accident: releases
tagged with a language other than the target are filtered out by default,
and every result shows its language tag when it has one.

**Non-goals.** Detecting the language of untagged releases (impossible from
the name; they are overwhelmingly English and stay). Subtitle language
preferences. Per-request overrides in Discord (a later settings item can
expose the policy).

## Design

### torrent-downloader

- Each result gains two wire fields alongside the existing camelCase ones:
  `languages` (list of language names PTN parsed, empty when untagged) and
  `multiAudio` (`true` when the name carries `MULTi`, `MULTI`, `DUAL` or
  `DUAL-AUDIO`, meaning more than one audio track is present).
- New config `AUDIO_LANGUAGE_FILTER` with values `lenient` (default),
  `strict`, `off`:
  - `lenient`: drop a result only when its parsed `languages` are non-empty,
    do not include the target language, and `multiAudio` is false. Untagged
    results and multi-audio results stay.
  - `strict`: as lenient, and also drop untagged results. For users whose
    trackers tag everything.
  - `off`: no filtering; tags still shown.
- The target language name comes from the existing `TARGET_LANGUAGE` code
  (`en`) through a small code-to-name table (`en` -> `English`, `fr` ->
  `French`, ...), kept in the downloader next to the filter. Unknown code:
  the filter logs once and behaves as `off`.
- The filter runs in `filter_and_sort_results`, after the seeder and
  source checks, before scope filtering. Dropped results are counted in the
  log line so an empty picker is explainable.

### medialab-bot

- `TorrentResult` gains `languages` and `multi_audio`.
- Option description appends the tag when there is one:
  `123 seeders · 8.0 GB · FRENCH`, `· ITA/ENG`, `· MULTi`. Untagged shows
  nothing extra. Names are upper-cased to read like release tags; multiple
  joined with `/`.

### contracts

None. The search result shape is torrent-downloader's own, mirrored by the
bot with aliases, as today.

## Decisions

1. Filter downstream, display upstream. The downloader owns search and
   already applies seeder and source filters; the bot only renders. Keeps
   the bot thin.
2. Lenient by default. Dropping untagged results would empty the picker for
   most English content; the accidental downloads were all tagged.
3. `MULTi`/`DUAL` kept, not dropped. They usually include the original
   audio; showing the `MULTi` tag lets the user decide.
4. Language table in the downloader, not a new dependency. A dozen codes
   cover real use; PTN's names are the join key.
5. Subtitle tags are not shown. `VOSTFR` means French subs on original audio,
   which for an English film is what the user wants; surfacing it would read
   as a warning.

## Open questions

None expected; default policy is the one decision, stated above.

## Test plan

Downloader: parsing table (every probed name above plus `MULTi`, `DUAL`,
untagged), filter under each policy, target-code mapping and unknown code,
counting of dropped results. Bot: description with one tag, two tags,
multi-audio, none; schema parses the new fields and tolerates their absence
(older downloader).

## Rollout

Downloader PR (minor), then bot PR (minor). Bot tolerates a downloader
without the fields, so order is not load-bearing.
