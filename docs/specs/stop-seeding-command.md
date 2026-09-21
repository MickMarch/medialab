# Spec: /stop-seeding command

Status: Draft
Issue: MickMarch/medialab#18

## Problem

torrent-downloader already exposes `POST /transfers/stop-seeding`, which
pauses every torrent currently in a seeding state and never touches an
in-progress download. The orchestrator's client already calls it inside the
pipeline's STOP_SEEDING step. Nothing lets a user trigger it from Discord.

## Goal and non-goals

**Goal.** `/stop-seeding` in Discord pauses all seeding (completed) torrents
and reports the result, through the gateway.

**Non-goals.** Per-torrent stop; remove-instead-of-pause; any change to what
the downloader does. Those belong to the stuck-download remediation issue
(#20), which decides the STOP_SEEDING remove-vs-pause behaviour.

## Design

| Layer | Change |
|---|---|
| medialab-orchestrator | `POST /api/v1/transfers/stop-seeding`, a stateless passthrough to `ctx.torrent.stop_seeding()` returning the downloader's `{status, message}` with `202`. Same shape as the existing `/storage` proxy. No job is created or touched: this is a user action on the torrent client, not a pipeline transition. |
| medialab-bot | `OrchestratorClient.stop_seeding()` posting to that route, parsed into a small `ActionResponse {status, message}` schema. `/stop-seeding` command in `StatusCog`: defer ephemeral, call, reply with the message, or a failure line when the client returns `None`. |

No contracts change: the response is the downloader's existing envelope.

## Decisions

1. Passthrough, not a job. The gateway rule "every endpoint binds a job" has
   the search proxies as its accepted exception; this is the same kind of
   stateless action and joins that exception.
2. All-seeding semantics kept. The downloader endpoint is all-or-nothing by
   design; a per-hash variant is a downloader change and is #20's call.
3. Ephemeral reply. It is an operator action; no need to post to the channel.

## Open questions

None.

## Test plan

Orchestrator `tests/test_gateway.py`: route proxies the client result with
`202`, requires the API key. Bot `tests/test_client.py`: posts to the shared
prefix path, parses the envelope. Bot `tests/cogs/test_status.py`: defers,
sends the message on success, failure line on `None`.

## Rollout

Orchestrator PR first (minor release), then bot PR (minor release).
