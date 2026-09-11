## Display-only edit/write hunks. Not sent to the model.
##
## `-`/`+` prefixes, no unified-diff headers. `edit` is old then new;
## `write` is all additions from `content`. Line numbers come from the
## edit tool's `lines:` report when present; `write` numbers from 1.

import std/[json, strutils]
import nimterm/theme

type HunkSpan* = tuple[oldStart, oldEnd, newStart, newEnd: int]

proc parseHunkSpans*(output: string): seq[HunkSpan] =
  ## Reads the edit tool's `lines: 12-14 > 12-13, …` report; empty if absent.
  for line in output.splitLines:
    if not line.startsWith("lines: "): continue
    for part in line[7 .. ^1].split(", "):
      let sides = part.split(" > ")
      if sides.len != 2: continue
      let oldR = sides[0].split("-")
      let newR = sides[1].split("-")
      if oldR.len != 2 or newR.len != 2: continue
      try:
        result.add (oldR[0].parseInt, oldR[1].parseInt,
                    newR[0].parseInt, newR[1].parseInt)
      except ValueError:
        discard

type HunkEntry = tuple[minus: bool, num, text: string]  ## num "" = unnumbered

proc hunkLine(e: HunkEntry, width: int): string =
  result = if e.minus: "- " else: "+ "
  if e.num.len > 0: result.add align(e.num, width) & " | "
  result.add e.text

proc formatToolHunk*(name: string, input: JsonNode, useColor: bool,
    spans: seq[HunkSpan] = @[]): seq[string] =
  ## Empty if this is not a successful-edit/write display, or args are missing.
  if input.isNil or input.kind != JObject:
    return
  var entries: seq[HunkEntry]
  case name
  of "edit":
    let reps = input.getOrDefault("replacements")
    var pairs: seq[tuple[oldText, newText: string]]
    if not reps.isNil and reps.kind == JArray and reps.len > 0:
      for r in reps:
        pairs.add (r.getOrDefault("old_text").getStr,
                   r.getOrDefault("new_text").getStr)
    else:
      pairs.add (input.getOrDefault("old_text").getStr,
                 input.getOrDefault("new_text").getStr)
    for k, pair in pairs:
      var span: HunkSpan
      if k < spans.len: span = spans[k]
      var i = 0
      if pair.oldText.len > 0:
        for line in pair.oldText.splitLines:
          var num = ""
          if span.oldStart > 0: num = $(span.oldStart + i)
          entries.add (true, num, line)
          inc i
      i = 0
      if pair.newText.len > 0:
        for line in pair.newText.splitLines:
          var num = ""
          if span.newStart > 0: num = $(span.newStart + i)
          entries.add (false, num, line)
          inc i
  of "write":
    let content = input.getOrDefault("content").getStr
    if content.len > 0:
      var i = 0
      for line in content.splitLines:
        entries.add (false, $(i + 1), line)
        inc i
  else:
    discard
  var width = 0
  for e in entries:
    if e.num.len > 0: width = max(width, e.num.len)
  let t = currentTheme
  for e in entries:
    let body = hunkLine(e, width)
    let color = if e.minus: t.error else: t.success
    result.add (if useColor and color.len > 0: color & body else: body)
