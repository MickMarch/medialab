# 0008 - A display name is not a path

Date: 2026-09-25. Context: first live run of the health poll (#20) and the
naming layout (#19).

## What happened

The pipeline identified a download on disk by `release_name`, taken from
qBittorrent's completion hook `%N` or the transfer list `name`. That is the
torrent's display name. For most releases it is not the folder name:
qBittorrent strips or normalises characters (`[5.1] [YTS.MX]` became
`[5 1] [YTS MX]`, `&` vanished, one name arrived with mojibake). RENAME
looked up a folder that did not exist, planned zero moves, and marked the
job DONE. Five recovered jobs "succeeded" this way before anyone looked at
the disk.

A second latent bug surfaced the same day: the downloader's per-hash
metadata cache lived inside the container and was wiped by every rebuild,
so a step that depended on it failed for any download that completed across
a deploy.

## Decision

- Identify files by what the source system reports as the path, never by a
  human-facing name. qBittorrent's `content_path` (`%F` in the hook) is the
  root file or folder; its basename is what the pipeline renames from.
- A step that finds nothing to do must distinguish "already done" from
  "cannot find the input". The former is idempotent success (the destination
  exists); the latter is a failure with a clear code. Silent success is the
  worst outcome because nobody looks.
- State a service needs at a later step is either carried on the job or
  persisted on a volume; an in-container cache is not a store.
- A recovery feature is verified against the disk, not against the job
  table. The job table said DONE; the disk said otherwise.
