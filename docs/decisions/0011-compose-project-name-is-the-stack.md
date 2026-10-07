# 0011 - The compose project name is the stack, not the directory

Date: 2026-10-07. Context: first live acceptance run of the setup CLI
(`docs/specs/setup-and-update-cli.md`, MickMarch/medialab#23).

## What happened

The acceptance plan was a fresh clone in a second directory, run while the
live stack was stopped, on the assumption that two directories meant two
compose projects with separate containers and volumes. `docker-compose.yml`
sets `name: medialab`, so Docker Compose treated the scratch clone as the
live project. Its `up` created `medialab-gluetun-1` and
`medialab-qbittorrent-1` with the scratch configuration and, had the run
reached the orchestrator, would have mounted the live `orchestrator-data`
volume. The run failed earlier, nothing was lost, and the live stack came
back with its own `up`. The isolation claim made before the run was wrong.

## The lesson

Compose identifies a stack by project name. Containers, networks and named
volumes all hang off that name; the directory is only where the file lives.
A top-level `name:` is convenient for one install and a trap for any second
checkout on the same engine, which is exactly what a test, a rollback
rehearsal or a second operator produces. `COMPOSE_PROJECT_NAME` and `-p`
override the file's name, so the fix is a guard plus a recipe, not a
compose change.

## How to apply

- Before any `compose up` from a tool, read `docker compose ls` and refuse
  when the project is owned by another directory. The setup CLI does this in
  preflight and before `update`.
- A second checkout on the same host must set `COMPOSE_PROJECT_NAME` to a
  distinct value, and its published ports still collide with the live stack,
  so it also runs while live is stopped or with different ports.
- When claiming isolation, name the shared identifiers (project name, named
  volumes, host ports, external accounts) one by one; the one not named is
  the one that bites.
