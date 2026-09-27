# Spec: runtime settings, one store per service, one page to change them

Status: Draft
Issue: MickMarch/medialab#21

## Problem

Every tunable lives in a service `.env` and is read once at import. Changing
the audio-language filter, the minimum seeders, the search timeout or the
health-poll budget means editing a file on the host and recreating a
container. The user types on a phone; that is not a workable loop. The
storage-threshold warning (#22) and the RSS watchlist (#24) both need a place
to keep a user-set value.

## Goal and non-goals

Goal: a small set of behaviour settings can be read and changed at runtime
from the web UI (and the bot), each service owns and persists its own values,
and a change applies without a restart wherever the code reads the value per
request. Secrets, URLs, ports, paths and the VPN allowlist are not settings:
they stay in `.env` and never appear on the page.

Non-goals: per-user settings, an audit log, editing `.env` from the UI,
changing anything that needs a process restart to apply (those remain `.env`
values and the page never lists them).

## Design

### Registry, store, override (each service that owns settings)

A service that owns settings adds `core/settings.py`:

- `SETTINGS: tuple[SettingSpec, ...]` declares each tunable: `key` (the
  `AppConfig` field name), type, bounds or choices, one-line description. Only
  declared keys are readable or writable; everything else in `AppConfig` is
  invisible to the API.
- `SettingsStore` persists overrides as a JSON document on the service's data
  volume (`SETTINGS_PATH`; the downloader defaults into its cache volume, the
  orchestrator into its data volume).
- On startup, stored overrides are applied onto the `config` instance. On
  `PUT`, the value is validated against the spec, written to the store, then
  applied with `setattr(config, key, value)`. Code that reads `config.<key>`
  at call time sees the new value on the next request.
- Effective value resolution: override if present, else the `.env` value,
  else the field default. `GET` reports the effective value and its source.

Owned settings, first release:

| Service | Key | Type | Applies |
|---|---|---|---|
| torrent-downloader | `target_language` | ISO 639-1 code | next search |
| torrent-downloader | `audio_language_filter` | `lenient` / `strict` / `off` | next search |
| torrent-downloader | `minimum_seeders` | int 0..1000 | next search |
| torrent-downloader | `search_timeout_seconds` | int 5..120 | next search |
| torrent-downloader | `search_concurrency` | int 1..8 | next search |
| torrent-downloader | `cache_expiration_seconds` | int 0..86400 | next cache write |
| medialab-orchestrator | `auto_resume_max` | int 0..10 | next poll tick |
| medialab-orchestrator | `auto_retry_max` | int 0..10 | next poll tick |
| medialab-orchestrator | `health_poll_interval_seconds` | int 0 or 60..3600 | next poll tick (the poller re-reads the interval each sleep) |

The bot's and the web UI's own display limits (`SELECT_MAX_RESULTS`,
`TORRENT_RESULTS_PER_RESOLUTION`) stay `.env` values: they are per-client
presentation, not suite behaviour.

### Service API (downloader, orchestrator)

| Method | Path | Body / result |
|---|---|---|
| `GET` | `/settings` | `SettingsResponse`: list of `SettingView` (`key`, `value`, `default`, `source`, `type`, `choices` or `min`/`max`, `description`, `applies`) |
| `PUT` | `/settings/{key}` | `{"value": ...}` -> the updated `SettingView`; 404 unknown key, 422 out of bounds |
| `DELETE` | `/settings/{key}` | drops the override; back to the `.env` value |

`SettingView`, `SettingsResponse` and `SettingSource` live in
`medialab-contracts` because the gateway relays them and two clients render
them.

### Gateway

`GET /settings` calls the downloader and adds its own local settings, returning
`{"services": {"torrent-downloader": [...], "medialab-orchestrator": [...]}}`.
`PUT /settings/{service}/{key}` and `DELETE /settings/{service}/{key}` forward
to the named service, or act locally for `medialab-orchestrator`. Unknown
service -> 404.

### Clients

- Web: a `/settings` page, one card per service, one row per setting with
  the effective value, its source (`.env` or override), an input sized to
  the type (select for choices, number with bounds), Save per row (HTMX swap
  of the row), and Reset to drop the override. Every row states when the
  change applies.
- Bot: `/settings` shows the same list as an embed; `/settings set
  <service> <key> <value>` and `/settings reset <service> <key>`. The reply
  states when the change applies.

## Decisions

1. Overrides in a JSON file on the service's own volume, not by rewriting
   `.env`. Rejected: `env_file` in compose injects variables at container
   create; the file is not mounted, so writing it from inside the container
   changes nothing until the container is recreated from an edited host file.
   The downloader's unused `settings_manager.update_environment_variables`
   is deleted for that reason.
2. A declared registry, not every `AppConfig` field. Rejected: exposing the
   whole model would put API keys and paths on a page; the registry is the
   allowlist and carries the bounds the UI needs.
3. Each service validates and persists its own settings; the gateway only
   relays. Rejected: a central settings table in the orchestrator would make
   the downloader depend on a callback to learn a value, inverting the
   dependency direction the README draws.
4. Mutating the live `config` instance in place, not rebuilding it. Rejected:
   every module imported `config` by reference; replacing the object would
   need every consumer to re-import. `setattr` on the pydantic model happens
   only after the spec validated the value.
5. `health_poll_interval_seconds` becomes hot by having the poller read the
   interval each iteration instead of once at startup; `0` still disables
   the next tick. Rejected: leaving it restart-only means one row on the page
   works differently from every other.
6. Not in scope: the storage threshold (#22) adds one orchestrator setting on
   top of this; the RSS watchlist (#24) keeps its own table, not settings.

## Open questions

1. Should the bot get `/settings` in the same release, or web first and bot
   in a follow-up? Recommendation: web first; the bot follows in its own PR.

## Test plan

- contracts: `SettingView` round-trips; `source` is `env` or `override`.
- downloader and orchestrator `core/settings.py`: registry rejects unknown
  keys; bounds and choices enforced; store round-trips; startup applies
  overrides onto `config`; `DELETE` restores the `.env` value; the next
  search or poll tick uses the new value (mock at the class boundary).
- orchestrator poller: interval change takes effect on the next sleep.
- gateway: `GET /settings` aggregates both; `PUT`/`DELETE` forward to the
  right service; local keys handled locally; unknown service is 404.
- web: settings page renders a row per setting with the right control; save
  posts the value and swaps the row; reset calls `DELETE`; a bounds error is
  shown inline.
- bot (follow-up): `/settings` embed, `set` and `reset` call the gateway once.

## Rollout

1. `medialab-contracts`: `SettingView`, `SettingsResponse`, `SettingSource`;
   release.
2. `torrent-downloader`: registry, store, routes; delete
   `settings_manager.py`; `SETTINGS_PATH` in `.env.example`; release.
3. `medialab-orchestrator`: registry, store, routes, hot poll interval,
   gateway aggregation and forwarding; release.
4. `medialab-web`: settings page; release.
5. `medialab-bot`: `/settings` cog; release.
6. Root: nothing to change; no secret is a setting.
