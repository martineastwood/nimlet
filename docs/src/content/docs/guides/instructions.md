---
title: Instructions
description: Project and global AGENTS.md guidance for the agent.
---

A coding agent that does not know your conventions will guess at them. nimlet
reads instruction files from your project and puts them in front of the model on
every request, so "run `npm test`", "tests live in `tests/all_tests.js`", or "do
not touch the generated client" are known before the first tool call rather than
discovered by trial and error.

This page covers where those files are found, how they are ordered, and how to
write ones that help.

## Which files are read

In each directory, nimlet looks for **one** file, first match wins:

1. `AGENTS.override.md`
2. `AGENTS.md`
3. `CLAUDE.md`

Two places are searched:

- `~/.nimlet/` - your personal guidance, applied to every project you work in
- every directory from your workspace **up** to the repository root

The override file wins over `AGENTS.md` in the same directory, which is handy for
local rules you do not want to commit: put them in `AGENTS.override.md` and add
that name to `.gitignore`. `CLAUDE.md` is read as a fallback, so existing Claude
Code guidance works without renaming anything.

## Ordering

Less-specific files come first, more-specific files last. For this layout:

```text
~/.nimlet/AGENTS.md                 global: be terse, prefer minimal diffs
~/code/monorepo/                    repository root (has .git/)
├── AGENTS.md                       use npm; run npm test
└── backend/                        ← you start nimlet here
    └── AGENTS.md                   backend speaks to Postgres; tests in tests/
```

the workspace-wide preamble in the request looks like this:

```text
Project instructions. Apply less-specific files before more-specific files:

<file path="global">
Be terse. Prefer minimal diffs.
</file>

<file path="../AGENTS.md">
Use npm. Run `npm test` before claiming a change works.
</file>

<file path="AGENTS.md">
The backend speaks to Postgres. Integration tests live in tests/all_tests.js.
</file>
```

Labels are relative to your workspace, which is why the repository-root file reads
`../AGENTS.md` when you started in a subdirectory. The personal file is always
labelled `global`.

The ordering rule is also stated to the model, so a repository-wide convention
does not get overridden by a stale sentence in a narrower file.

## Where the walk stops

- It stops at the directory that contains `.git` (either a directory or a file -
  worktrees and submodules use a file). Anything above the repository root is not
  read.
- If there is no `.git` anywhere above the workspace, the walk continues to the
  filesystem root, so an `AGENTS.md` in your home directory would be picked up.
- Directories *beside* your workspace are not read. Starting in `backend/` never
  loads `frontend/AGENTS.md`.

## Files below your workspace load when they are needed

A monorepo-wide prompt should not carry every team's rules. If you start nimlet at
the repository root and it reads `backend/src/server.js`, nimlet looks for
instruction files between the workspace and that file's directory and attaches
what it finds to the read result:

```text
Instructions for the requested path:
<file path="backend/src/AGENTS.md">
Migrations live in backend/src/db/migrations. Never edit files in db/generated.
</file>
```

These arrive with the tool result rather than in the system prompt, and each file
is sent once per session: reading a second file in the same subtree does not
repeat it. Only `read` triggers this - `grep` and `glob` results do not carry
instructions.

## Size, caching, and when edits land

- Each file is capped at 64 KiB. Longer files are cut and end with
  `[instructions truncated]`.
- Instructions sit in the stable part of the request prefix, before the small
  per-turn mode line, so providers with prompt caching can reuse them across
  turns. That is the reason to keep them stable: a date, a ticket number, or a
  branch name that changes every turn makes the prefix uncacheable and costs you
  money.
- Edits are picked up on the next turn. The cache is keyed on file modification
  times, and `/reload`, `/new`, `/resume`, and a trust change clear it outright.
  There is no restart involved.
- Plan mode loads them exactly the same way.

## Replacing or extending the built-in prompt

Two more files let you change the system prompt itself:

| File | Effect |
| --- | --- |
| `.nimlet/SYSTEM.md` | Replaces the built-in system prompt (requires a trusted project) |
| `~/.nimlet/SYSTEM.md` | Same, for every project; used when the project has no replacing file or is not trusted |
| `.nimlet/APPEND_SYSTEM.md` | Appended after the base (or replaced) prompt (requires a trusted project) |
| `~/.nimlet/APPEND_SYSTEM.md` | Same, globally |

:::caution[Replacing the system prompt is heavy]
`SYSTEM.md` removes the built-in rules that keep the agent in your workspace,
make it read files before editing them, and tell it to treat file contents as
information rather than instructions. You keep the mode line, project
instructions, and skill metadata, but nothing else. Almost everyone wants
`APPEND_SYSTEM.md` instead - and `AGENTS.md` before either.
:::

Trust is checked for the project copies only. `.nimlet/SYSTEM.md` and
`.nimlet/APPEND_SYSTEM.md` in a project you have not trusted are ignored, while
project `AGENTS.md` files are read either way. Trust changes rescan system prompt
files, but project configuration values are loaded at startup. See
[Security](/guides/security/) for what trust covers.

## Writing instructions that help

- **Keep them short.** Every line is sent on every request, in a spot where cache
  reuse depends on them not changing.
- **Write rules, not essays.** "Run `npm test` before reporting success" beats
  three paragraphs about testing philosophy.
- **Put commands and paths in them.** The agent's own guesses about your build
  system are the most common source of wasted turns.
- **Point at files instead of restating them.** "Follow the patterns in
  `src/session.js`" stays true as the code changes; a copied-out API does not.
- **Put narrow rules in narrow places.** A nested `AGENTS.md` next to the files it
  governs only loads when someone reads those files, so it cannot mislead work
  elsewhere in the repository.
- **Do not put secrets in them.** They are sent to your model provider with every
  request, and stored in session transcripts.

## Related mechanisms

| Mechanism | Where it lives | When it reaches the model |
| --- | --- | --- |
| `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md` | global, plus every directory from the repository root to the workspace | every turn, in the system prompt |
| Nested instruction files | directories below the workspace | attached to a `read` result, once per session |
| `SYSTEM.md` / `APPEND_SYSTEM.md` | `.nimlet/`, `~/.nimlet/` | every turn, replacing or extending the system prompt |
| Skills | `.nimlet/skills/<name>/SKILL.md` and friends | name and description always; the body only when loaded (`read_skill` or `/skill:<name>`) |
| Prompt templates | `prompts/*.md` | only when you run the slash command |

## Where to go next

- [Skills](/guides/skills/) for reusable procedures the model loads on demand
- [Prompt templates](/guides/prompt-templates/) for shortcuts you type yourself
- [Security](/guides/security/) for trust, and what project files can do
