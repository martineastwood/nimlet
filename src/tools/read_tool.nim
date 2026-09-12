## read tool — read all or part of a file.

import std/[asyncdispatch, json, strutils, os, strformat]
import tool, ../workspace, ../images, nimgent

const
  MaxReadBytes = 200_000

proc imageMimeAt(path: string): string =
  try:
    let size = min(int(getFileSize(path)), 32_768)
    if size <= 0: return
    var head = newString(size)
    let f = open(path)
    let n = f.readBuffer(addr head[0], size)
    f.close()
    head.setLen(n)
    sniffImageMime(head)
  except CatchableError:
    ""

proc makeReadTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "read",
    description: "Read all or part of a file. Returns numbered lines and a version token. png/jpeg/gif/webp files are returned as image content.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "File path relative to workspace root."},
        "start_line": {"type": "integer", "description": "First line to read (1-based). Omit to read from the start."},
        "end_line": {"type": "integer", "description": "Last line to read (1-based, inclusive). Omit to read to the end."}
      },
      "required": ["path"]
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    await sleepAsync(0)
    let path = input["path"].getStr
    var resolved: string
    try:
      resolved = ws.resolve(path)
    except WorkspaceError as e:
      return ToolResult(output: e.msg, isError: true)

    if not fileExists(resolved):
      return ToolResult(output: "File not found: " & path, isError: true)

    let mime = imageMimeAt(resolved)
    if mime.len > 0:
      if getFileSize(resolved) > MaxImageBytes.int64:
        return ToolResult(output: "image too large (" & $getFileSize(resolved) &
          " bytes; max " & $MaxImageBytes & ")", isError: true)
      var buf = fmt"path: {ws.relative(resolved)}" & "\n"
      buf.add fmt"version: {fileVersion(resolved)}" & "\n"
      buf.add mime & " " & $getFileSize(resolved) & " bytes\n"
      return ToolResult(output: buf, images: @[
        ImageContent(mimeType: mime,
          path: ws.relative(resolved).replace('\\', '/'))])

    var startLine = 1
    var endLine = int.high
    if "start_line" in input:
      startLine = max(1, input["start_line"].getInt)
    if "end_line" in input:
      endLine = input["end_line"].getInt
    if endLine < startLine:
      return ToolResult(output: "end_line must be at least start_line.",
        isError: true)

    let version = fileVersion(resolved)
    var f: File
    try:
      f = open(resolved, fmRead)
    except CatchableError as e:
      return ToolResult(output: e.msg, isError: true)
    defer: f.close()

    var line: string
    var lineNo = 0
    var outputBytes = 0
    var selected: seq[tuple[number: int, text: string]]
    var truncated = false
    var reachedEnd = false
    while f.readLine(line):
      inc lineNo
      if lineNo < startLine: continue
      let renderedBytes = len($lineNo) + 3 + line.len
      if outputBytes + renderedBytes > MaxReadBytes:
        truncated = true
        break
      selected.add (lineNo, line)
      outputBytes += renderedBytes
      if lineNo >= endLine:
        reachedEnd = true
        break

    if selected.len == 0 and lineNo < startLine:
      return ToolResult(output: fmt"start_line {startLine} exceeds file length ({lineNo} lines).",
        isError: true)

    let complete = not truncated and not reachedEnd
    var buf = fmt"path: {ws.relative(resolved)}" & "\n"
    buf.add fmt"version: {version}" & "\n"
    if complete:
      buf.add fmt"lines: {startLine}-{lineNo} of {lineNo}" & "\n\n"
    else:
      let last = if selected.len > 0: selected[^1].number else: startLine
      buf.add fmt"lines: {startLine}-{last}" & "\n\n"
    let width = len($(if selected.len > 0: selected[^1].number else: startLine))
    for item in selected:
      buf.add align($item.number, width) & " | " & item.text & "\n"
    if truncated:
      let next = if selected.len > 0: selected[^1].number + 1 else: startLine
      buf.add fmt"[output truncated; use start_line={next} to continue]\n"
    elif reachedEnd and endLine < int.high:
      buf.add fmt"[read through line {endLine}; use start_line={endLine + 1} to continue]\n"

    return ToolResult(output: buf, isError: false)

  (def, run)
