# nimlet

A local coding agent for software projects.

## Get started

This README assumes the `nimlet` binary is installed and available on your
`PATH`. No language toolchain or source checkout is required to use it.

Set a provider credential, then run nimlet from the project you want to inspect
or change:

```sh
export OPENROUTER_API_KEY=your-key
cd /path/to/your/project
nimlet
```

If your binary is not on `PATH`, replace `nimlet` in the examples with its
path. Windows users can use the same command from PowerShell when the binary is
on `PATH`.

Store the provider credential in `~/.nimlet/auth.json`, or set its environment
variable before starting the agent:
`OPENROUTER_API_KEY` for OpenRouter, `OPENAI_API_KEY` for OpenAI,
`ANTHROPIC_API_KEY` for Anthropic, `HYPER_API_KEY` for Hyper,
`MISTRAL_API_KEY` for Mistral, `GEMINI_API_KEY` for the Gemini API (Google AI
Studio; `GOOGLE_API_KEY` works too), or `OPENCODE_API_KEY` for OpenCode Go and
OpenCode Zen.

For ChatGPT-backed Codex access, use `/login` inside nimlet. Use `/login device`
when a browser callback is not convenient; `/auth` shows the current Codex
account and `/logout` signs out. Codex App Server owns those credentials and
refreshes its tokens.
After logging in, run `/provider codex` to use the local Codex agent. Use
`/models refresh` to load the models exposed by Codex App Server, then choose
one with `/model <id>`; typing `/model ` offers the available choices.
Optional project configuration is read from `.nimlet/config.json` in the
workspace and overlays `~/.nimlet/config.json`. Global files live in
`~/.nimlet/`:

- `~/.nimlet/config.json` - default provider and model
- `~/.nimlet/auth.json` - private provider credentials
- `~/.nimlet/AGENTS.md` - personal instructions (all projects)
- `~/.nimlet/skills/` - global skills
- `~/.nimlet/prompts/` - global prompt templates
- `~/.nimlet/extensions/` - global persistent extensions
- `~/.nimlet/tools/` - global external tools
- `~/.nimlet/sessions/` - saved sessions
- `~/.nimlet/models-dev.json` - cached model metadata

To use Anthropic, run `/provider anthropic`. The first switch selects
`claude-sonnet-4-6`; subsequent switches restore your last model for that provider.
Use `/model <id>` to change it. Choices persist in `providers.<name>.last_model`.
Credentials can be stored in `~/.nimlet/auth.json`, or supplied through the
provider environment variable. The key defaults to `ANTHROPIC_API_KEY`.
Native streaming, tool calls, thinking (`/thinking high`), and hosted search
(`/web on`) are supported. Known modern Claude models use adaptive thinking
and model-supported effort levels; legacy thinking budgets are added once to
the answer token allowance. With adaptive thinking, `agent.max_tokens` caps
the combined thinking and answer. New shells must export the key before launching nimlet.

To use Mistral Vibe models, run `/provider mistral`. The first switch selects
`mistral-vibe-cli-with-tools`; subsequent switches restore your last model for
that provider. Mistral uses its OpenAI-compatible Chat Completions API, so
streaming and Nimlet's local tools work normally.

`/doctor` shows the selected provider/model, endpoint (without credentials or
query parameters), config source paths, write target, and whether each key is
set. `/doctor test` makes a small request to the selected provider (normal API
usage applies), without adding it to session history or changing configuration.

`/model`, `/thinking`, `/web`, and `/settings` write immediately: to the project file if it
exists, otherwise to the global file (created if needed). `/model` sets
`default_provider` and `default_model`; `/thinking` sets `agent.thinking`;
`/web on` sets `agent.web_search` (hosted search on OpenAI, Anthropic, and Google);
`/settings` opens a settings menu; choose `Queue` to set
`agent.steering_mode` and `agent.follow_up_mode`.

Configuration example:

```json
{
  "default_provider": "openrouter",
  "default_model": "deepseek/deepseek-v4-flash-0731",
  "agent": {
    "max_tokens": 4096,
    "request_timeout": 300,
    "web_search": false,
    "steering_mode": "one-at-a-time",
    "follow_up_mode": "one-at-a-time"
  },
  "keybindings": {
    "app.editor.external": "ctrl+g",
    "tui.editor.undo": "ctrl+z"
  }
}
```

