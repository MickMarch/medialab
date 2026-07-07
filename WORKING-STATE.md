# Last-Known-Good Running State

Baseline recorded **2026-07-07**, captured from the live Docker stack before the
version-tracking rework (`chore/version-tracking-compose`).

## Why these are inferred, not read

The running containers were built by the old `docker-compose.yml`, which passed
no `APP_VERSION` build arg. `hatch-vcs` therefore fell back to its `0.0.0`
default, so every running container reports version `0.0.0` internally
(`_version.py` and `importlib.metadata` both confirm `0.0.0`). There is no real
version baked into the live images.

The versions below are reconstructed from each image's **build timestamp** cross
-referenced against the submodule's **git tag history**: the newest tag whose
creation time is at or before the image build time. Image IDs are exact and were
verified against the running containers (all matched `:latest`).

## The stack

| Service | Running version | Image ID | Image built (UTC) | Basis |
|---|---|---|---|---|
| torrent-downloader | **v1.2.0** | `25061b4ecf72` | 2026-06-26 22:35 | v1.2.0 tagged 06-26 15:56 EDT, before build |
| medialab-jellyfin | **pre-v1.0.0** (untagged) | `09963964ac2c` | 2026-06-26 22:34 | earliest tag v1.0.0 is 06-29, after build - built from untagged main |
| medialab-orchestrator | **v0.1.0** | `634447667fb5` | 2026-06-29 18:14 | v0.2.0 tagged 06-29 14:51 EDT = 18:51 UTC, 37 min after build; v0.1.0 is the live one |
| medialab-bot | **v1.0.0** | `f22ba05e6040` | 2026-06-26 22:50 | v1.0.0 tagged 06-08, before build; v2.0.0 not until 06-29 |

## Rollback

Machine-readable copy: [bin/last-known-good.env](bin/last-known-good.env). To
restore, rebuild each submodule at the version above, or - if the pinned image
IDs still exist locally (`docker image ls`) - retag and `up` them directly.

## Going forward

After this branch merges, builds go through `bin/medialab-build.sh`, which
stamps the real git version into both the image tag and an
`org.opencontainers.image.version` OCI label. From then on `bin/medialab-status.sh`
reads the true running version directly - no more inference.
