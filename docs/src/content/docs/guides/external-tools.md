---
title: External tools
description: Register ephemeral executables as model tools with tool.json.
---

External tools let you expose an executable as a model tool without keeping a
process running between calls. Nimlet starts the executable only when the model
uses the tool, sends one JSON object on stdin, and expects one JSON object back
on stdout.

## Add a tool

Create a directory with a `tool.json` manifest and an executable:

```text
.nimlet/tools/word-count/
├── tool.json
└── word-count
```

```json title=".nimlet/tools/word-count/tool.json"
{
  "name": "word_count",
  "description": "Count the words in a text string.",
  "command": ["word-count"],
  "input_schema": {
    "type": "object",
    "properties": { "text": { "type": "string" } },
    "required": ["text"]
  },
  "timeout_seconds": 10,
  "capabilities": ["read"]
}
```

`name`, `description`, `command`, and `input_schema` are required. `command`
must be a non-empty string array. The first command item is resolved relative
to the directory containing `tool.json`; later items are fixed arguments. An
absolute executable path is used as written. The process working directory is
the workspace where nimlet is running.

The optional timeout defaults to 30 seconds. `capabilities` can contain
`read`, `write`, `shell`, `network`, or `user`. Omitting the field treats the
tool as unsafe, with `write`, `shell`, and `network` capabilities. A tool is
available in plan mode only when every declared capability is `read` or `user`.

## Discovery and reload

Nimlet searches these roots in order:

| Root | Scope |
| --- | --- |
| `~/.nimlet/tools` | Your global tools |
| `<workspace>/.agent/tools` | Trusted project tools |
| `<workspace>/.nimlet/tools` | Trusted project tools |

Directories are sorted within each root. A later root replaces a tool with the
same name, case-insensitively. Project roots are skipped until the project is
trusted. Invalid manifests produce a startup warning and are skipped. A name
that collides with a built-in tool is skipped too. Built-in names are
`ask_user`, `bash`, `edit`, `git`, `glob`, `grep`, `read`, `read_skill`, and
`write`.

Use `/reload` after adding or editing a manifest. Nimlet does not start an
external tool while it is scanning the directories.

## Process protocol

For a call with arguments such as:

```json
{"text":"hello from nimlet"}
```

the executable receives that object on stdin. `{}` is sent when the call has no
arguments. It must write exactly one JSON value to stdout. Stderr is captured
separately and is not parsed as the result. A non-zero exit, empty or invalid
JSON stdout, timeout, or cancellation makes the tool call fail. Output is
capped by `tools.bash.max_output_bytes`, which defaults to `100000` bytes.

The first command item is resolved relative to the manifest directory and is run
with the selected shell so stdout and stderr can be captured. On Windows,
common script files are launched through the appropriate shell, and native
executables can be used directly. Give the command an executable bit on POSIX:

```sh
chmod +x .nimlet/tools/word-count/word-count
```

## Permissions and plan mode

Act-mode calls to external tools use the normal permission prompt. Plan mode
offers only tools whose capabilities are limited to `read` and `user`. A
headless JSON or RPC run has no approval UI, so do not expose untrusted tools to
those modes.

For persistent extensions that stay alive and receive lifecycle events, see
[Extensions and hooks](/guides/extensions-and-hooks/). For the exact built-in
path and output rules, see [Built-in tools](/reference/tools/).
