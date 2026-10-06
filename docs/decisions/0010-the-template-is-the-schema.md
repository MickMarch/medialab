# 0010 - The template is the schema

Date: 2026-10-06. Context: the install and update CLI
(`docs/specs/setup-and-update-cli.md`, MickMarch/medialab#23 and #129).

## What happened

The first design for the setup tool had it own a list of every service
setting: name, type, default, help text, which file it goes in. That list
would have been the third copy of each setting, after the service's
`pydantic-settings` class and its `.env.example`, and every new setting
would have needed a tool release before `setup` could write it.

Instead the tool treats each service's `.env.example` as the schema. It
parses the template in order, keeps every comment as the prompt help, takes
each default as the default, and renders the `.env` from it. Keys that exist
in the live file but not in the template survive under a marker; keys the
template gained are appended with their default. The tool itself knows only
which keys are secrets, which are shared across files, and where to get the
credentials, in one binding table.

## The lesson

When a file is already the authoritative list of something, read it; do not
restate it. A service adding a setting changes one file, and `setup`,
`update`'s migration and the custom-mode prompts all pick it up with no
change to the tool. The template's comments became documentation the
operator sees at the moment they need it, which made them better.

## How to apply

- Before adding a table of names to a tool, ask which existing file already
  holds them and whether parsing it is cheaper than keeping two in step.
- Treat comments in a template as user-facing text and write them that way.
- Keep the one table the tool does own small and tested against the files it
  describes: every binding must name a real key in a real template.
