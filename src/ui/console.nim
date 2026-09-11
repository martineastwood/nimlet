## Plain terminal UI. It deliberately performs no redraws, timers or polling.
##
## Colors come from `currentTheme` and are empty when depth is none (NO_COLOR /
## non-TTY), matching https://no-color.org/.

import std/[json, strutils]
import nimgent
import ../commands
import nimterm/markdown
import diff
import nimterm/theme

proc printPrompt*() =
  let t = currentTheme
  stdout.write t.paint(t.accent, "> ")
  stdout.flushFile()

proc printToolStart*(call: ContentBlock) =
  let t = currentTheme
  let summary =
    if call.input.isNil: "{}"
    elif call.name == "edit" or call.name == "write":
      call.input.getOrDefault("path").getStr
    else:
      call.input.pretty(0)
  stdout.write t.paint(t.accent, "● " & call.name) & " " &
    t.paint(t.dim, summary) & "\n"
  stdout.flushFile()

proc printToolResult*(output: string, isError: bool,
                      call: ContentBlock = ContentBlock()) =
  let t = currentTheme
  if not isError and call.kind == ckToolUse:
    let hunk = formatToolHunk(call.name, call.input, t.colorsOn,
      parseHunkSpans(output))
    if hunk.len > 0:
      stdout.write hunk.join("\n")
      if t.colorsOn: stdout.write t.reset
      stdout.write "\n\n"
      stdout.flushFile()
      return
  if isError:
    stdout.write t.paint(t.error, "  ERROR: " & output) & "\n\n"
  else:
    stdout.write t.paint(t.dim, output) & (if output.endsWith("\n"): "\n" else: "\n\n")
  stdout.flushFile()

proc printResponse*(response: ProviderResponse) =
  let t = currentTheme
  let content = response.text
  if content.len > 0:
    let rendered = renderMarkdown(content, t.colorsOn)
    stdout.write rendered & (if rendered.endsWith("\n"): "" else: "\n")
  var stats: seq[string] = @[]
  if response.model.len > 0:
    stats.add t.paint(t.model, response.model)
  for label in formatUsageLabels(response.usage):
    stats.add t.paint(t.dim, label)
  if stats.len > 0:
    stdout.write t.paint(t.dim, stats.join(" · ")) & "\n"
  stdout.flushFile()

proc printHelp*() =
  stdout.write renderMarkdown(helpText(), currentTheme.colorsOn) & "\n"
