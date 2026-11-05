# Process audit: toward one-shot delivery

A running log, kept while delivering MickMarch/medialab#162 (anime numbering).
It records:
- every point where work stopped for the user;
- every point where a specialist agent would have added value, or did.

The goal is a workflow where one approved spec runs to a deployable release
with no further prompts, apart from the gates that are deliberately kept.

## Human touchpoints

| # | Point | What was asked | Needed? | Proposal |
|---|---|---|---|---|
| H1 | Problem triage | Spec it, quick fix, manual grab, or discuss | Partly: a product direction | Default to "spec it" for `kind:feature`; ask only when the options differ in user-visible behaviour |
| H2 | Spec approval | Approve the Draft | Yes, the main design gate | Keep. Hand it over already reviewed by a design agent (A1) |
| H3 | Contracts merge and release | Merge #44 and cut a minor release | No: implied by H2 | Approving a spec authorizes merging and releasing its internal dependency PRs once CI and review agents pass |
| H4 | Batch release | (to come) | Yes, as the user requires | Keep, once per batch |
| H5 | Deploy | (to come) | Yes, since the host is shared | Keep |

Earlier this session, the same pattern showed up:
- "Merge, release, deploy" was asked per repo, for #69, #151, jellyfin #28,
  bot #64, setup #16 and others.
- Auto mode blocked one merge (#155) until the user said "Merge #155" in
  their own words. That is a tool permission, not a process need. Fix it in
  the settings allowlist.

## Agent opportunities

| # | Where | Agent | Why |
|---|---|---|---|
| A1 | Spec Draft, before H2 | Design reviewer, checking the spec against CLAUDE.md: UI scope, no version prediction, DRY across the domain boundary, decisions with a rejected alternative | Catches rule breaks before the user reads the spec |
| A2 | Every PR, before merge | PR reviewer (`cavecrew-reviewer`) | An independent read of the diff, not anchored on the author's view |
| A3 | Auth, secrets, webhooks, new endpoints, dependency bumps | `security-auditor` | Webhook #71 changed auth (constant-time key check, a route without an API key) and had no security review. The pip-audit failures were found only by CI |
| A4 | Tests-first step | A test author separate from the implementer | Tests that encode the spec, not the implementation |
| A5 | After deploy | Live verifier: doctor, smoke-test the new routes, check a real show | Earlier sessions verified by hand (route 403, version check) |
| A6 | Cross-repo | Drift and contract checker: pins, the shared model used consistently in every consumer | The setup contracts pin was stale (v1.3.0), found only when it broke |

## Log for #162

- H1, H2 and H3 happened as above.
- A1 was skipped: the spec went to the user unreviewed.
- A2 ran on torrent-downloader#58 (`cavecrew-reviewer`, about 3 minutes):
  0 blocking, 8 risks, 1 nit, 2 questions.
  - Fixed:
    - an unvalidated `group` id went into a TMDB URL path, so a crafted id
      could reach other endpoints with the server's key. A3 should have been
      the one to catch this.
    - the group cache was not keyed by language;
    - auto fetched every group up front, and one failing group broke it;
    - a magic number.
  - Accepted, with the reason recorded in the spec:
    - unpadded absolute searches;
    - an absolute match does not check the title, the same exposure as
      existing `SxxEyy` matches;
    - the tail extrapolation.
  - Lesson: a reviewer pass on every PR is cheap and found a real security
    issue the author missed. Run A3 automatically whenever a diff touches a
    URL built from user input, auth, or secrets.
- A2 ran on medialab-orchestrator#72 (about 6 minutes): 2 blocking, 8 risks.
  - Blocking, fixed:
    - a manual download and a follow job on the same episode did not match,
      so it would have downloaded twice;
    - rename failed open on a numbering outage, misfiling an episode for
      good.
  - Risks, fixed:
    - the migration wiped season states;
    - an unknown release code was given an invented season;
    - an episode grouped under specials was searched forever;
    - numbering was read twice per tick;
    - season decisions did not match the web's season rows. This one needed
      a web change: group by release season.
  - Accepted:
    - the absolute regex is copied in two services. The workspace rule is to
      extract on the third repetition.
    - the per-release-season count gate. The group is built from the TMDB
      listing, so the counts agree by construction.
  - Lesson: the author's own tests encoded the bugs. In both blocking cases
    the test asserted the wrong behaviour. A4 (a separate test author working
    from the spec) would likely have caught the scope mismatch before any
    code was written.
- H6: the user raised custom libraries mid-task. It was captured as #164 with
  no spec. No interruption was needed, because the user only stated intent.