Credentials use this separate file:

```json
{
  "openrouter": { "type": "api_key", "key": "sk-or-..." },
  "anthropic": { "type": "api_key", "key": "sk-ant-..." }
}
```

Save it as `~/.nimlet/auth.json` and keep it out of version control.

Interactive keybindings are configured as action IDs under the top-level
`keybindings` object. Values are a single key string or an array; an empty
array disables that action. For example, `tui.editor.undo` can be moved to
`ctrl+u` and `app.editor.external` to `ctrl+e`. Supported action IDs cover the
editor, queue, clear/interrupt, external editor, and mode toggle shortcuts.

Provider blocks also accept an `options` object with native API request fields:

```json
{
  "providers": {
    "openrouter": {
      "options": {
        "provider": {"sort": "latency", "allow_fallbacks": false}
      }
    },
    "openai": {
      "options": {"parallel_tool_calls": false, "store": false}
    }
  }
}
```

Only the active provider's options are added to agent turn requests. Project
configuration recursively overlays global configuration; switching providers
selects that provider's options. Missing or `null` options mean no extra settings;
other values must be JSON objects. These are provider-native fields, not fields
from nimlet's higher-level configuration.

An explicit `agent.thinking` setting (including `/thinking none`) replaces
configured `reasoning`, `reasoning_effort`, and `thinking` blocks and the
`output_config.effort` field. With no thinking setting, configured reasoning passes
through unchanged. Other settings remain intact. `/thinking` and `/model` saves
preserve provider options. Connection probes and compaction keep their existing
request settings.

Run the installed executable from the workspace you want the agent to modify:
`nimlet` on any platform where it is on `PATH`. If it is not on `PATH`, use the
full path to the binary.

While a turn is running, Enter queues a steering message for delivery after the
current assistant tool batch, before the next model call. Alt+Enter queues a
follow-up message for delivery after the agent finishes. The composer stays
editable while messages are queued, and slash commands cannot be queued.
Escape or Ctrl-C interrupts the current turn and restores queued messages to the
composer. Alt+Up restores queued messages without interrupting the turn.
Use `/settings` → `Queue` to choose `one-at-a-time` or `all` delivery
independently for steering and follow-up queues.
Pass a prompt on the command line for a one-shot turn that exits when
done: `nimlet fix the failing parser test`. Add `-i` /
`--interactive` to run that prompt and then keep the REPL open.
Use `-p` / `--print` for clean stdout containing only the final response.
Piped stdin selects print mode automatically and is placed before an optional
CLI instruction: `cat README.md | nimlet -p "Summarize this text"`.
Startup overrides are ephemeral: `--provider NAME`, `--model ID`,
`--thinking LEVEL`, `--api-key KEY`, and `--tools read,bash` (use
`--tools none` to disable tools). `--no-session` keeps the transcript in
memory and cannot be combined with `--resume` or `--session`.
Use `--mode json` instead for versioned JSONL events. Every stdout line is one
object with `"version":1`. Lifecycle types are `session_start`, `run_start`,
`step_start`, `step_end`, `run_end`, and `session_end`; message types are
`message`, `message_delta`, and `thinking_delta`; tool types are `tool_call`,
`tool_output_delta`, `tool_result`, and `approval_required`. Errors and warnings
use `error` and `diagnostic`. The reserved queue record has `type`, `action`,
`content`, and `depth`; one-shot JSON mode does not itself create a queue.
The complete version 1 contract is in [docs/json.md](docs/json.md).
Use `--mode rpc` for a long-running JSONL process that accepts correlated
`prompt`, `steer`, `follow_up`, `interrupt`, `get_state`, queue, and `shutdown`
commands on stdin. It supports separate steering and follow-up queues; see
[docs/rpc.md](docs/rpc.md).
The interactive TUI is available in the installed binary. Reads, searches, and
workspace edits run without prompts. Shell commands and extension tools ask on
first use; press
`Enter` for once, `s` to allow the normalized command for the session, `p` to
save that grant for the project, or `n` to deny. Use `/permissions` to inspect
grants and `/permissions clear` to remove project grants.
Use `/yolo` or start with `--yolo` to auto-approve all tools for the current
process; `/yolo off` disables it. YOLO mode is never persisted.
Use `/session` to print the current session ID and `/resume` to list or
resume sessions. Bare `/resume` opens the session picker; type words from a
session ID, name, or first message to filter it. `/resume` lists this workspace
(newest 20), with recency and the first user message; `/resume ID` restores that transcript and
the last provider and requested model used, without changing your saved defaults.
In the picker, `Ctrl-R` prepares a rename and `Ctrl-D` prepares a recoverable
delete; press `Enter` to run the prepared command. Rename, delete, and restore
sessions directly with `/session rename ID TITLE`, `/session delete ID`, and
`/session restore ID`. Deleted sessions are moved into Nimlet's session trash.
Use `/copy` to copy the latest assistant response to the clipboard.
Older sessions without provider metadata retain the currently selected provider.
A session from another project still loads by ID,
with a warning. Sessions without a workspace header are hidden from
workspace-filtered lists. `/model name` switches the model for later turns.
`nimlet --resume` continues the latest session for this workspace. A specific
session can be selected with `nimlet --session ID`.

