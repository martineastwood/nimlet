## write tool — create a new file or replace an existing one.

import std/[asyncdispatch, json, os, strformat]
import tool, ../workspace, nimgent

proc makeWriteTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "write",
    description: "Create a new file or overwrite an existing file. Use edit for targeted changes.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "File path relative to workspace root."},
        "content": {"type": "string", "description": "Full file content."},
        "overwrite": {"type": "boolean", "description": "Must be true to replace an existing file."}
      },
      "required": ["path", "content"]
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let path = input["path"].getStr
    var resolved: string
    try:
      resolved = ws.resolve(path)
    except WorkspaceError as e:
      return ToolResult(output: e.msg, isError: true)

    let content = input["content"].getStr
    let overwrite = if "overwrite" in input: input["overwrite"].getBool else: false

    if fileExists(resolved) and not overwrite:
      return ToolResult(
        output: "File already exists: " & path & "\nSet overwrite: true to replace it.",
        isError: true)

    let dir = resolved.parentDir
    if dir.len > 0: createDir(dir)

    writeFileAtomic(resolved, content)
    clearMentionFileCache(ws.root)
    let version = fileVersion(resolved)
    return ToolResult(
      output: fmt"OK — wrote {ws.relative(resolved)}" & "\n" & fmt"version: {version}",
      isError: false)

  (def, run)
