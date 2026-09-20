# 0003 - Webhook-only cannot detect a stuck download

Date: 2026-07-20. Context: orchestrator MVP decision "DOWNLOADING via
read-through, not polling", later reversed by the stuck-download remediation
issue.

## What happened

The MVP advanced jobs only on the qBittorrent completion webhook, on the
assumption that downloads always complete and the hook always fires. Observed
live: an I/O error mid-download leaves the torrent in an error or upload-only
state, the completion hook never fires, and the job sits at
`DOWNLOAD_SUBMITTED` forever with nothing to notice it.

A second variant hit after completion: the pipeline reached DONE, then
qBittorrent's final re-verify hit a file briefly locked by Windows Defender and
flipped the torrent to error. For TV the RENAME step had already moved the
folder, so a resume can never succeed (the files are gone from the old path);
for movies (no move) a resume fixes it.

## Decision

- The orchestrator runs a periodic health poll over `GET /transfers` in its
  asyncio worker. The webhook remains the fast path; the poll is the safety
  net. "No polling" was the wrong absolute.
- Remedy is auto-resume with a retry cap, then flag the job for a human.
- STOP_SEEDING must remove (or repoint) the torrent once the pipeline owns the
  files, not merely pause it, or a later recheck errors on the moved path.
