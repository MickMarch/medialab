# Spec: graphical install wizard over medialab-setup

Status: Approved
Issue: MickMarch/medialab#135

Allowed statuses: Draft, Approved, Shipped, Superseded. No implementation code
before Approved. No version numbers anywhere in a spec.

## Problem

`medialab-setup setup` reaches a green doctor from a fresh clone, but it is a
terminal conversation: a dozen prompts, hints in parentheses, a Y/n for every
browser URL. The operator this project is meant to be shared with does not
read terminals. Every value the wizard needs is already defined once in the
CLI: the asked fields and their guides, the live credential checks, the
template rendering, the phases. What is missing is a window.

## Goal and non-goals

**Goal.** A double-click on the clone opens a browser window that walks the
operator through install: a prerequisites page, one credentials page with an
entry field for every required value and an info control beside each field
explaining how to get it, a run page streaming build and provision output,
and a result page showing the doctor. The wizard is a front end over the
existing phases in `medialab-setup`; it adds no second implementation of any
rule. An advanced toggle on the credentials page reveals the optional values
and template tunables that `setup --custom` asks.

**Non-goals.** `update` and the host autostart steps stay CLI-only in this
release (follow-up items on the board). A packaged executable (no Git, no
Python) is its own issue. A native window frame; the page runs in the default
browser. Anything that needs the stack running: the wizard runs before the
containers exist, so it cannot live in medialab-web.

## Design

### Launch