Use `/plan` for an opt-in, read-only investigation checkpoint and `/act` to enable
implementation. Plan mode exposes targeted file/search tools, local Git history,
and extensions that explicitly declare read-only capabilities. Act mode reuses the
latest plan and tool results instead of restarting broad exploration. Shift+Tab toggles
the same modes without changing your draft;
during a running turn it queues the switch for the next turn (press again to
cancel the queued switch). The footer shows `[plan]` or `[act]`.

Plan mode exposes read-only file/search/history tools plus extensions explicitly
marked with `read` or `user` capabilities. Edits, shell execution, hosted
search, non-read-only extensions, and hooks are disabled, and unadvertised tool
calls are rejected at execution time. Session history still saves, and explicit
configuration commands still work. Modes apply to the current process, including
`/new` and `/resume`; restarting starts in act mode. Planning is optional and
does not require a separate plan file.

On resume, missing local tool results are recorded as interrupted with an unknown
execution outcome; completed results are preserved and tools are not automatically
rerun. A damaged JSONL tail is repaired on the next append, with the original file
preserved beside the session as `<session>.jsonl.recovery-<timestamp>`.

### Keyboard shortcuts

`/help` prints both the commands and this list in the TUI.

- `Enter` - submit; while a turn is running, queue a steering message
- `Alt+Enter` - queue a follow-up message while a turn runs
- `Shift+Enter` / `Alt+J` - newline in the composer
- `Shift+Tab` - toggle plan / act mode
- `Esc` / `Ctrl-C` - interrupt a running turn and restore queued messages
- `Alt+Up` - restore queued messages to the composer
- `Ctrl-V` - paste text or a clipboard image
- `Tab` / `Up` / `Down` - accept / move through suggestions
- `Left`/`Right`, `Ctrl-B` - move the cursor by character
- `Ctrl-F` - search the transcript
- `Alt-B` / `Alt-F` - move the cursor by word
- `Home`/`End`, `Ctrl-A`/`Ctrl-E` - jump to start / end of the line
- `Up`/`Down`, `Ctrl-P`/`Ctrl-N` - history (and composer line up/down)
- `Ctrl-G` - open the composer in `$VISUAL`, `$EDITOR`, or `nano`
- `Ctrl-Z` - undo the last composer edit
- `Ctrl-W` / `Alt-D` - delete the previous / next word; `Ctrl-Y` yanks it back
- `!command` - run a shell command and send its output to the model
- `!!command` - run a shell command without sending its output to the model
- `Ctrl-O` - show or hide tool output and thinking details
- `PgUp` / `PgDn` / mouse wheel - scroll the transcript

Type `/help` at any prompt to see these in the running app.

Project instructions are loaded from `~/.nimlet/AGENTS.md`, then from
`AGENTS.md` files between the repository root and the workspace. Passive
skills can be placed in `.nimlet/skills/<name>/SKILL.md`,
`.agents/skills/<name>/SKILL.md`, `~/.nimlet/skills/<name>/SKILL.md`, or
the portable `~/.agents/skills/<name>/SKILL.md` location;
their metadata is advertised to the model and full bodies are loaded
only through the `read_skill` tool. Type `/skill:<name>` (optionally followed by
a request) to load a skill into the next turn. Built-in commands win when
names collide.

