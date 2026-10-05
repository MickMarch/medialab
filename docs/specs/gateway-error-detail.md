# Spec: gateway error code and detail in the web and bot

Status: Approved
Issue: MickMarch/medialab#124

## Problem

The orchestrator answers a failed download with a structured error envelope
(`{status, code, detail}`), and since MickMarch/medialab#110 that envelope can
say something worth acting on: `503 SOURCE_UNREACHABLE` with "the request can
be retried". Neither UI reads it. The web and bot clients collapse every
non-2xx answer into `None`, so the user sees "Download request failed; nothing
was submitted" whether the VPN dropped, the source page could not be fetched,
or the gateway was down. The bot already works around one case by probing
`/health` for the VPN flag after a failure, because the gateway collapses the
downloader's `VPN_NOT_BOUND` into `502 DOWNSTREAM_UNAVAILABLE`.

## Goal and non-goals

**Goal.** A download or redo that the gateway refuses with a known, retryable
code shows that code's detail in the UI, worded as "try again", so the user
retries instead of giving up or re-searching. The clients expose the envelope
to the route or cog without the UIs growing any business logic: the mapping is
a lookup from code to message.

**Non-goals.** Automatic retry in either UI. Changing the orchestrator or
downloader. Surfacing every error code (unknown codes keep the generic
message). Reading the envelope on GET routes, which already degrade to an
empty view. Extracting the client into a shared package (third consumer rule,
unchanged).

## Design

Both clients are copies of each other; the change is identical in both and
lands in each repo's `client/_base.py` and `client/_torrents.py`.

**Client.** `_post` gains a sibling, `_post_or_error`, that returns the parsed
success body, or a `GatewayError` when the answer is a non-2xx whose body
parses as the contracts `ErrorResponse`, or `None` on transport failure,
timeout, non-JSON, or an error body that does not parse. `GatewayError` is a
small model in each client's `schemas/errors.py` beside the `ErrorResponse`
re-export: `status_code: int`, `code: str`, `detail: str`. `download()` and
`redo()` (web) and `download()` (bot) switch to it and return
`DownloadResponse | GatewayError | None`. Every other client method is
untouched.

**Presentation.** One lookup per UI, `RETRYABLE_CODES`, a frozenset of the
codes whose detail is shown: `SOURCE_UNREACHABLE` and `TMDB_UNAVAILABLE`,
read from the services' public names as string constants in each UI's
`constants.py` (the UIs do not depend on service `ErrorCode` enums). A helper
`failure_message(result)` returns the gateway detail when `result` is a
`GatewayError` whose code is in the set, and the existing generic message
otherwise.

| Surface | Today | After |
|---|---|---|
| web `POST /downloads` | generic error fragment | detail for a retryable code, generic otherwise |
| web `POST /jobs/{id}/redo` | generic error fragment | same |
| bot torrent pick | generic, or VPN message after a `/health` probe | retryable codes show the detail without the probe; anything else keeps today's probe and messages |

The error fragment and the ephemeral Discord message are unchanged in shape;
only the text differs.

## Decisions

1. A returned `GatewayError`, not a raised exception. The clients' contract is
   "a value or `None`, never raises"; every route and cog is written against
   it. A third return type extends the contract without changing call sites
   that do not care.
2. Codes as string constants in each UI, not an import of a service
   `ErrorCode`. The UIs depend only on `medialab-contracts`, and the contracts
   package deliberately types `code` as a plain string. Two short constants
   are cheaper than a cross-service dependency.
3. The bot keeps its `/health` probe for the non-retryable path. Relaying
   `VPN_NOT_BOUND` through the gateway would make the probe redundant, but
   that is an orchestrator change and this spec touches only the UIs; a
   follow-up can add it and drop the probe.
4. Allowlist, not "show every detail". Details of unknown or 5xx-internal
   errors can carry paths or hashes meant for logs; the generic message stays
   the default.

## Open questions

None.

## Test plan

**medialab-web** `tests/test_client.py`: `download()` returns `GatewayError`
with code and detail on a 503 JSON error body; returns `None` on a non-JSON
503 and on a transport error; returns `DownloadResponse` on 202.
`tests/test_search_page.py`: the download route renders the detail for
`SOURCE_UNREACHABLE` and the generic message for an unknown code.
`tests/test_jobs_page.py`: the same for redo.

**medialab-bot** `tests/test_client.py`: same client cases. `tests/cogs` or
`tests/views`: the torrent pick sends the detail for `SOURCE_UNREACHABLE`, the
VPN message when the probe reports unbound, the generic message for an
unknown code, and skips the probe when the detail is shown.

## Rollout

Two independent PRs, web and bot, each with a `Changed` changelog entry and a
minor release. No orchestrator or downloader change. No host step.
