---
title: Quickstart
description: Set an API key and run your first turn with nimlet.
---

This guide assumes the `nimlet` binary is already installed and available on
your `PATH`. Give it a provider credential, then run it from the workspace you
want the agent to inspect or change. No language toolchain or source checkout is
required to use nimlet.

## Configure provider access

```sh
export OPENROUTER_API_KEY=your-key
```

OpenRouter is the default provider. You can use another wired provider by
exporting its key, then selecting it with `--provider` or `/provider`:

| Provider | Credential environment variable |
| --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` |
| Google Gemini API | `GEMINI_API_KEY`, `GOOGLE_API_KEY`, or `GOOGLE_GENERATIVE_AI_API_KEY` |
| Hyper | `HYPER_API_KEY` |
| Mistral | `MISTRAL_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| OpenCode Go or Zen | `OPENCODE_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| Codex | Sign in with `/login` inside nimlet |

You can store credentials in `~/.nimlet/auth.json` instead. See
[configuration](/guides/configuration/) for the file format and provider
options.

## Start your first turn

Run nimlet from the project directory:

```sh
cd /path/to/your/project
nimlet
```

Try a small request:

```text
Explain how this project runs its tests, then suggest the smallest useful fix
for the failing parser test.
```

The interactive footer shows the active provider, model, thinking level,
context usage, token totals, cost when model pricing is known, and queued
messages. File reads, searches, and workspace edits are built in. Shell
commands normally ask for approval the first time.

## One-shot and piped input

Pass a prompt after the flags for a turn that exits when it finishes:

```sh
nimlet fix the failing parser test
```

Use `--interactive` to run that initial prompt and then keep the REPL open:

```sh
nimlet --interactive inspect the parser tests
```

Use `--print` when stdout must contain only the final response. Warnings and
errors go to stderr:

```sh
nimlet --print "Summarize the current README"
cat README.md | nimlet --print "Summarize this text"
```

Piped input is added before the optional command-line prompt. Use
`--no-session` for a run that is not written to the session directory.

## Next steps

- [Interactive TUI](/guides/interactive-tui/) for queues, mentions, and keybindings
- [Models and providers](/guides/models-and-providers/) to switch models
- [Plan and act mode](/guides/plan-and-act/) for read-only investigation
- [Commands and shortcuts](/reference/commands/) for the complete command list
