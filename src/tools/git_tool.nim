## Read-only Git context for planning and code review.

import std/[asyncdispatch, json, osproc, streams, strutils]
import tool, ../childproc, ../workspace, nimgent

const
  DefaultLogLimit = 20
  MaxLogLimit = 100
  MaxGitOutputBytes = 100_000

proc makeGitTool*(ws: Workspace,
                  maxOutputBytes = MaxGitOutputBytes): (ToolDefinition, ToolProc) =
  let outputLimit = max(2, maxOutputBytes)
  let def = ToolDefinition(
    name: "git",
    description: "Inspect local Git status, history, diffs, or blame without changing the workspace.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "operation": {"type": "string", "enum": ["status", "log", "show", "diff", "blame"], "description": "Read-only Git operation. Defaults to status."},
        "path": {"type": "string", "description": "Optional workspace-relative file or directory."},
        "commit": {"type": "string", "description": "Revision for log/show. Defaults to HEAD for show."},
        "limit": {"type": "integer", "description": "Maximum log entries (default 20, max 100)."}
      }
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let operation = input.getOrDefault("operation").getStr.strip.toLowerAscii
    let op = if operation.len == 0: "status" else: operation
    if op notin ["status", "log", "show", "diff", "blame"]:
      return ToolResult(output: "unsupported git operation: " & op, isError: true)

    var pathArg = ""
    let suppliedPath = input.getOrDefault("path").getStr.strip
    if suppliedPath.len > 0:
      try:
        pathArg = ws.relative(ws.resolve(suppliedPath))
      except WorkspaceError as e:
        return ToolResult(output: e.msg, isError: true)
      if pathArg.len == 0: pathArg = "."

    var args: seq[string]
    case op
    of "status":
      args = @["status", "--short", "--untracked-files=all", "--"]
    of "log":
      let requested = input.getOrDefault("limit").getInt
      let limit = if requested <= 0: DefaultLogLimit else: min(requested, MaxLogLimit)
      args = @["log", "--oneline", "--decorate", "-n", $limit]
      let commit = input.getOrDefault("commit").getStr.strip
      if commit.len > 0:
        if commit.startsWith("-"):
          return ToolResult(output: "commit must not start with '-': " & commit,
            isError: true)
        args.add commit
      args.add "--"
    of "show":
      let commit = input.getOrDefault("commit").getStr.strip
      let revision = if commit.len == 0: "HEAD" else: commit
      if revision.startsWith("-"):
        return ToolResult(output: "commit must not start with '-': " & revision,
          isError: true)
      args = @["show", "--format=fuller", "--no-ext-diff", "--no-renames",
        revision, "--"]
    of "diff":
      args = @["diff", "--no-ext-diff", "--"]
    of "blame":
      if pathArg.len == 0:
        return ToolResult(output: "blame requires path", isError: true)
      args = @["blame", "--", pathArg]
    else: discard
    if op in ["status", "log", "show", "diff"] and pathArg.len > 0:
      args.add pathArg

    var process: Process
    try:
      process = startProcess("git", args = args, workingDir = ws.root,
        options = {poUsePath, poStdErrToStdOut})
    except CatchableError as e:
      return ToolResult(output: "git is unavailable: " & e.msg, isError: true)
    defer: process.close()

    var output = ""
    var truncated = false
    var line = ""
    while process.outputStream.readLine(line):
      if output.len + line.len + 1 <= outputLimit:
        output.add line & "\n"
      else:
        truncated = true
    let exitCode = process.waitForExit()
    if truncated:
      output.add "\n[... git output truncated ...]\n"
    output = truncateOutput(output, outputLimit)
    if exitCode != 0:
      return ToolResult(output: "exit_code: " & $exitCode & "\n" & output,
        isError: true)
    ToolResult(output: output)

  (def, run)
