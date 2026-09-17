---
title: Built-in tools
description: The tools nimlet always ships, their schemas, and their safety rules.
---

Nimlet gives the model a small set of tools for inspecting and changing the
workspace. The tool definitions are sent with each request, so an integration
can discover their JSON schemas from the provider request or use the behavior
below when testing a tool call.

## Tool list

| Tool | What it does | Default capability |
| --- | --- | --- |
| `read` | Read text or an image from a workspace path | Read |
| `grep` | Search file contents with a PCRE pattern | Read |
| `glob` | List workspace files matching a glob | Read |
| `git` | Inspect Git status, history, diffs, or blame | Read |
| `read_skill` | Load a discovered `SKILL.md` by name | Read |
| `edit` | Replace exact text in one file | Write |
| `write` | Create or replace a complete file | Write |
| `bash` | Run a shell command in the workspace | Shell |
| `ask_user` | Ask the user a multiple-choice question | User |

`--tools` can restrict the set, for example `--tools read,grep,glob` or
`--tools none`. The restriction applies to extension tools as well as built-ins.
The path-taking tools accept workspace-relative paths only. Symlink escapes
outside the workspace are rejected, including when an existing symlink points
elsewhere.

Independent `read`, `grep`, `glob`, and `read_skill` calls in the same model
response can run in parallel. Other tools run one at a time in the order the
model requested them.

## Read and search

### `read`

```json
{
  "path": "src/parser.py",
  "start_line": 1,
  "end_line": 80
}
```

`path` is required. Line numbers are one-based and the end is inclusive. Omit a
range to read the whole file. Text is returned with numbered lines, a
workspace-relative path, and an opaque `version` token that can be passed as
`edit.expected_version`. Text output is limited to 200,000 bytes. A truncation
message gives the next `start_line` to request.

PNG, JPEG, GIF, and WEBP files are returned as image content instead of numbered
text. Images larger than 5 MiB fail. Files that do not exist, line ranges that
start past the end, and `end_line` values before `start_line` fail.

### `grep`

```json
{
  "pattern": "TODO|FIXME",
  "glob": "**/*.py",
  "path": "src",
  "case_insensitive": true,
  "max_matches": 80
}
```

`pattern` is required and is a PCRE regular expression. Plain text works too.
Use `glob` to filter file names and `path` to limit the search to a workspace
subdirectory. The default match limit is 80 and the maximum is 200. Binary
files and files larger than 1 MiB are skipped by the built-in scanner. Output is
limited to 100,000 bytes and reports when matches were omitted. No matches
returns `No matches.`

### `glob`

```json
{"pattern":"src/**/*.py","path":"."}
```

`pattern` is required. `*` matches within one path segment, `**` matches any
depth, and `?` matches one character. The optional `path` limits the search to a
subdirectory. Results are capped at 200 paths and report when more were
omitted. Generated and dependency directories such as `.git`, `node_modules`,
`nimcache`, `dist`, `build`, `target`, `.next`, and `.turbo` are excluded.

## Changing files

### `edit`

Use `old_text` and `new_text` for one replacement, or `replacements` for several
ordered hunks:

```json
{
  "path": "src/parser.py",
  "replacements": [
    {"old_text":"let value = old", "new_text":"let value = new"},
    {"old_text":"return false", "new_text":"return true"}
  ]
}
```

Each `old_text` must be non-empty and occur exactly once at the point it is
applied. Matching is exact, with no fuzzy or partial matching. Replacements are
checked in memory and written atomically only when every hunk succeeds. Set
`expected_version` to the opaque `version` value from a previous `read` to
reject an edit when the file changed. Failures start with `EDIT_FAILED` and
include the current version when available, so the model can reread and try
again.

### `write`

```json
{"path":"src/generated.py","content":"# generated\n","overwrite":false}
```

`path` and `content` are required. The default is to create a new file and fail
if it already exists. Set `overwrite: true` to replace it. Parent directories
are created as needed, and the write is atomic.

## Running commands

### `bash`

```json
{"command":"npm test","timeout_seconds":120}
```

`command` is required. It runs in the workspace using the detected shell or the
shell selected by `NIMLET_SHELL`. The default timeout is 120 seconds; values are
clamped to at least one second. A normal result contains `exit_code`,
`duration_ms`, and any `stdout` and `stderr`. Output is capped at
`tools.bash.max_output_bytes`, which defaults to 100,000 bytes and preserves the
start and end of large output. While it runs, output can also be streamed to
the UI.

Timeouts return `TIMEOUT after ...` with captured output. Cancellation returns
`INTERRUPTED (...)` with captured output. On Linux, cancellation terminates the
shell's process group, including its descendants.

### `git`

The default operation is `status`. The supported operations are `status`,
`log`, `show`, `diff`, and `blame`. `path` is an optional workspace-relative
file or directory. `commit` selects a revision for `log` or `show`, and `limit`
controls `log` entries, defaulting to 20 and capped at 100. `blame` requires a
path. All operations are read-only, use the workspace as the Git working
directory, and fail if Git is unavailable or returns a non-zero status.

## Skills and questions

`read_skill` requires a discovered skill name and returns its full Markdown body.
The body is limited to 100,000 bytes. See [Skills](/guides/skills/) for how
skills are discovered.

`ask_user` requires a string `question` and an array of string `options`. It is
available when the interactive TUI can show the question. JSON mode, RPC mode,
and the plain console have no question UI, so the call fails with
`question_unavailable` there.

## Safety boundary

The read, search, and skill tools are designed for quiet inspection. File
changes, shell commands, Git inspection, and extension tools use the configured
permission rules in act mode. Plan mode exposes only the read-only registry,
which includes `read`, `grep`, `glob`, `git`, `read_skill`, and `ask_user`.

For tools implemented outside nimlet, see [External tools](/guides/external-tools/).