Prompt templates are non-recursive Markdown files in `prompts/` under the same
Nimlet and portable `.agents` roots. The filename becomes a bare slash command: `prompts/review.md`
registers `/review`. Optional frontmatter may set `description`; `$ARGUMENTS`
and `$@` in the body expand to the text following the command. Built-in commands
win when names collide. Use prompt templates for short reusable requests and
skills for model-visible procedures that may include supporting files.

Legacy external tools are discovered the same way under `tools/` instead of
`skills/`: `~/.nimlet/tools/`, `<workspace>/.agent/tools/`, then
`<workspace>/.nimlet/tools/` (later roots override the same name). Each
child directory needs a `tool.json` and an executable; the agent reads
manifests at startup and only spawns the process when the model calls the
tool. Built-in tool names always win over extensions. Tools and extensions are
rescanned on `/reload`, `/new`, and `/resume` (as well as process start).
`/reload` keeps the current session; skills and `AGENTS.md` are already
read from disk on every turn.

External tools are act-only by default. Add `"capabilities":["read"]` (or
`"user"`) to a manifest when the tool is safe to expose in plan mode; write,
shell, and network capabilities keep it out of plan mode.

Persistent extensions subscribe with an `events` array in their `register`
response. Supported events are `tool_call`, `tool_result`, `session_start`,
`session_end`, `session_before_compact`, `session_compact`, `turn_start`, and
`turn_end`. Event responses may deny an action, rewrite tool arguments/results,
append compaction instructions, or provide a complete custom compaction.
Failures are fail-open and reported as warnings. The old `hook.json` process
model is not loaded.

Compiled-in extensions may persist namespaced JSON state with
`Session.addExtensionEntry(name, data)` and recover it with
`Session.extensionEntries(name)`. These entries stay in the append-only session
log but are not sent to the model or counted as conversation context.

Persistent extensions are language-neutral executables discovered from
`extensions/<name>/extension.json` under global or project `.agents` and
`.nimlet` roots. Nimlet sends one `initialize` JSON line and expects a
`register` response:

```json
{"name":"hello","command":["./extension.py"],"response_timeout_seconds":120}
```

```json
{"type":"register","commands":[{"name":"hello","description":"Say hello"}],"events":["turn_start"],"tools":[{"name":"inspect","description":"Inspect project state","input_schema":{"type":"object"},"capabilities":["read"]}]}
```

Invoking `/hello world` sends a `command` request with `name`, `arguments`, and
a correlation `id`. A matching `response` may contain `message` for immediate
display or `prompt` to start a model turn. Extensions block on stdin between
events, so they require no polling or idle CPU. `/reload` stops and restarts
them; clean Nimlet exit sends `shutdown`.

`response_timeout_seconds` defaults to 30, accepts a positive integer, and may
be `null` for no timeout. The same asynchronous request path is used for
commands and tools, so long-running extensions keep the UI responsive.
Responses are routed by ID, allowing concurrent requests.

Persistent extension tools are act-only unless their registration includes
capabilities containing only read and/or user.

Any response may also carry host actions:

```json
{
  "type": "response",
  "id": "7",
  "status": {"key": "state", "text": "3 subagents running"},
  "widget": {"key": "agents", "lines": ["✓ research", "… tests"]},
  "notification": {"level": "info", "message": "Research complete"},
  "entry": {"completed": ["research"]}
}
```

Status and widget keys are automatically namespaced to the extension. Returning
an empty status `text` or empty widget `lines` clears that item. `entry` is
appended to the session under the extension's name and never enters model
context.

Extensions may publish the same actions at any time without a request:

```json
{"type":"update","status":{"key":"agent","text":"researching"}}
```

One blocking reader per extension wakes the UI immediately without polling the
child process or consuming idle CPU.

While handling a request, an extension may ask the user and then continue:

```json
{"type":"ui_request","id":"q1","method":"question","prompt":"Environment?","options":["staging","production"]}
```

Nimlet replies with `{"type":"ui_response","id":"q1","answer":"staging","cancelled":false}`.
Time spent waiting for the user does not count against the response timeout.

## License

MIT. See [LICENSE](LICENSE).
