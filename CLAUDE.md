# CLAUDE.md - medialab workspace

Working rules for Claude Code in this workspace. This file holds rules and
pointers only. Facts live where they are owned:

| Fact | Owner |
|---|---|
| What is in flight, what is next, open threads | GitHub Issues + the "medialab" Project board on `MickMarch/medialab` |
| Architecture, deployment, compose, version tracking | [README.md](README.md) |
| Feature designs | `docs/specs/<slug>.md` (see workflow below) |
| Durable lessons and why things are shaped as they are | `docs/decisions/` |
| Where every secret comes from and goes | [docs/secrets.md](docs/secrets.md) |
| A service's API, config, module layout, test fixtures | that service's `README.md` and `CLAUDE.md` |
| A service's version | its git tag, nothing else |
| Shared wire models and constants | `medialab-contracts` |

Never restate an owned fact elsewhere. Link to it.

## Session start

```bash
gh issue list --repo MickMarch/medialab --label "status:in-progress"   # or open the board
git submodule status                                                  # + means the pin moved
```

A `+` prefix on a submodule means it has commits past the root pin; read that
service's `CLAUDE.md` before touching it. Nothing else needs reading up front.

## Layout

Each subdirectory is an independent git repo pinned here as a submodule. The
root repo tracks workspace docs, `docker-compose.yml`, `bin/`, and the shared
GitHub workflows. Service list, image names and version variables are read
from `docker-compose.yml` by `bin/lib.sh`; do not hardcode them anywhere.

## Conventions (every repo)

- Python 3.12+, `uv` (never pip or poetry), `hatchling` + `hatch-vcs`,
  `pydantic-settings` loading from `.env`.
- Tests: pytest style only, always `uv run pytest`.
- Commits: Conventional Commits. No "Claude", "AI", or tool attribution in
  commit messages or code comments (CLAUDE.md files and `.claude/` are exempt).
- No em dash character anywhere. Use a hyphen or rewrite.
- No hardcoded secrets; `.env` is gitignored; every service ships `.env.example`.
- No magic numbers or strings: named constants, enums, or config
  (`PLR2004` enforces the comparison case).
- Branches: feature branches off `main`, PR to merge. Branch names describe
  the work, never a version.

## Engineering standards (every repo)

Ruff is the only linter and formatter (`E,F,I,UP,B,SIM,PLR2004`, `UP042`
ignored). mypy with the pydantic plugin. Pre-commit with ruff, whitespace, EOF,
yaml and toml checks. Keep-a-Changelog `CHANGELOG.md` with an `Unreleased`
section. Dependabot, grouped per ecosystem.

CI is one reusable workflow, `.github/workflows/python-ci.yml` in this repo,
running ruff check -> ruff format --check -> mypy -> pytest -> pip-audit.
Each service's `ci.yml` only calls it. Shared tooling config
(`.pre-commit-config.yaml`, `dependabot.yml`, `.python-version`, the shared
`[tool.ruff]` / `[tool.mypy]` / pytest markers) must be identical across
repos; `bin/medialab-drift.sh` fails when it is not, and runs in root CI.

Tests must pass with no `.env` and no network. Config fields default to
`None` or literals so imports never fail. Mock external systems at the
client-class boundary, not `httpx`. Anything that needs a real secret or a
live service is `@pytest.mark.integration` and skipped in CI.

DRY with judgment: extract on the third real repetition, never across a
domain boundary just to dedupe. Cross-service shapes and constants go in
`medialab-contracts`, consumed as a tag-pinned uv git dependency.

## Workflow: issue -> spec -> tests -> code -> release

1. **Pick** the top card in "Next" on the board. Every piece of work has an
   issue; if it does not, create one first (labels: `area:*`, `size:*`,
   `kind:*`).
2. **Spec** when the issue is `kind:feature` or `size:M|L`, or carries
   `status:spec-needed`. Write `docs/specs/<slug>.md` from
   `docs/specs/TEMPLATE.md` with `Status: Draft`, open a PR, get explicit
   approval, set `Status: Approved`. No implementation code before approval.
3. **Tests first.** Failing tests that encode the spec, then implement until
   green. Update the service `CHANGELOG.md` under `Unreleased`.
4. **PR** to the service repo. Reference the issue as
   `Closes MickMarch/medialab#N`. CI must be green.
5. **Release** when wanted: `bin/medialab-release.sh <repo> <major|minor|patch>`.
   It computes the version from the last tag at that moment, dates the
   changelog, tags, pushes, and bumps the root pin. The repo's `release.yml`
   publishes the GitHub Release from the changelog section.
6. **Close out.** Spec `Status: Shipped`. A durable lesson, if any, becomes a
   short note in `docs/decisions/`. The issue closes via the PR.

Spec status enum: `Draft`, `Approved`, `Shipped`, `Superseded`. Specs never
carry version numbers or dates of future releases.

## Versioning

The git tag is the single source of truth; `hatch-vcs` derives everything.
Never write a predicted version anywhere: not in a spec, an issue, a branch,
a PR title, or a doc. Refer to work by issue number and name. The version is
chosen at release time by the bump kind (`Added`/`Changed` -> minor,
`Fixed` -> patch, breaking -> major). See
`docs/decisions/0004-no-version-prediction.md` for why.

## Environment

Host: Windows 10 gaming PC; avoid CPU/GPU-heavy local services. qBittorrent
and Jellyfin run on the host, reached from containers over
`host.docker.internal`. A bound VPN is required for any torrent traffic; the
downloader enforces it and the check is configurable but never relaxable.
