## Standalone HTML export for saved sessions.

import std/[json, os, strutils]
import nimgent
import session

proc htmlEscape*(value: string): string =
  for ch in value:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add ch

proc safeHref(value: string): string =
  let url = value.strip
  if url.startsWith("https://") or url.startsWith("http://"):
    url
  else:
    ""

proc jsonPretty(node: JsonNode): string =
  if not node.isNil: result = node.pretty

proc blockHtml(part: ContentBlock): string =
  case part.kind
  of ckText:
    result = "<pre class=\"content\">" & part.text.htmlEscape & "</pre>"
  of ckThinking:
    result = "<details class=\"thinking\"><summary>Thinking</summary><pre>" &
      part.thinking.htmlEscape & "</pre></details>"
  of ckToolUse:
    result = "<details class=\"tool\"><summary>Tool: " &
      part.name.htmlEscape & "</summary><pre>" & jsonPretty(part.input).htmlEscape &
      "</pre></details>"
  of ckToolResult:
    let className = if part.isError: "tool-result error" else: "tool-result"
    result = "<details class=\"" & className & "\"><summary>Tool result" &
      (if part.isError: " (error)" else: "") & "</summary><pre>" &
      part.output.htmlEscape & "</pre></details>"
  of ckImage:
    if part.toImage.path.len > 0:
      result = "<p class=\"attachment\">[image: " &
        part.toImage.path.htmlEscape & "]</p>"
    elif part.toImage.data.len > 0:
      result = "<img class=\"attachment-image\" src=\"data:" &
        part.toImage.mimeType.htmlEscape & ";base64," &
        part.toImage.data.htmlEscape & "\" alt=\"attached image\">"
    else:
      result = "<p class=\"attachment\">[image]</p>"
  of ckFile:
    result = "<p class=\"attachment\">[file" &
      (if part.file.filename.len > 0: ": " & part.file.filename.htmlEscape else: "") &
      "]</p>"
  of ckSource:
    let href = safeHref(part.source.url)
    let label = if part.source.title.len > 0: part.source.title else: part.source.url
    if href.len > 0:
      result = "<p class=\"source\"><a href=\"" & href.htmlEscape & "\">" &
        label.htmlEscape & "</a></p>"
    else:
      result = "<p class=\"source\">" & label.htmlEscape & "</p>"

proc messageHtml(event: SessionEvent): string =
  let role = if event.message.role == roleUser: "user" else: "assistant"
  result = "<article class=\"message " & role & "\"><header>" &
    role.capitalizeAscii &
    (if event.model.len > 0: " <small>" & event.model.htmlEscape & "</small>" else: "") &
    "</header>"
  for part in event.message.content:
    result.add blockHtml(part)
  result.add "</article>"

proc sessionHtml*(session: Session): string =
  let title = if session.name.len > 0: session.name else: "Nimlet session " & session.id
  result = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>""" & title.htmlEscape & """</title>
<style>
:root { color-scheme: light dark; font: 16px/1.5 system-ui, sans-serif; }
body { max-width: 960px; margin: 0 auto; padding: 2rem 1rem; background: #f7f7f8; color: #202124; }
h1 { margin-bottom: .25rem; }
.meta { color: #666; margin-bottom: 2rem; }
.message { margin: 1rem 0; padding: 1rem; border-radius: .75rem; background: white; box-shadow: 0 1px 3px #0002; }
.message.user { border-left: .25rem solid #6b7280; }
.message.assistant { border-left: .25rem solid #2563eb; }
header { font-weight: 700; margin-bottom: .75rem; text-transform: capitalize; }
header small { color: #666; font-weight: 400; text-transform: none; }
.content, details pre { white-space: pre-wrap; overflow-x: auto; margin: .5rem 0 0; font: inherit; }
details { margin: .75rem 0; padding: .5rem .75rem; background: #f1f3f4; border-radius: .5rem; }
summary { cursor: pointer; font-weight: 600; }
.thinking { opacity: .75; }
.tool-result.error { border: 1px solid #dc2626; }
.attachment-image { display: block; max-width: 100%; max-height: 32rem; }
.attachment, .source { color: #666; }
a { color: #2563eb; }
@media (prefers-color-scheme: dark) {
  body { background: #16181d; color: #e5e7eb; }
  .message { background: #22252b; }
  .meta, header small, .attachment, .source { color: #a1a1aa; }
  details { background: #30343b; }
  a { color: #93c5fd; }
}
</style>
</head>
<body>
<h1>""" & title.htmlEscape & """</h1>
<p class="meta">nimlet session <code>""" & session.id.htmlEscape & """</code>"""
  if session.workspace.len > 0:
    result.add " in <code>" & session.workspace.htmlEscape & "</code>"
  result.add "</p><main>"
  for event in session.events:
    case event.kind
    of sekUser, sekAssistant:
      result.add event.messageHtml
    of sekToolResult:
      let className = if event.toolError: "tool-result error" else: "tool-result"
      result.add "<details class=\"" & className & "\"><summary>Tool result" &
        (if event.toolError: " (error)" else: "") & "</summary><pre>" &
        event.toolOutput.htmlEscape & "</pre></details>"
    of sekCompaction:
      result.add "<details class=\"compaction\"><summary>Context compacted</summary><pre>" &
        event.summary.htmlEscape & "</pre></details>"
    of sekExtension:
      result.add "<details class=\"extension\"><summary>Extension: " &
        event.extension.htmlEscape & "</summary><pre>" &
        jsonPretty(event.extensionData).htmlEscape & "</pre></details>"
    of sekName, sekSelection:
      discard
  result.add "</main></body></html>"

proc exportSessionHtml*(session: Session, path: string) =
  let parent = path.parentDir
  if parent.len > 0: createDir(parent)
  writeFile(path, session.sessionHtml)
