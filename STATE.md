# STATE

Session-resume snapshot. Read this first at the start of a session, before
`CLAUDE.md` and before running git commands.

This file is **rewritten, never appended**. It describes only the present. History
lives in git log and in `ROADMAP-DONE.md`.

**Last updated: 2026-08-17**

---

## Now

Nothing in flight. No branch open, no half-finished work.

Working tree: clean except `item-23-plugin-fileurl-spec.md` (uncommitted,
docs-only back-annotation recording two build-time findings - the snapshot-diff
hash readback, and that `medialab-contracts` needed no change for Tier A).

## Last done

- **Item 16 - qBittorrent completion webhook.** COMPLETE 2026-07-20. First real
  end-to-end run succeeded: a movie downloaded, the qB hook fired, the pipeline
  advanced to DONE (Jellyfin scan returned 204). Two fallout fixes shipped -
  medialab-jellyfin `.env` host correction, and dropping the per-download
  REGISTER step (orchestrator v0.4.2, pipeline is now RENAME -> SCAN).
- **Item 23 - per-plugin `fileUrl` handling.** COMPLETE 2026-07-20, verified
  live. All tiers shipped. Live finding: Tier B (HTML details-page scrape) was
  the load-bearing tier, not Tier A.

## Next (agreed order)

1. **Item 18 - uptime / autostart.** Pairs with 16: an always-on pipeline needs
   an always-on stack. Docker runtime on host boot, plus host-app autostart for
   qBittorrent and Jellyfin.
2. **Item 17 - torrent size in the picker**, then **item 13 - `/stop-seeding`
   command.** Two small isolated quick wins.
3. **Item 11 - full Jellyfin naming**, then **item 10 - stuck/failed
   remediation.** Item 10's spec design is locked in `CLAUDE.md` but has no spec
   file and no code yet.

Full ordering rationale and the rest of the queue: `CLAUDE.md` -> "Backlog
ordering".

## Open threads

- `item-23-plugin-fileurl-spec.md` diff is uncommitted.
- Orphan-webhook cosmetic gap: a webhook with no matching job inserts
  `tmdb_id=0`, so RESOLVE_META resolves an empty title. Not on the normal path
  (a real `/download` submit creates the job with the true `tmdb_id`). Fix is a
  PTN-parse title fallback, tied to item 21.
- `WORKING-STATE.md` is a one-shot rollback document, now obsolete since the
  post-rework stack is verified live. Prune or archive it.

## Live pins

All five submodules match their pinned SHA and sit on a tagged release. No dirty
service working trees.

| Submodule | Version |
|---|---|
| medialab-bot | v2.2.0 |
| medialab-contracts | v0.3.0 |
| medialab-jellyfin | v1.0.0-1-g080efb5 |
| medialab-orchestrator | v0.4.2 |
| torrent-downloader | v1.5.0 |

Verify with `git submodule status`; for build/run skew use `bin/medialab-status.sh`.

---

## Maintaining this file

Rewrite it at the end of a working session, or whenever the answer to "where are
we" changes. Keep every section short - if a section grows past a screen, the
detail belongs in `CLAUDE.md` (durable design) or a spec file, not here.

When a backlog item completes, move its entry out of `CLAUDE.md` into
`ROADMAP-DONE.md`, keeping only the outcome and any durable lesson.
