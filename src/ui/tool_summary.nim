## Compact display-only summaries for verbose read-only tool results.

import std/[json, sequtils, strutils]

proc inputText(input: JsonNode, key: string): string =
  let value = input.getOrDefault(key)
  if not value.isNil and value.kind == JString: result = value.getStr

proc displayValue(value: string, limit = 240): string =
  result = value.replace("\r", "\\r").replace("\n", "\\n")
  if result.len > limit:
    result = result[0 ..< limit] & "…"

proc addInputField(result: var string, input: JsonNode, key, label: string) =
  let value = inputText(input, key)
  if value.len > 0:
    result.add label & ": " & displayValue(value) & "\n"

proc transcriptToolOutput*(name: string, input: JsonNode,
                           output: string, isError = false): string =
  if isError or name notin ["read", "grep", "glob", "git"]:
    return output
  let args = if input.isNil: newJObject() else: input
  let lines = output.splitLines
  case name
  of "read":
    for line in lines:
      if line.startsWith("path: ") or line.startsWith("version: ") or
          line.startsWith("lines: "):
        result.add line & "\n"
    var sourceLines = 0
    for line in lines:
      let separator = line.find(" | ")
      if separator > 0 and line[0 ..< separator].allCharsInSet({'0' .. '9'}):
        inc sourceLines
    if sourceLines > 0:
      result.add "[" & $sourceLines & " source lines hidden from transcript]\n"
  of "grep":
    addInputField(result, args, "pattern", "pattern")
    addInputField(result, args, "glob", "glob")
    addInputField(result, args, "path", "path")
    let matches = lines.filterIt(it.len > 0)
    result.add "matches: " & $matches.len & "\n"
    for i in 0 ..< min(3, matches.len):
      result.add matches[i] & "\n"
    if matches.len > 3:
      result.add "[" & $(matches.len - 3) & " more matches hidden]\n"
  of "glob":
    addInputField(result, args, "pattern", "pattern")
    addInputField(result, args, "path", "path")
    let matches = lines.filterIt(it.len > 0)
    result.add "matches: " & $matches.len & "\n"
    for i in 0 ..< min(10, matches.len):
      result.add matches[i] & "\n"
    if matches.len > 10:
      result.add "[" & $(matches.len - 10) & " more paths hidden]\n"
  of "git":
    addInputField(result, args, "operation", "operation")
    addInputField(result, args, "path", "path")
    addInputField(result, args, "commit", "commit")
    result.add "output: " & $lines.filterIt(it.len > 0).len & " lines\n"
    for i in 0 ..< min(5, lines.len):
      if lines[i].len > 0: result.add lines[i] & "\n"
    if lines.filterIt(it.len > 0).len > 5:
      result.add "[more Git output hidden]\n"
  else: discard
