---
title: Skills
description: Passive Markdown capabilities the model loads only when needed.
---

A skill is a folder containing a `SKILL.md`: a written procedure the model can
pick up when a task calls for it. Cutting a release, reviewing a migration,
following your team's debugging checklist. It is just Markdown — a skill can
describe commands, but it cannot run anything.

What makes skills worth the extra file layout is *when* they cost something. Only
the name and description are in the request; the body stays on disk until
something asks for it.

## Where skills live

```text
~/.agents/skills/review/SKILL.md          portable, shared with other agents
~/.nimlet/skills/review/SKILL.md          your global nimlet skills
<workspace>/.agent/skills/review/SKILL.md
<workspace>/.agents/skills/review/SKILL.md
<workspace>/.nimlet/skills/review/SKILL.md
```

nimlet searches those roots in that order, and a later root overrides an earlier
one with the same name. So a project can override one of your global skills, and
inside a project `.nimlet/skills` wins over `.agent/skills` and `.agents/skills`.

The project roots are only searched when you have trusted the project, since
skills arrive with the repository. Your own skill folders are always available.

Each skill is a directory that contains a file called exactly `SKILL.md`. The
directory name becomes the skill name, and frontmatter can override it.

## A minimal skill

```text
.nimlet/skills/release/SKILL.md
```

```markdown
---
name: release
description: Cut a release, tag it, and update the changelog.
---

1. Check `git status` is clean.
2. Bump the version in `nimlet.nimble` and commit it.
3. Run `nimble test`, then `git tag v$VERSION` and push the tag.
4. Add the release notes to `CHANGELOG.md`.
```

Note the shape: the description says *when* to reach for this, and the body says
*how*. The model reads the description to decide.

## What reaches the model at startup

Only names and descriptions, in this form:

```text
Available skills (use read_skill with the skill name to load one):
- release: Cut a release, tag it, and update the changelog.
- review: Review a diff for correctness and style.
```

A folder of twenty skills you never use costs twenty lines on every request.

Metadata is read from the first 64 lines of each `SKILL.md`. If there is no
frontmatter, the name comes from the directory and the description from the first
non-empty line that is not a heading.

## Loading a skill

There are two ways in.

**The model asks for it.** When a description matches what you asked for, the
model calls the `read_skill` tool, which returns the whole file:

```text
Skill: release

1. Check `git status` is clean.
...
```

**You ask for it.** `/skill:<name>` loads the skill into the next message
immediately, whether or not the model would have picked it. Anything you type
after the name is appended to the request:

```text
/skill:release version 0.4.0 only
```

Loads the release skill and adds "version 0.4.0 only" to the end of the message.
The model receives `Follow the "release" skill.` followed by the file body.

`read_skill` works in plan mode too — loading instructions does not change
anything on disk.

## Which files are read

Frontmatter is optional and can contain `name` and `description`:

```markdown
---
name: review
description: Review a diff for correctness and style.
---
```

Both are plain `key: value` lines; the values can be quoted. Anything else in the
frontmatter is left alone. Unlike prompt templates, the whole file is sent when
the skill loads, so the frontmatter is part of what the model sees — a few extra
lines, nothing more.

Without frontmatter:

- the name is the directory name
- the description is the first non-empty line that is not a heading

Matching is case-insensitive, so `/skill:Review` finds `review`. Avoid spaces in
skill names: `/skill:code review` cannot be parsed as a command, and skills whose
names contain a space are left out of the completion list. A model can still load
them by name, since its own list includes them — but you cannot type them.

## Size, caching, and edits

- A skill up to 100,000 bytes loads normally. A larger one stays in the list but
  loading it returns an error instead of a partial file:
  `skill is too large (maximum 100000 bytes)`.
- Body edits take effect on the next load, because the file is read from disk
  each time it is requested.
- The name and description list is cached until it is rebuilt. Run `/reload` (or
  `/new`, or restart) after adding a skill directory or changing a description,
  and the metadata shows up. Changing trust in a project rescans as well.

## How skills differ from the other extension points

| Mechanism | What it is | When it reaches the model |
| --- | --- | --- |
| `AGENTS.md` | Rules for the whole project | Every request |
| Skill | A procedure in Markdown | When the model calls `read_skill` or you run `/skill:<name>` |
| Prompt template | A message you send | When you type the command |
| Extension | A program with tools and events | Its tools whenever the model calls them |

The practical split: put things that are true all the time into `AGENTS.md`, put
procedures into skills, and put anything that needs to *do* something into an
extension.

## Writing a skill that gets used

- **Make the description a trigger.** "Cut a release, tag it, and update the
  changelog" beats "release stuff" — the model chooses from that sentence alone.
- **Write steps, not background.** Numbered actions with real commands beat
  explanation, because the model already knows what a release is.
- **Name the files and commands.** Exact paths save a round of searching.
- **Keep the file lean.** It is loaded whole when it is used, and every line
  competes for the model's attention with the actual task.
- **One skill, one procedure.** A skill that covers releasing *and* hotfixes gets
  loaded at the wrong time and read past.

## Where to go next

- [Instructions](/guides/instructions/) for the always-on guidance
- [Prompt templates](/guides/prompt-templates/) for shortcuts you type yourself
- [Extensions and hooks](/guides/extensions-and-hooks/) when a skill needs to run
  something
