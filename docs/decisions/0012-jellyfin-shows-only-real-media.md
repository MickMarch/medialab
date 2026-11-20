# 0012 - Jellyfin shows only real media

Date: 2026-11-20. Context: removal of the Discover libraries
(`docs/specs/remove-discover-libraries.md`, MickMarch/medialab#168), which
superseded `docs/specs/jellyfin-in-app-requests.md`.

## What happened

The Discover Movies and Discover Shows libraries filled Jellyfin with
placeholder items so a household member could favorite a title to request
it. In use, they sorted ahead of the real libraries in every client, and
their real posters and overviews made them look like media that was already
there. The request flow did not earn that cost, and it was removed with the
libraries. Discovery stays in medialab-web.

The teardown on deploy then failed with 401: Jellyfin 12 rejects the
`X-Emby-Token` header that medialab-setup sent, while medialab-jellyfin
already used `Authorization: MediaBrowser Token="..."`
(MickMarch/medialab#171).

## The lesson

- A media server's libraries are what people browse. Anything placed there
  must be real media. A feature that needs stand-in items belongs in the
  suite's own UI, where it can look like what it is.
- Removing a feature that wrote into another system needs a teardown that
  can be retried, and a guard for the case where it fails. Update reruns the
  teardown on every run, and medialab-jellyfin keeps ignoring the retired
  library names until no install has them.
- Every Jellyfin client in the suite authenticates with the same header
  form. Two forms existed, and only the one the long-running service used
  was exercised against the upgraded server.

## How to apply

- Do not add libraries, collections or items to Jellyfin that are not files
  on disk.
- When a suite tool talks to Jellyfin, use the `Authorization` header form,
  and run its live path once after a Jellyfin major upgrade.
