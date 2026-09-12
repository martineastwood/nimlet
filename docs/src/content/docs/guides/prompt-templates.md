---
title: Prompt templates
description: File-backed prompts that become slash commands.
---

A prompt template is a Markdown file whose name becomes a slash command. Where a
skill is something the model loads for itself, a template is a message *you*
send: write the request once, reliably, and stop retyping it.

## Making one

```text
~/.agents/prompts/review.md                 portable, shared with other agents
~/.nimlet/prompts/review.md                 your global templates
<workspace>/.agent/prompts/review.md
<workspace>/.agents/prompts/review.md
<workspace>/.nimlet/prompts/review.md
```

nimlet searches those roots in that order, and a later root overrides an earlier
one with the same name, so a project can ship a `/review` that replaces yours.
The project roots are only searched when you have trusted the project. Your own
`~/.agents/prompts` and `~/.nimlet/prompts` are always available.

Discovery is flat: only `*.md` files directly inside a prompts directory count.
Subdirectories are not walked, so grouping templates into folders is not a thing —
use a filename prefix like `db-migrate.md` instead.

The filename, minus `.md`, is the command name exactly: `review.md` gives you
`/review`, and `fix-parser.md` gives you `/fix-parser`. A filename with a space
in it cannot be typed as a command, so use dashes.

## A template with arguments

```markdown title="~/.nimlet/prompts/review.md"
---
description: Review my changes for correctness and style.
---

Review the current diff. Correctness first, then readability.

Extra focus: $ARGUMENTS
```

Typing `/review` sends the body as written. Typing `/review the parser edge cases`
replaces `$ARGUMENTS` with everything after the command:

```text
Review the current diff. Correctness first, then readability.

Extra focus: the parser edge cases
```

`$@` is an alias for `$ARGUMENTS`, and both are replaced everywhere they appear,
so a template can use one several times. The substitution is plain text: there is
no quoting, escaping, or shell interpretation. If you use `$ARGUMENTS` inside a
code block in the body, it is replaced there too.

With no arguments the placeholders become empty, which usually reads awkwardly. If
a template only makes sense with input, say so in the body — for example, "If no
focus is given, review the whole diff."

## Frontmatter and the command name

Frontmatter is optional:

```markdown
---
description: Explain the change under discussion to a newcomer.
---
```

- Only `description` is read from it, and it is what the completion menu shows as
  you type the command. If you leave it out, the first non-empty line of the body
  is used instead.
- The frontmatter itself is not sent. The message is the body after the closing
  `---`.
- A file with frontmatter but no body registers nothing. There has to be
  something to send.

Both description and body are read as plain text from the top of the file, so
keep the useful parts near the beginning.

## Names and collisions

For a bare `/name`, nimlet resolves in this order:

1. built-in commands
2. extension commands
3. prompt templates

That means built-in names are reserved. A `prompts/plan.md` never runs, and it is
not even offered in completions — the built-in `/plan` wins and the file is
silently ignored. Rename it to `/plan-fix` or similar. The same applies if an
extension registers a command with the same name as your template.

Skills never compete for bare names: they live in the `/skill:` namespace. So
`prompts/review.md` and `skills/review/SKILL.md` coexist happily, as `/review`
and `/skill:review`.

## Size, mentions, and nesting

- Files over 100,000 bytes are ignored entirely: no command, no warning. Keep
  templates small; a long template is usually a skill in disguise.
- `@path` mentions work in the body, exactly as they do when you type them. The
  file contents (or a folder listing) are attached to the message.
- Templates are not recursive. A body containing another `/command` line is sent
  to the model as text, not run as a command.
- The expanded text is an ordinary user message, saved in the session like
  anything else you type, so `/review` costs one message and nothing more.

## When to use which

| You want | Use |
| --- | --- |
| The same request phrased the same way each time | A prompt template |
| The model to choose a procedure when the task calls for it | A skill |
| Rules that always apply to a project | `AGENTS.md` |
| Something that must actually run | An extension |

Templates are yours to send; skills are the model's to load. When you notice
yourself typing the same paragraphs twice, a template is usually the fix — and
when you notice the model reaching for the wrong procedure, that is a skill
description to sharpen.

## Where to go next

- [Skills](/guides/skills/) for procedures the model loads on demand
- [Commands and shortcuts](/reference/commands/) for the built-in command list
- [Instructions](/guides/instructions/) for always-on project guidance
