# 0004 - Never predict a version number

Date: 2026-07-02. Context: TV season targeting shipped across four repos.

## What happened

The spec and branch names guessed the release versions while drafting. Two
guesses were wrong: the orchestrator was written as v0.2.0 but that tag
already existed, so it shipped v0.3.0; the bot was written as v1.1.0 but was
already at v2.0.0 after the gateway rewrite, so it shipped v2.1.0. The stale
guesses then lived on in the spec, the roadmap, and two branch names.

## Decision

- The git tag is the single source of truth for a service's version.
  `hatch-vcs` derives everything from it; nothing is hardcoded.
- No predicted version appears in a spec, an issue, a branch name, a PR title,
  or any doc. Work is referenced by issue number and feature name.
- The version is chosen at release time, by `bin/medialab-release.sh`, from
  the last tag plus the bump kind (Keep-a-Changelog: Added/Changed -> minor,
  Fixed -> patch, breaking -> major).
- Root docs never carry a service version in prose. The `CHANGELOG.md` and
  the tag list are the only places a version string belongs.
