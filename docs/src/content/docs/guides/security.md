---
title: Security
description: What nimlet asks before it acts, what it does on its own, and what is still your call.
---

nimlet can read your files, change them, and run shell commands. That is the whole
point of a coding agent, and it is also why it is worth knowing exactly where the
guardrails are before you point it at a project.

Two different questions get answered before nimlet does anything:

1. **Should this project's customizations load at all?** A repository can bring
   its own tools, extensions, skills, and system prompts. Those change how the
   agent behaves, so nimlet asks once per folder. This is *trust*.
2. **Should this particular command run?** Shell commands, the Git tool, and
   extension tools ask the first time you use them. This is *permissions*.

Here is the short version, then the details.

## The short version

| What is happening | What nimlet does |
| --- | --- |
| Reading, searching, or editing files in your workspace | Runs without asking |
| Running a shell command, the Git tool, or an extension tool | Asks the first time |
| Running something like `rm`, `sudo`, or `git reset` | Always asks, even if you allowed it before |
| Working in plan mode | Only read-only tools are available |
| Opening a project that ships tools, extensions, skills, or config | Asks first; nothing loads until you say yes |
| `-p`, `--mode json`, `--mode rpc` | There is nobody to ask, so tools run without prompts |

## Trust: the project you just opened

Most repositories are just code, and nimlet opens them without a word. But a
repository can also carry nimlet settings of its own. For example, a checkout
might contain:

```
.nimlet/config.json
.agents/extensions/lint/extension.json
.nimlet/skills/review/SKILL.md
```

These are not inert text. An extension is a program that can run while nimlet is
open, a `config.json` can point the agent at a different endpoint or model, and a
`SYSTEM.md` can rewrite its instructions. That is useful in a repository you
control, and a bad day in one you just cloned to look at. So the first time you
start nimlet in a folder that contains any of them, it asks:

```
This project has optional Nimlet customizations:
  1 project tool
  1 project extension
  1 project setting, prompt, or skill file
Extensions may run while Nimlet is open; tools run only when used.
Nimlet works normally with its built-in tools if you choose No.
Load these customizations for this workspace? [y/N]
You can change this later with /trust on or /trust off.
```

The default is No, so pressing `Enter` right away keeps your machine unchanged:
nimlet uses its built-in tools and ignores the project's own setup. You can still
work in the repository normally.

These are the files that trigger the question:

- `.nimlet/config.json` and `.nimlet/permissions.json`
- `.nimlet/SYSTEM.md` and `.nimlet/APPEND_SYSTEM.md`
- tools: `.agent/tools/<name>/tool.json`, `.nimlet/tools/<name>/tool.json`
- extensions: `.agents/extensions/<name>/extension.json`,
  `.nimlet/extensions/<name>/extension.json`
- skills under `.agent/skills`, `.agents/skills`, `.nimlet/skills`
- prompt templates under `.agent/prompts`, `.agents/prompts`, `.nimlet/prompts`
- themes: `.nimlet/themes/*.json`

Your answer is remembered in `~/.nimlet/trust.json`, keyed by folder. A folder
you trust also covers everything inside it, so one answer at a monorepo root is
enough for every package underneath.

You can change your mind later:

- `/trust` shows whether this project's resources are loaded.
- `/trust on` enables them now, and `/trust off` disables them. Tools, skills,
  prompts, extensions, and system prompt files are rescanned without a restart.
  Project configuration was merged at startup, so restart nimlet to apply or
  remove project config values and to change the config write target.
- `--approve` answers yes for one run, `--no-approve` answers no.

:::note
Trust only covers files inside the project. Your own tools, skills, extensions,
and prompts in `~/.nimlet/` always load - they are yours, and they follow you
between projects.
:::

## Permissions: the command you did not ask for

Reading a file, searching the workspace, and editing code happen without a
prompt. If you asked the agent to fix a failing test, being interrupted to
approve each `read` would be noise, and the diff is shown to you anyway.

Shell commands, the Git tool, and extension tools are different: they can do
anything your user can do, so nimlet asks the first time you see a particular
one.

| Key | Choice | What it means |
| --- | --- | --- |
| `Enter` | once | Run this one command. Ask again next time. |
| `s` | session | Allow the same command until you quit nimlet. |
| `p` | project | Also save the grant in `.nimlet/permissions.json`. |
| `n` | deny | Skip it. The model is told the call was denied. |

Denying does not remember anything, so the next turn will ask again if the model
tries the same thing.

What gets remembered is deliberately coarse:

- For `bash`, the whole normalized command - so `ls   -la` and `ls -la` are the
  same grant, but `npm test` and `npm run build` are two different ones.
- For everything else, the tool name: `git`, or the name of the extension tool.

### Some commands are never remembered

A few patterns are always asked about, even when you already have a session or
project grant:

