## read tool — read all or part of a file.

import std/[asyncdispatch, json, strutils, os, strformat]
import tool, ../workspace, ../images, nimgent

const
  MaxReadBytes = 200_000

proc makeReadTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "read",
    description: "Read all or part of a file. Returns numbered lines and a version hash. png/jpeg/gif/webp files are returned as image content.",
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
    let path = input["path"].getStr
    var resolved: string
    try:
      resolved = ws.resolve(path)
    except WorkspaceError as e:
      return ToolResult(output: e.msg, isError: true)

    if not fileExists(resolved):
      return ToolResult(output: "File not found: " & path, isError: true)

    let rawContent = readFile(resolved)
    let classified = classifyImage(rawContent)
    if classified.mime.len > 0:
      if not classified.ok:
        return ToolResult(output: classified.err, isError: true)
      let version = hashContent(rawContent)
      var buf = fmt"path: {ws.relative(resolved)}" & "\n"
      buf.add fmt"version: {version}" & "\n"
      buf.add classified.mime & " " & $rawContent.len & " bytes\n"
      return ToolResult(output: buf, images: @[
        ImageContent(mimeType: classified.mime,
          path: ws.relative(resolved).replace('\\', '/'))])
    if rawContent.len > MaxReadBytes and
       "start_line" notin input and "end_line" notin input:
      return ToolResult(
        output: fmt"File too large ({rawContent.len} bytes). Supply start_line/end_line to read a portion.",
        isError: true)

    let version = hashContent(rawContent)
    let allLines = rawContent.splitLines
    let totalLines = allLines.len

    var startLine = 1
    var endLine = totalLines
    if "start_line" in input:
      startLine = max(1, input["start_line"].getInt)
    if "end_line" in input:
      endLine = min(totalLines, input["end_line"].getInt)
    if startLine > totalLines:
      return ToolResult(output: fmt"start_line {startLine} exceeds file length ({totalLines} lines).", isError: true)

    var buf = fmt"path: {ws.relative(resolved)}" & "\n"
    buf.add fmt"version: {version}" & "\n"
    buf.add fmt"lines: {startLine}-{endLine} of {totalLines}" & "\n\n"

    let width = len($endLine)
    var outputLen = buf.len
    for i in (startLine - 1) ..< min(endLine, totalLines):
      let line = align($(i + 1), width) & " | " & allLines[i] & "\n"
      outputLen += line.len
      if outputLen > MaxReadBytes:
        buf.add "[output truncated]\n"
        break
      buf.add line

    return ToolResult(output: buf, isError: false)

  (def, run)