`setup.cmd` at the workspace root is the double-click target. It checks for
`uv` and installs it through `winget` when missing (the same package the
CLI's preflight would install), then runs
`uv run --project medialab-setup medialab-setup wizard`. The `wizard`
command starts a FastAPI app on a random loopback port, opens
`http://127.0.0.1:<port>/` in the default browser, and exits when the
operator closes the result page or after an idle timeout. Only loopback is
bound; the page carries a per-run token in every request so another local
process cannot drive it.

### Pages

| Page | Shows | Backed by |
|---|---|---|
| Prerequisites | the preflight table live, with an Install button per missing item that runs the winget install and re-probes | `Preflight`; installs reuse `_install` with the page as the prompter |
| Credentials | one field per asked value; required ones marked; an info control per field; an Advanced toggle revealing optional values and the unbound template keys with their template comments as help | `ASKED_FIELDS`, `REQUIRED_FIELDS`, `GUIDES`, the `.env.example` templates |
| Run | a plan table (files to create or update), then streamed output of build, provision and the Jellyfin step | `render_all`, `files_table`, `run_build`, `run_provision` |
| Result | the doctor table, green or not, with the retry window shown as a countdown; a link to the web UI when green | `wait_for_doctor` |

The credentials page is the one the issue asks for. Each field has:

- a label from the guide's title, a placeholder from `looks_like`, and
  `type=password` for secret fields with a show toggle;
- an info control (`?` button) that opens a popover with the guide's numbered
  steps and a link to the console URL opening in a new tab; the same text the
  CLI prints;
- inline validation on blur for fields with a live check (TMDB, Jellyfin,
  Discord): a request to `/check/<field>` runs `CredentialChecker.run` and the
  field shows accepted, rejected with the HTTP status, or unverified when the
  service is unreachable;
- prefill from an existing `.env` or answers file, shown as "already set"
  for secrets with an empty field that keeps the current value when left
  blank, exactly as the CLI's custom mode does.

Submit is disabled until every required field is non-empty and no field is
in the rejected state.

### Reuse

The wizard is a package `medialab_setup.wizard` with routes, templates and a
`WebPrompter`. `WebPrompter` implements the `Prompter` protocol: `text` and
`secret` answer from the submitted form, `confirm` answers from the button
that was clicked, `note` appends to the page's log. With that object the
existing `collect`, `run_preflight`, `run_generate`, `run_build`,
`run_provision` and `wait_for_doctor` run unchanged. Long-running phases run
in a background task; the page polls a `/events` endpoint for appended log
lines and phase transitions (htmx, as medialab-web uses).

Stack: FastAPI, Jinja2, htmx, uvicorn, the same as medialab-web, so the two
share conventions. No JavaScript framework. The CLI commands keep working
and keep their tests; the wizard adds route tests with FastAPI's test client
and a fake shell, the same fakes the CLI tests use.

### Security

Loopback only. A random token minted at start is embedded in the page and
required on every POST; a missing or wrong token is 403. Secrets are posted
once, written to their `.env` through the existing atomic writer, and never
echoed back: the page shows "set", not the value. No secret appears in a URL,
a log line or the events stream. The server exits when the run finishes or
when idle, so nothing listens after setup.

## Decisions

1. **A local web page, not a native toolkit.** Same stack as medialab-web,
   no native dependency, testable with the project's existing patterns, and a
   native frame (pywebview over the same page) can be added later without a
   UI rewrite. Rejected Tkinter: more code per field, dated look. Rejected a
   TUI: still a terminal, which is the problem being solved.
2. **`setup.cmd` bootstrap, exe later.** A tiny script that installs `uv`
   through `winget` and runs the wizard removes the Python knowledge
   requirement; it still needs Git to clone. A packaged executable removes
   Git too but brings a build pipeline, signing and antivirus questions, so
   it is a separate issue.
3. **Install only in this release.** Prerequisites, credentials, run, result.
   `update` and host steps are CLI-only until their own pages are specified.
4. **One credentials page, advanced toggle.** Required values are few enough
   to fit one screen; optional values and tunables hide behind a toggle rather
   than extra steps, matching express and custom in the CLI.
5. **The wizard owns no rules.** Field list, help text, checks, rendering and
   phases come from the CLI modules through the `Prompter` protocol. A new
   setting in a service template appears in the advanced section with no
   wizard change.
6. **Validate on blur with the existing checks.** Rejected validating only on
   submit: the operator should learn a bad key while the console tab is still
   open.

7. **Idle timeout of ten minutes after the result page.** Long enough to read
   the doctor and open the web UI, short enough that nothing listens on the
   host for long. Rejected no timeout: a forgotten server is a listening
   process with the run token in memory.
8. **No host-steps toggle on the Run page.** Host steps are out of scope for
   this release; the result page links to `docs/host-setup.md` and names the
   CLI command that applies them. Rejected a disabled toggle: a control that
   does nothing invites a bug report.
9. **Docker Desktop sign-out handled with a message, as the CLI does.** The
   prerequisites page installs it, says a sign-out is needed, and tells the
   operator to reopen `setup.cmd` afterwards; preflight is re-derived on the
   next run. Rejected forcing a sign-out from the page: the installer must
   never end the operator's session.

## Open questions

None. The draft's three questions were accepted as proposed and recorded as
decisions 7 to 9.

## Test plan

`medialab-setup`, pytest, FastAPI test client, `FakeShell` and a fake
checker, no network:

- `test_wizard_requires_token`: POST without the token is 403.
- `test_credentials_page_lists_every_asked_field_with_help`: one input and one
  info control per `ASKED_FIELDS` entry; required ones marked; guide steps
  and URL present in the popover markup.
- `test_advanced_section_lists_unbound_template_keys` with template comments
  as help.
- `test_blur_check_returns_states`: accepted, rejected with status, unverified.
- `test_submit_disabled_rules`: server-side rejection of a submit with a
  missing required field or a rejected check.
- `test_submit_renders_env_files_without_echoing_secrets`: files written
  through the atomic writer; page and events stream contain no secret value.
- `test_run_streams_phase_output_and_result`: fake streams produce log lines
  and a final doctor-green result; a failing doctor shows the failure.
- `test_prefill_from_existing_env_marks_set_and_keeps_on_blank`.
- `test_server_exits_on_idle` with the clock faked.
- Root `bin/tests`: `setup.cmd` is present and references the wizard command
  (string check; the script itself is exercised by hand on the host).

## Rollout

1. `medialab-setup` PR: `wizard` command, routes, templates, `WebPrompter`,
   tests. CLI unchanged.
2. Root PR: `setup.cmd`, README "Running" gains the double-click path above
   the CLI path, this spec to Shipped.
3. Acceptance on the host with the recipe in
   `docs/specs/setup-and-update-cli.md` (scratch clone, own compose project,
   live media root), driven through the browser instead of the terminal.
