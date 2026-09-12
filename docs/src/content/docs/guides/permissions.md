---
title: Permissions
description: Approval prompts, remembered grants, and YOLO mode.
---

nimlet asks two different questions before it does anything. *Trust* decides
whether a project's own tools and settings load at all, and it is asked once per
folder. *Permissions* are this page: the question about one specific action, asked
while you work.

The short version: reading and editing files happen quietly, and running shell
commands asks the first time.

## What runs without asking

| Tool | Why |
| --- | --- |
| `read`, `grep`, `glob` | They only read your workspace |
| `edit`, `write` | They change files, but stay inside the workspace and you see the diff |
| `read_skill` | It loads a skill body |
| `ask_user` | It asks you, so prompting would be circular |

Everything else asks: `bash`, the read-only `git` tool, and any tool an extension
provides. The `git` tool asking looks odd until you notice it can be pointed at
any path in the workspace — and it only ever asks once, since the answer can be
remembered.

## The prompt

When a tool needs approval, the transcript grows a small keypad under the call:

```text
● bash
│   Allow bash: npm test
│   working
│   [enter] once
│   [s] session
│   [p] project
│   [n] deny
```

| Key | Choice | What it means |
| --- | --- | --- |
| `Enter` | once | Run this one time. Ask again next time. |
| `s` | session | Allow the same command until nimlet exits. |
| `p` | project | Also save the grant in `.nimlet/permissions.json`. |
| `n` | deny | Do not run it. |
| `Esc` | deny | The same as `n`. |

A few things worth knowing while the prompt is up:

- The turn is waiting, and the next keystroke belongs to the prompt. Letters that
  are not one of the keys do nothing rather than typing into the composer.
- Denying is not remembered. The model is told the call was denied, and in the
  next turn it can propose something else or explain what it wanted.
- If the command cannot be remembered, the keypad is shorter — just
  `[enter] once` and `[n] deny`. There is no session or project option to choose,
  because neither would be honoured.

## What a grant covers

What gets remembered is deliberately coarse, in two shapes:

- **`bash`** — the whole normalized command. Whitespace is collapsed, so
  `npm   test` and `npm test` are the same grant. Arguments and flags are part of
  the key, so `npm test` does not cover `npm test -- --watch`, and a redirect goes
  its own way: `npm test > /tmp/out` is a third grant.
- **Everything else** — the tool name: `tool:git`, or the name of the extension
  tool (`tool:lint`).

That is the whole model. There are no patterns, no wildcards, and no way to grant
`bash` in general — which is the point, since "any command" is the thing you do
not want to hand over by accident.

## Commands that are never remembered

Approvals for these are always re-asked, even with a session or project grant in
place:

```text
rm            git reset     git clean     git checkout --   git restore
sudo          curl          wget          ssh               scp
chmod         chown         kill          pkill             dd
mkfs          shutdown      reboot
```

The check is a word match on the lowercased command, not a shell parser. `sudo`
counts anywhere it appears, `rm -rf build && echo done` counts, and a command that
merely contains the word — `echo rm` — counts too. False positives here are cheap;
the alternative is trusting a command line that a shell will interpret.

If you genuinely want one of these to run without asking again, approve it once,
or reach for YOLO mode below. Do not add it to the file by hand and expect nimlet
to go along: the danger check happens before grants are consulted.

## Inspecting and clearing grants

```text
/permissions
```

prints what is currently granted, project grants first:

```text
Permission grants:
  project  bash:npm test
  session  tool:git
```

```text
/permissions clear
```

removes the project grants. Session grants stay until you quit, because they were
never written anywhere.

## Where project grants live

In the workspace you were working in:

```json title=".nimlet/permissions.json"
{
  "allow": [
    "bash:npm test",
    "tool:git"
  ]
}
```

- It is only read when you have trusted the project, so a repository cannot grant
  itself approvals.
- `/permissions clear` leaves the file in place with an empty `allow` list.
- It is an ordinary file: readable, editable, deletable. The order of the list
  does not matter.
- Grants outlive a rename. If an extension renames a tool, the old
  `tool:old-name` entry becomes dead weight — `/permissions clear` prunes it.
- Since it is a file in your repository, think about whether you want to commit
  it. A shared `bash:npm test` is usually fine; a shared grant for a deploy script
  is a decision for whoever clones next.

## YOLO mode

```text
/yolo
/yolo off
```

or start with `--yolo`. This skips every prompt for the current process, including
everything in the never-remembered list. It is never written to disk, the footer
shows `[yolo]`, and the startup banner says what is going on:

```text
YOLO mode: all tools auto-approved for this process
```

Two things it does *not* change: it does not add tools you do not have (file
tools are still confined to the workspace), and it does not affect plan mode,
which is checked before permissions ever come up. YOLO is for a scratch checkout
or a container. Everywhere else, `s` is usually what you meant.

## Plan mode

Plan mode does not prompt, because the tools available in it are the read-only
ones: `read`, `grep`, `glob`, `git`, `read_skill`, `ask_user`, plus extension
tools that declare read-only capabilities. They execute directly through a
separate tool list, so the permission policy is not consulted at all.

Your grants are not lost when you switch modes — they belong to the process, and
they are still there when you `/act` again. Extension hooks do not fire in plan
mode either, so nothing gets a chance to intervene.

## Runs without a prompt at all

With `-p`, `--mode json`, or `--mode rpc` there is no interface for a keypad, so
tools run without asking. Keep those runs pointed at workspaces you trust, and
narrow what is available when you can:

```sh
./nimlet -p "summarize the README" --tools read
```

The `approval_required` event in JSON mode is emitted by the interactive TUI; a
headless run has nobody to answer it, so it does not appear.

## Where to go next

- [Security](/guides/security/) for trust, and the honest list of limits
- [Plan and act mode](/guides/plan-and-act/) for the read-only tool list
- [Extensions and hooks](/guides/extensions-and-hooks/) for tools that ask, and
  what they can do