```
rm  git reset  git clean  git checkout --  git restore  sudo  curl  wget
ssh  scp  chmod  chown  kill  pkill  dd  mkfs  shutdown  reboot
```

Pressing `s` or `p` on one of these does not stick. That is on purpose: a
remembered `rm` grant would apply to every future `rm` in that folder, which is
not a decision you want to make once and forget.

Use `/permissions` to see what is currently granted, and `/permissions clear` to
drop the grants saved for this project.

:::note
The grants in `.nimlet/permissions.json` are only read when you have trusted the
project. If you answer No to the trust question, a file that grants itself broad
approvals has no effect.
:::

### YOLO mode

`/yolo` (or starting with `--yolo`) skips every prompt for the current process,
including the always-ask list. `/yolo off` returns to normal prompting. The mode
is never written to disk, the footer shows `[yolo]`, and the startup banner says
so:

```
YOLO mode: all tools auto-approved for this process
```

It is genuinely useful in a scratch checkout or a container where there is
nothing to lose. Everywhere else, `s` is usually what you actually want.

## Plan mode

Plan mode is a read-only mode for looking around before you commit to anything.
It exposes file reads, searches, the read-only Git tool, skills, and questions to
you - plus extension tools whose manifest declares only read-only capabilities.
Everything else is unavailable, and the model gets a clear error if it tries:

```
Tool unavailable in plan mode. The user must switch to /act to enable implementation tools.
```

Shell commands, file edits, hooks, and hosted web search are all out of reach
until you switch to act mode, either with `/act` or `Shift+Tab`. If you are
opening a repository you have not read, start in plan mode and look around
first.

## The workspace boundary

File tools - `read`, `write`, `edit`, `grep`, `glob`, and `git` - resolve paths
against your workspace and refuse anything that escapes it, including through a
symlink:

```text
read ../../etc/passwd
path is outside the workspace: ../../etc/passwd
```

Shell commands are not confined that way:

```text
bash: cat ../notes.txt
```

That works, because the shell runs as you, in your workspace, with your
environment. The filesystem check is a guardrail against a confusing path, not a
sandbox.

## What nimlet does not do

It is worth being plain about the limits.

**It is not a sandbox.** Everything nimlet runs, runs as your user, with your
environment, on your machine. If a command can delete your home directory from a
terminal, it can do the same here once approved. For work you do not want to
risk, run nimlet inside a container or a virtual machine.

**It cannot tell instructions from content.** A README, a test fixture, a GitHub
issue, or a fetched web page can contain text that reads like instructions to the
model. That is prompt injection, and no agent is immune to it. Habits that help:
read the diff before you accept a change, stay in plan mode while reading content
you do not trust, and grant per session with `s` while you are still deciding.

**It does not look for secrets.** `read` returns `.env` as happily as any other
file, and nimlet does not scan output or transcripts for tokens and redact them.
Sessions are plain JSONL files under `~/.nimlet/sessions/` unless you pass
`--no-session`, so anything you paste into the prompt is written there. Keep
secrets out of the workspace and store them in the private auth file or pass
them by environment variable:

```json title="~/.nimlet/auth.json"
{
  "openai": { "type": "api_key", "key": "sk-..." }
}
```

`--api-key` never writes the key anywhere, but it does land in your shell
history, so prefer the auth file or an environment variable. `/doctor` prints
the endpoint without credentials or query parameters, and reports only whether
each key is set - never its value.

**Extensions are programs, not settings.** A project extension runs as your user,
and an extension can start when nimlet starts, before you have seen any output
from it. Skim the manifest and the script before you answer yes to the trust
question. If a hook fails, the failure is reported as a warning and the tool call
continues.

**Headless runs have no prompts.** With `-p`, `--mode json`, or `--mode rpc`
there is no interface to ask, so tools execute without stopping. Use them on
workspaces you trust, and narrow what is available when you can:

```sh
nimlet -p "summarize the README" --tools read
```

**Your work leaves your machine.** Whatever the model reads - file contents,
command output, your prompts - is sent to the provider you configured, under that
provider's terms. nimlet's only other network call is a best-effort background
refresh of the [models.dev](https://models.dev) catalog when its local copy is
missing or over a day old; `/models refresh` does the same fetch on demand, and
hosted web search (`/web on`) is performed by the provider, which is why it is
only offered in act mode.

## A few habits that hold up

- Read the trust prompt before answering it the first time in a repo.
- Start in plan mode when the code is unfamiliar.
- Use `s` while experimenting and `p` when you have decided.
- Run `/permissions` occasionally. It is cheap.
- Keep risky work in a container, and keys in the environment.
- In scripts and CI, prefer `--tools read` and never store keys in the repo.

## Where to go next

- [Permissions](/guides/permissions/) for the prompt keys and grant storage
- [Plan and act mode](/guides/plan-and-act/) for the read-only mode in detail
- [Files and directories](/reference/files-and-directories/) for what nimlet
  writes, and where
