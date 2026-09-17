# nimlet

A local coding agent for software projects. Nimlet runs in your terminal, works
directly in your repository, and takes a request from description to inspected,
edited, and tested change.

It is a single native binary, built in Nim with [nimgent](https://nimgent.niminal.dev)
for models and tools and [nimterm](https://nimterm.niminal.dev) for the terminal
UI. There is no language runtime to install and no hosted service in the path.

## Why nimlet

- **Light enough to run anywhere.** Nimlet is a compiled binary with fast startup
  and low memory use, so you can run one per branch, workspace, or CI job without
  a heavy runtime behind each one.
- **Idle when nothing is happening.** It waits on you, the provider, or a
  subprocess. No polling, no timers, no idle CPU.
- **Requests go straight to your provider.** Credentials stay in your environment
  or in `~/.nimlet/auth.json`, and Nimlet talks to the API you picked.
- **You decide what runs.** Reads, searches, and workspace edits run without
  prompting. Shell commands and extension tools ask the first time, and you can
  grant them for the session or the project.
- **Fits the terminal and your scripts.** The same agent is an interactive TUI, a
  one-shot command, a JSON event stream, or a long-running RPC process.

## Quickstart

Put the `nimlet` binary on your `PATH`, set a provider key, and run it from the
workspace you want to work on:

```sh
export OPENROUTER_API_KEY=your-key
cd /path/to/your/project
nimlet
```

Then describe the outcome you want:

```text
Fix the failing parser test and run the focused test.
```

Nimlet reads and searches files, checks Git history, makes the smallest edit that
fits, and runs the commands you approve. The footer shows the active provider,
model, thinking level, context usage, tokens, and cost when pricing is known.

To build the binary from source, install Nim 2.0 or later and run
`nimble release`, which writes `build/nimlet`.

### Providers

| Provider | Credential |
| --- | --- |
| OpenRouter (default) | `OPENROUTER_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Anthropic | `ANTHROPIC_API_KEY` |
| Google Gemini API | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Mistral | `MISTRAL_API_KEY` |
| Hyper | `HYPER_API_KEY` |
| OpenCode Go or Zen | `OPENCODE_API_KEY` |
| Codex (ChatGPT) | Sign in with `/login` inside nimlet |

Switch providers with `/provider <name>` or `--provider <name>`, and pick a model
with `/model <id>`. For ChatGPT-backed Codex access, run `/login` inside nimlet,
then switch with `/provider codex`.

## What you can do with it

### Work across the project

Nimlet ships with tools for reading text and images, searching file contents,
listing files, inspecting Git, editing files in place, writing new ones, and
running shell commands. Point it at a task and it gathers the context it needs
instead of waiting for you to paste files in.

### Plan before you act

Press `Shift+Tab` to toggle read-only plan mode. Plan mode exposes file, search,
and Git tools plus extensions marked read-only, and leaves your code untouched.
Switch back to act mode and Nimlet reuses the plan and tool results instead of
starting its investigation again.

### Keep your next thought moving

While a turn is running, `Enter` queues a steering message and `Alt+Enter` queues
a follow-up. The composer stays editable, and `Escape` interrupts and restores
anything still queued.

### Come back to the work later

Sessions are saved per workspace. Resume the latest one with `nimlet --resume` or
`/resume`, load a specific session with `--session ID`, rename or delete sessions
from the picker, and copy the last response with `/copy`. Long tasks compact
their context so the conversation can keep going.

### Make it yours

- **Instructions** in `AGENTS.md` files and `~/.nimlet/AGENTS.md` reach every request.
- **Skills** in `.nimlet/skills/<name>/SKILL.md` load detailed procedures only when a task needs them.
- **Prompt templates** in `prompts/` turn recurring requests into slash commands such as `/review`.
- **External tools** expose your own executables to the model with a `tool.json` manifest.
- **Persistent extensions** add tools, commands, hooks, and live status updates in any language.
- **Themes** are configurable with `/theme`, including custom themes in `themes/`.

### Use it from scripts and CI

- `nimlet "prompt"` runs one turn and exits, and `-p` / `--print` keeps stdout to the final answer.
- Piped input selects print mode automatically: `cat README.md | nimlet -p "Summarize this"`.
- `--mode json` emits versioned JSONL events for one run.
- `--mode rpc` drives a long-running process with prompts, steering, follow-ups, and interrupts.

## Documentation

Full documentation lives at **[nimlet.niminal.dev](https://nimlet.niminal.dev)**.

- [Quickstart](https://nimlet.niminal.dev/guides/quickstart/)
- [Configuration](https://nimlet.niminal.dev/guides/configuration/)
- [Interactive TUI](https://nimlet.niminal.dev/guides/interactive-tui/)
- [Plan and act mode](https://nimlet.niminal.dev/guides/plan-and-act/)
- [Permissions](https://nimlet.niminal.dev/guides/permissions/)
- [Sessions](https://nimlet.niminal.dev/guides/sessions/)
- [Models and providers](https://nimlet.niminal.dev/guides/models-and-providers/)
- [Skills](https://nimlet.niminal.dev/guides/skills/), [prompt templates](https://nimlet.niminal.dev/guides/prompt-templates/), [external tools](https://nimlet.niminal.dev/guides/external-tools/), [extensions](https://nimlet.niminal.dev/guides/extensions-and-hooks/)
- [JSON mode](https://nimlet.niminal.dev/reference/json-mode/), [RPC mode](https://nimlet.niminal.dev/reference/rpc-mode/)
- [Commands and shortcuts](https://nimlet.niminal.dev/reference/commands/)

## License

MIT. See [LICENSE](LICENSE).
