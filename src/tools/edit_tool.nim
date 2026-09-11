## edit tool — exact search-and-replace on a single file.

import std/[asyncdispatch, json, strutils, strformat, os]
import tool, ../workspace, nimgent

proc nearbyLines(content, oldText: string): string =
  let lines = content.splitLines
  let needle = oldText.splitLines[0]
  if needle.len <= 8: return
  for i, line in lines:
    if needle[0 .. min(7, needle.high)] in line:
      result.add fmt"  {i+1} | {line}" & "\n"
      if result.len > 500: return

proc replacementsFrom*(input: JsonNode): seq[tuple[oldText, newText: string]] =
  if input.isNil or input.kind != JObject: return
  let arr = input.getOrDefault("replacements")
  if not arr.isNil and arr.kind == JArray and arr.len > 0:
    for r in arr:
      if r.kind != JObject: continue
      result.add (r.getOrDefault("old_text").getStr, r.getOrDefault("new_text").getStr)
  elif "old_text" in input:
    result.add (input["old_text"].getStr, input["new_text"].getStr)

type EditSpan* = tuple[oldStart, oldEnd, newStart, newEnd: int]

proc applyReplacements*(content: string,
    replacements: openArray[tuple[oldText, newText: string]]):
    tuple[ok: bool, text, err: string, spans: seq[EditSpan]] =
  if replacements.len == 0:
    return (false, content, "EDIT_FAILED\n\nNo replacements given.", @[])
  var text = content
  for i, r in replacements:
    if r.oldText.len == 0:
      return (false, content, "EDIT_FAILED\n\nReplacement " & $(i + 1) &
        " has empty old_text.", @[])
    let count = text.count(r.oldText)
    if count == 0:
      var msg = "EDIT_FAILED\n\nReplacement " & $(i + 1) &
        ": old_text was not found exactly.\n"
      let nearby = nearbyLines(text, r.oldText)
      if nearby.len > 0:
        msg.add "\nPossibly similar lines:\n" & nearby
      return (false, content, msg, @[])
    if count > 1:
      return (false, content, "EDIT_FAILED\n\nReplacement " & $(i + 1) &
        " matches " & $count & " locations. It must be unique.\n" &
        "Add surrounding context to disambiguate.", @[])
    let pos = text.find(r.oldText)
    let start = text[0 ..< pos].count('\n') + 1
    result.spans.add (start, start + r.oldText.splitLines.len - 1,
                      start, start + r.newText.splitLines.len - 1)
    text = text.replace(r.oldText, r.newText)
  result.text = text
  result.ok = true

proc reportSpans*(spans: openArray[EditSpan]): string =
  ## `lines: 12-14 > 12-13, …` — display-only report of the touched lines.
  if spans.len == 0: return
  for i, s in spans:
    if i > 0: result.add ", "
    result.add "$1-$2 > $3-$4" % [$s.oldStart, $s.oldEnd,
                                  $s.newStart, $s.newEnd]

proc makeEditTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "edit",
    description: "Replace unique old_text → new_text in a file. Pass replacements=[{old_text,new_text},…] for several hunks in one call (applied in order, all-or-nothing). Supply expected_version from read.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "File path relative to workspace root."},
        "old_text": {"type": "string", "description": "Exact text to find. Must occur exactly once."},
        "new_text": {"type": "string", "description": "Replacement text."},
        "replacements": {
          "type": "array",
          "description": "Multiple unique replacements, applied in order.",
          "items": {
            "type": "object",
            "properties": {
              "old_text": {"type": "string"},
              "new_text": {"type": "string"}
            },
            "required": ["old_text", "new_text"]
          }
        },
        "expected_version": {"type": "string", "description": "Version hash from a previous read. Edit is rejected if the file has changed since."}
      },
      "required": ["path"]
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let path = input["path"].getStr
    var resolved: string
    try:
      resolved = ws.resolve(path)
    except WorkspaceError as e:
      return ToolResult(output: e.msg, isError: true)

    if not fileExists(resolved):
      return ToolResult(output: "File not found: " & path, isError: true)

    let content = readFile(resolved)
    let currentVersion = hashContent(content)

    if "expected_version" in input:
      let expected = input["expected_version"].getStr
      if expected.len > 0 and expected != currentVersion:
        return ToolResult(
          output: "EDIT_FAILED\n\nFile version changed since previous read.\n" &
                  "expected: " & expected & "\n" &
                  "current:  " & currentVersion & "\n\n" &
                  "Please reread the file before editing.",
          isError: true)

    let reps = replacementsFrom(input)
    let applied = applyReplacements(content, reps)
    if not applied.ok:
      var msg = applied.err
      msg.add "current version: " & currentVersion & "\n"
      return ToolResult(output: msg, isError: true)

    writeFileAtomic(resolved, applied.text)
    clearMentionFileCache(ws.root)
    let newVersion = hashContent(applied.text)
    var outp = fmt"OK — {ws.relative(resolved)}" & "\n" &
               fmt"version: {newVersion}"
    if reps.len > 1:
      outp.add "\n" & fmt"replacements: {reps.len}"
    if applied.spans.len > 0:
      outp.add "\nlines: " & reportSpans(applied.spans)
    return ToolResult(output: outp, isError: false)

  (def, run)
