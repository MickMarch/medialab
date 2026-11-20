# Spec: remove the Jellyfin Discover libraries

Status: Shipped
Issue: MickMarch/medialab#168

## Problem

The Discover Movies and Discover Shows libraries
(`docs/specs/jellyfin-in-app-requests.md`) do not work for the household:

- They sort before the real libraries, so they show up first in every client.
- Their placeholder items carry real posters and overviews, so they look like
  media that is already in the library. You only find out by opening one.

The favorite-to-request flow they exist for has not earned that cost.
Discovery already has a home in medialab-web: the Discover page, the show
browser and Follow. Mood collections (MickMarch/medialab#161) will extend it.

## Goal and non-goals

Goal: Jellyfin shows only real media.
- The Discover libraries are removed from Jellyfin.
- The orchestrator stops writing placeholders and stops polling favorites.
- Every piece of code and config that exists only for them is removed:
  - code: services, routes and loops;
  - settings: config keys, the webhook secret, the compose mount;
  - setup steps;
  - shared models in medialab-contracts.
- Upgrading needs no manual step except deleting the old placeholder folder
  and, optionally, uninstalling the Jellyfin Webhook plugin.

Non-goals:
- Any new discovery surface in Jellyfin.
- Changes to the web Discover page or the bot.
- Mood collections (MickMarch/medialab#161).
- Removing torrent-downloader capabilities that other flows use.

## Design

### What goes, by service

| Service | Removed | Kept |
|---|---|---|
| medialab-orchestrator | `services/discover_reconcile.py`; `services/requests.py`; `store/requests.py`; `routers/jellyfin_events.py`; the Discover and request loops in the lifespan; the Discover and favorites methods on `clients/jellyfin.py`; the `discover_*` and `jellyfin_request_*` config fields and their runtime settings; `jellyfin_webhook_secret`; the client methods `discover(..., released=)` and `recommendations` | Watchlist entries a request created: they are ordinary saved or followed entries and stay as they are |
| medialab-jellyfin | `routers/discover.py`, `services/placeholders.py`, the bundled clip under `assets/`, the per-user favorites reader, `DISCOVER_MOUNT_PATH` config | Library scan, `/library/tmdb-ids`, credential probe |
| medialab-contracts | `placeholders.py` (placeholder states and markers, the clip constants, `JellyfinRequestEvent`, `FavoriteScope`, `PlaceholderWrite`, `PlaceholderInfo`, `PlaceholdersResponse`, `DISCOVER_LIBRARY_NAMES`) and its exports. This is a breaking change, so the next release is a major one | Everything else |
| medialab-setup | `ensure_discover_libraries`, `discover_folders`, the `DISCOVER_HOST_DIR` binding. Gains `remove_discover_libraries` (see Teardown) | Library root registration |
| torrent-downloader | Nothing | The `released` discover filter, recommendations, movie-scope picks and rejecting pre-release (cam, screener) releases. See decision 4 |
| root | `DISCOVER_HOST_DIR` in `.env.example`; the medialab-jellyfin `/discover` mount in `docker-compose.yml`; the Discover sections of `docs/host-setup.md`; the webhook secret row in `docs/secrets.md` | |
| medialab-web, medialab-bot | Nothing. The removed settings simply drop off the Settings page, because the gateway lists them | |

### Teardown on an existing install

`bin/medialab-setup.sh update` runs `remove_discover_libraries` once the new
images are up:
- It deletes each Jellyfin library named "Discover Movies" or "Discover
  Shows" whose only path is under the old Discover folder, through
  `DELETE /Library/VirtualFolders`.
- A library with that name but any other path is left alone and logged.
- Running it again finds nothing and does nothing.

The orchestrator drops the `jellyfin_request` table at startup if it exists.
A request still in flight has already filed its download as an ordinary job,
or a show follow, so nothing is lost.

The placeholder folder on the host (old `DISCOVER_HOST_DIR`, default
`F:\MedialabDiscover`) is not deleted by any script. `docs/host-setup.md`
gets an "Upgrading past Discover libraries" note:
- delete the folder by hand;
- optionally uninstall the Jellyfin Webhook plugin, which only woke the
  request poll.

### The superseded spec

`docs/specs/jellyfin-in-app-requests.md` moves to `Status: Superseded` with
a one-line pointer to this spec. At close-out, a decision note records why
in-Jellyfin requests were removed (`docs/decisions/`).

## Decisions

1. **Remove, not reorder.** Each user can push the libraries down under
   Jellyfin's Settings > Home, but that fixes the order only, not items that
   look like real media. Renaming them to sort last ("zz Discover") fixes the
   order globally and still leaves the look-alikes. Rejected: the look-alike
   problem is the main complaint.
2. **The request flow goes with the libraries.** Favoriting a placeholder is
   the only way to request from inside Jellyfin. The alternative was to keep
   requests through favorites in the real libraries, but you can only
   favorite what you already have. Rejected. Requests stay in web and the bot.
3. **Delete the code, do not leave it switched off behind a flag.** A disabled
   subsystem still costs CI time, dependency bumps and reading. It stays in
   git history if it is ever wanted back.
4. **torrent-downloader keeps its capabilities.**
   - The movie-scope pick and the pre-release rejection are correct
     behaviour for any automatic pick.
   - The `released` filter and recommendations are small cached TMDB reads.
     Mood collections (MickMarch/medialab#161) is the likely next consumer,
     and removing them now would only mean adding them back.

   Rejected: removing everything only the request flow called today. The
   orchestrator's client methods for them do go, so that no dead code is
   left in the gateway.
5. **Remove from the contracts now, with a major release.** The alternative
   was to keep deprecated models for a release cycle. Rejected: every
   consumer is in this workspace and pinned by tag, and all of them move in
   this change, so nobody is left on the old models.
6. **Setup deletes the Jellyfin libraries; nothing deletes the folder.**
   Deleting a library only removes Jellyfin's index of it and is recreated
   cheaply. Deleting files on the host is not reversible, so it stays a
   documented manual step.

7. **medialab-jellyfin keeps excluding the retired library names.** If
   teardown is skipped or fails, a leftover Discover library would otherwise
   report placeholder titles, and a placeholder's stub `S01E01`, as owned, and
   the follow would never fetch them. The alternative was to drop the filter
   with the libraries. Rejected: one failed teardown would silently block
   downloads. The exclusion uses a local constant and goes in a later change,
   once no install has the libraries.
8. **Open requests survive the table drop.** A `requested` or `not_found`
   request had filed nothing, so dropping `jellyfin_request` would lose it.
   Each one becomes a saved watchlist entry first. The alternative was to
   only log them. Rejected: the user asked for the title and should still
   see it.
9. **`update` strips the removed keys from service `.env` files.** Otherwise
   a local `uv run` fails, because the settings loader rejects unknown dotenv
   keys. Teardown also runs on an up-to-date `update`, so a warned teardown is
   retried. It stays a warning that names each library left behind, which is
   safe because of decision 7.

## Open questions

None.

## Test plan

- **medialab-orchestrator:**
  - the app starts with no Discover or request loop running;
  - `POST /jellyfin/events` returns 404;
  - startup drops an existing `jellyfin_request` table and keeps the
    watchlist rows;
  - the settings listing has no `discover_*` or `jellyfin_request_*` key.

  Tests for the removed modules are deleted with them.
- **medialab-jellyfin:**
  - every `/discover/*` route returns 404;
  - the app starts with no `DISCOVER_MOUNT_PATH` set.
- **medialab-contracts:** `tests/test_placeholders.py` is deleted; a test
  asserts the package no longer exports `DISCOVER_LIBRARY_NAMES` or
  `JellyfinRequestEvent`.
- **medialab-setup:** `remove_discover_libraries`, tested against a mocked
  client:
  - it deletes a matching library;
  - it skips a library with the same name but a foreign path;
  - it does nothing when no Discover library exists;
  - running it twice is safe.
- **root:** `bin/medialab-drift.sh` and compose config validation pass
  without `DISCOVER_HOST_DIR`.

## Rollout

1. medialab-orchestrator PR: stop calling medialab-jellyfin's Discover routes
   and remove the loops, routes, store and config. Released first, so
   nothing calls the routes the next PR removes.
2. medialab-jellyfin PR: remove the routes, service, clip and mount config.
3. medialab-setup PR: `remove_discover_libraries` replaces
   `ensure_discover_libraries`.
4. medialab-contracts PR and major release: remove the placeholder models.
   Then a pin bump in orchestrator, jellyfin and setup, in the same release
   batch.
5. Root PR: compose mount, `.env.example`, host-setup and secrets docs. Mark
   `jellyfin-in-app-requests.md` Superseded and bump the pins.
6. Deploy with `bin/medialab-setup.sh update`. The libraries disappear from
   every client after it runs. Delete the host folder by hand.
