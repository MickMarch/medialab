# Spec: medialab-web, a browser UI beside the Discord bot

Status: Approved
Issue: MickMarch/medialab#66

## Problem

The Discord bot is the only client. Discord limits shape every command: a
select holds 25 options, an embed 25 fields, ephemeral messages expire, there
are no tables, and a delete takes three separate messages. Two copies of one
title were indistinguishable until the picker started showing release names.
The user types on a limited keyboard; a page with buttons beats slash commands.

## Goal and non-goals

Goal: a small self-hosted web page, reachable from any device that reaches
the host (LAN or Meshnet), showing jobs, transfers and storage, with one-click
retry, delete (with the same plan-then-confirm), stop-seeding, and the
search -> pick -> download flow. It is a second thin client of the gateway
and owns no business logic, exactly like the bot.

Non-goals: replacing the bot (it keeps notifications and quick search),
multi-user accounts, editing settings (issue #21), streaming or media
playback (Jellyfin does that), a JavaScript build toolchain.

## Design

New repo and submodule `medialab-web`, image `medialab/medialab-web`,
compose service on port 8080. FastAPI + Jinja2 templates + HTMX from a
vendored file (no npm). Talks only to the orchestrator over
`ORCHESTRATOR_URL` + `ORCHESTRATOR_API_KEY`, the same pair the bot uses.
The gateway is not changed for the first release.

| Page | Gateway calls | Controls |
|---|---|---|
| `/` Jobs | `GET /jobs`, `GET /transfers`, `GET /storage`, `GET /health` | filter by status; Retry on FAILED / NEEDS_ATTENTION; Delete opens the plan panel; Stop seeding |
| `/jobs/{id}` Job | `GET /jobs/{id}`, `GET /jobs/{id}/deletion-plan` | plan shown inline; red Delete button posts `DELETE /jobs/{id}`; Cancel |
| `/search` Search | `GET /search/tmdb`, `GET /search/tmdb/{type}/{id}`, `GET /search/torrents`, `POST /download` | TMDB results as cards; show -> season/episode scope; torrents as a sortable table (seeders, size, resolution, languages) with a Download button per row |
| `/login` | none | single shared password, signed session cookie |

Row layout for jobs: Title (Year), release name, status badge, updated,
actions. Every mutating control is an HTMX `hx-post`/`hx-delete` that swaps
the row; delete requires a second click on the rendered plan. Auto-refresh of
the jobs table every 30 s via `hx-trigger="every 30s"`.

Auth: one password in `WEB_PASSWORD` (`.env`, documented in
`docs/secrets.md`), compared in constant time, session in an itsdangerous
signed cookie (`WEB_SECRET_KEY`). No password means the service refuses to
start. Rate limited like the other services.

Config (`.env.example`): `ORCHESTRATOR_URL`, `ORCHESTRATOR_API_KEY`,
`WEB_PASSWORD`, `WEB_SECRET_KEY`, `API_HOST`, `API_PORT`.

Module layout mirrors the bot: `client/` (copied gateway client, same
mixins), `schemas/` (contracts re-exports), `routes/` (one module per page),
`templates/`, `static/` (htmx.min.js, one stylesheet). The shared client
becomes a candidate for extraction into `medialab-contracts` or a
`medialab-client` package on the third consumer, not now.

## Decisions

1. Separate service, not routes inside the orchestrator. Rejected: HTML in the
   gateway mixes a browser session model with API-key auth and makes the
   gateway the thing that changes for every UI tweak. A second thin client
   keeps the topology the README already draws.
2. Server-rendered HTMX, not a React/Vue app. Rejected: a JS toolchain adds a
   build step, a second dependency ecosystem and CI variant for a page with
   four views.
3. Single shared password plus signed cookie, not per-user accounts or no
   auth. Rejected: no auth exposes delete and download to anyone on Meshnet;
   accounts are #21-scale work for one household.
4. Gateway untouched. Rejected: adding a server-sent-events job stream is
   nicer than polling but is its own spec; 30 s polling matches the health
   poll cadence and is enough.
5. Bot stays. Rejected: dropping it loses push notifications and mobile quick
   search that a page cannot provide without a PWA.
6. Port 8080, direct. Rejected: a reverse proxy in front is host setup, not
   this feature.
7. The search page hides torrents the downloader's audio-language filter
   rejects, same as the bot. Rejected: greyed-out rows invite the exact
   wrong-language download the filter exists to stop.

## Open questions

None.

## Test plan

`medialab-web` (pytest, `httpx.AsyncClient` against the app, gateway client
mocked at the class boundary):

- login: wrong password 401, right password sets cookie, unauthenticated page
  redirects to `/login`, missing `WEB_PASSWORD` fails startup.
- jobs page renders one row per job with title, year, release name and the
  right action buttons per status; filter query narrows.
- retry posts to the gateway and swaps the row; failure shows an inline error.
- delete: plan renders from the gateway plan, refused plan shows no button,
  confirm calls `delete_job` once, cancel calls nothing.
- stop-seeding posts once and reports the count.
- search: TMDB results render; show scope pickers appear; torrent table sorted
  by seeders; Download posts `{source_url, media_type, tmdb_id}`.
- storage panel renders the gateway numbers.

Root: `bin/lib.sh` picks the new service up from compose; drift check
covers the new repo; doctor checks its health endpoint.

## Rollout

1. Create the `medialab-web` repo from the bot's tooling (shared CI caller,
   pre-commit, dependabot, ruff/mypy blocks); add as submodule; compose
   service; `.env.example`; secrets doc.
2. Login + jobs page + storage panel (first release).
3. Delete and retry controls.
4. Search and download flow.
5. Doctor and README updates in the root repo.
