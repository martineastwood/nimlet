## grep and glob — find files and content without shelling out to bash.

import std/[asyncdispatch, json, os, re, strutils]
import tool, ../workspace, nimgent

const
  defaultGrepHits = 80
  maxGrepHits = 200
  defaultGlobHits = 200
  maxScanBytes = 1_000_000

proc underPrefix(rel, prefix: string): bool =
  if prefix.len == 0: return true
  let p = prefix.canonRel.strip(chars = {'/'})
  if p.len == 0: return true
  rel == p or rel.startsWith(p & "/")

proc isProbablyBinary(content: string): bool =
  let n = min(content.len, 8192)
  for i in 0 ..< n:
    if content[i] == '\0': return true
  false

proc grepWorkspace*(root, pattern, glob, relPath: string, maxHits: int,
                    insensitive: bool): seq[string] =
  ## PCRE search over the current workspace file list. Raises RegexError.
  if pattern.len == 0: return
  let flags = if insensitive: {reIgnoreCase, reStudy} else: {reStudy}
  let rx = re(pattern, flags)
  let hits = max(1, min(maxHits, maxGrepHits))
  for rel in listWorkspaceFiles(root):
    if not underPrefix(rel, relPath): continue
    if glob.len > 0 and not globMatch(rel, glob): continue
    let path = root / rel
    if not fileExists(path): continue
    var content: string
    try:
      if getFileSize(path) > maxScanBytes: continue
      content = readFile(path)
    except CatchableError:
      continue
    if isProbablyBinary(content): continue
    var lineno = 0
    for line in content.splitLines:
      inc lineno
      if find(line, rx) < 0: continue
      result.add rel & ":" & $lineno & ":" & line
      if result.len >= hits: return

proc globWorkspace*(root, pattern, relPath: string, maxHits: int): seq[string] =
  if pattern.len == 0: return
  let hits = max(1, min(maxHits, defaultGlobHits))
  for rel in listWorkspaceFiles(root):
    if not underPrefix(rel, relPath): continue
    if not globMatch(rel, pattern): continue
    result.add rel
    if result.len >= hits: return

proc makeGrepTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "grep",
    description: "Search file contents with a PCRE regex (plain text still works). Filter with glob (e.g. **/*.nim) and optional subdirectory path.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "pattern": {"type": "string", "description": "PCRE regex. Escape specials (e.g. foo\\()."},
        "glob": {"type": "string", "description": "Only search files matching this glob."},
        "path": {"type": "string", "description": "Subdirectory relative to the workspace."},
        "case_insensitive": {"type": "boolean", "description": "Ignore case. Default false."},
        "max_matches": {"type": "integer", "description": "Cap matches (default 80, max 200)."}
      },
      "required": ["pattern"]
    }
  )
  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let pattern = input.getOrDefault("pattern").getStr
    if pattern.len == 0:
      return ToolResult(output: "pattern must not be empty", isError: true)
    let rel = input.getOrDefault("path").getStr
    if rel.len > 0:
      try:
        discard ws.resolve(rel)
      except WorkspaceError as e:
        return ToolResult(output: e.msg, isError: true)
    let maxHits = if "max_matches" in input: input["max_matches"].getInt
                  else: defaultGrepHits
    var hits: seq[string]
    try:
      hits = grepWorkspace(ws.root, pattern, input.getOrDefault("glob").getStr,
        rel, maxHits, input.getOrDefault("case_insensitive").getBool)
    except RegexError as e:
      return ToolResult(output: "invalid pattern: " & e.msg, isError: true)
    if hits.len == 0:
      return ToolResult(output: "No matches.")
    var buf = hits.join("\n")
    if hits.len >= max(1, min(maxHits, maxGrepHits)):
      buf.add "\n[" & $hits.len & " matches, more omitted]"
    return ToolResult(output: buf)
  (def, run)

proc makeGlobTool*(ws: Workspace): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "glob",
    description: "List workspace files matching a glob (e.g. **/*.nim, src/**/test_*.nim).",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "pattern": {"type": "string", "description": "Glob pattern. * is one segment, ** is any depth."},
        "path": {"type": "string", "description": "Subdirectory relative to the workspace."}
      },
      "required": ["pattern"]
    }
  )
  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let pattern = input.getOrDefault("pattern").getStr
    if pattern.len == 0:
      return ToolResult(output: "pattern must not be empty", isError: true)
    let rel = input.getOrDefault("path").getStr
    if rel.len > 0:
      try:
        discard ws.resolve(rel)
      except WorkspaceError as e:
        return ToolResult(output: e.msg, isError: true)
    let hits = globWorkspace(ws.root, pattern, rel, defaultGlobHits)
    if hits.len == 0:
      return ToolResult(output: "No files.")
    var buf = hits.join("\n")
    if hits.len >= defaultGlobHits:
      buf.add "\n[" & $hits.len & " files, more omitted]"
    return ToolResult(output: buf)
  (def, run)
