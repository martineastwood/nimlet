## External tools: Unix-style ephemeral processes discovered via tool.json.
##
## At startup we only read manifests. The executable runs only when invoked.
## runExtension is public so lifecycle hooks can reuse the same protocol later.

import std/[algorithm, asyncdispatch, json, os, osproc, strformat, strutils, times]
when not defined(linux):
  import posix
import config
import nimgent
import childproc
import tools/tool

const
  DefaultTimeout* = 30
  BuiltinToolNames* = ["ask_user", "bash", "edit", "glob", "grep", "read",
    "read_skill", "write"]

type
  ExtensionTool* = object
    name*: string
    description*: string
    command*: seq[string]
    timeoutSeconds*: int
    inputSchema*: JsonNode
    dir*: string

  DiscoverResult* = object
    tools*: seq[ExtensionTool]
    warnings*: seq[string]

proc resolveCommand(toolDir, cmd0: string): string =
  if cmd0.isAbsolute:
    cmd0
  else:
    toolDir / cmd0

proc parseCommandArray*(doc: JsonNode):
    tuple[ok: bool, command: seq[string], err: string] =
  if "command" notin doc or doc["command"].kind != JArray or doc["command"].len == 0:
    return (false, @[], "command must be a nonempty array")
  for item in doc["command"]:
    if item.kind != JString or item.getStr.len == 0:
      return (false, @[], "command entries must be nonempty strings")
    result.command.add item.getStr
  result.ok = true

proc parseTimeoutSeconds*(doc: JsonNode, default = DefaultTimeout):
    tuple[ok: bool, timeout: int, err: string] =
  result.ok = true
  result.timeout = default
  if "timeout_seconds" notin doc:
    return
  if doc["timeout_seconds"].kind != JInt:
    return (false, default, "timeout_seconds must be an integer")
  result.timeout = max(1, doc["timeout_seconds"].getInt)

proc parseManifest(path: string): tuple[ok: bool, tool: ExtensionTool, err: string] =
  var doc: JsonNode
  try:
    doc = parseJson(readFile(path))
  except CatchableError as e:
    return (false, ExtensionTool(), "invalid JSON: " & e.msg)
  if doc.isNil or doc.kind != JObject:
    return (false, ExtensionTool(), "manifest must be a JSON object")

  let name = if "name" in doc: doc["name"].getStr.strip else: ""
  let description = if "description" in doc: doc["description"].getStr else: ""
  if name.len == 0:
    return (false, ExtensionTool(), "missing name")
  if description.len == 0:
    return (false, ExtensionTool(), "missing description")
  let command = parseCommandArray(doc)
  if not command.ok:
    return (false, ExtensionTool(), command.err)
  if "input_schema" notin doc or doc["input_schema"].kind != JObject:
    return (false, ExtensionTool(), "input_schema must be a JSON object")
  let timeout = parseTimeoutSeconds(doc)
  if not timeout.ok:
    return (false, ExtensionTool(), timeout.err)

  result.ok = true
  result.tool = ExtensionTool(
    name: name,
    description: description,
    command: command.command,
    timeoutSeconds: timeout.timeout,
    inputSchema: doc["input_schema"],
    dir: path.parentDir)

proc discoverExtensions*(workspace: string): DiscoverResult =
  ## Later roots override the same tool name: global → `.agent` → `.nimlet`.
  for dir in collectPluginDirs(workspace, "tools", "tool.json"):
    let parsed = parseManifest(dir / "tool.json")
    if not parsed.ok:
      result.warnings.add "skipping " & dir & ": " & parsed.err
      continue
    result.tools.overrideNamed(parsed.tool)
  result.tools.sort(proc(a, b: ExtensionTool): int =
    let byName = cmp(a.name.toLowerAscii, b.name.toLowerAscii)
    if byName != 0: byName else: cmp(a.dir, b.dir))

proc isBuiltinName*(name: string): bool =
  let lower = name.toLowerAscii
  for b in BuiltinToolNames:
    if b == lower:
      return true
  false

proc runExtension*(ext: ExtensionTool, input: JsonNode, workspace: string,
                   maxOutputBytes = 100_000,
                   shouldCancel: CancelCheck = nil): Future[ToolResult] {.async.} =
  ## Spawn the tool: stdin = JSON args, stdout must be JSON, cwd = workspace.
  let spawnCmd = resolveCommand(ext.dir, ext.command[0])
  if not fileExists(spawnCmd):
    return ToolResult(output: "extension executable not found: " & spawnCmd, isError: true)
  let spawnArgs = if ext.command.len > 1: ext.command[1 .. ^1] else: @[]

  let start = epochTime()
  let stamp = $getCurrentProcessId() & "-" & $int(start * 1_000_000)
  let stdinPath = getTempDir() / ("nimlet-ext-" & stamp & ".in")
  let stdoutPath = getTempDir() / ("nimlet-ext-" & stamp & ".out")
  let stderrPath = getTempDir() / ("nimlet-ext-" & stamp & ".err")
  defer:
    if fileExists(stdinPath): removeFile(stdinPath)
    if fileExists(stdoutPath): removeFile(stdoutPath)
    if fileExists(stderrPath): removeFile(stderrPath)

  let payload = if input.isNil: newJObject() else: input
  writeFile(stdinPath, $payload)

  # Redirect via the shell so stdout/stderr cannot fill a pipe and deadlock.
  var argvQuoted = quoteShell(spawnCmd)
  for a in spawnArgs:
    argvQuoted.add " "
    argvQuoted.add quoteShell(a)
  let shell = getEnv("SHELL", "/bin/sh")
  let script = argvQuoted & " <" & quoteShell(stdinPath) &
    " >" & quoteShell(stdoutPath) & " 2>" & quoteShell(stderrPath)
  let shellArgs = @["-c", script]
  var spawnShell = shell
  var spawnShellArgs = shellArgs
  var spawnOpts = {poUsePath}
  when defined(linux):
    spawnShell = "setsid"
    spawnShellArgs = @[shell] & shellArgs
  else:
    spawnOpts.incl poDaemon

  let p = startProcess(
    command = spawnShell,
    args = spawnShellArgs,
    options = spawnOpts,
    workingDir = workspace)
  when not defined(linux):
    let pid = Pid(p.processID)
    discard setpgid(pid, pid)

  let (endKind, exitCode) = await waitForChildAsync(p, ext.timeoutSeconds,
    shouldCancel)
  let elapsed = epochTime() - start
  p.close()
  let ms = int(elapsed * 1000)

  var stdout = if fileExists(stdoutPath): readFile(stdoutPath) else: ""
  var stderr = if fileExists(stderrPath): readFile(stderrPath) else: ""
  stdout = truncateOutput(stdout, maxOutputBytes)
  stderr = truncateOutput(stderr, maxOutputBytes)

  if endKind == weTimeout:
    var msg = fmt"TIMEOUT after {ext.timeoutSeconds}s ({ms}ms)"
    if stdout.len == 0 and stderr.len > 0:
      msg.add "\n\nstderr:\n" & stderr
    elif stdout.len > 0:
      msg.add "\n\n" & stdout
    return ToolResult(output: msg, isError: true)
  if endKind == weCancelled:
    var msg = fmt"INTERRUPTED ({ms}ms)"
    if stdout.len == 0 and stderr.len > 0:
      msg.add "\n\nstderr:\n" & stderr
    elif stdout.len > 0:
      msg.add "\n\n" & stdout
    return ToolResult(output: msg, isError: true)

  var jsonOk = false
  if stdout.len > 0:
    try:
      discard parseJson(stdout)
      jsonOk = true
    except CatchableError:
      jsonOk = false

  let failed = exitCode != 0 or not jsonOk
  if failed and stdout.len == 0 and stderr.len > 0:
    var msg = if exitCode != 0: fmt"exit_code: {exitCode}" & "\n\nstderr:\n" & stderr
              else: "stdout was not valid JSON\n\nstderr:\n" & stderr
    return ToolResult(output: msg, isError: true)
  if not jsonOk:
    var msg = "stdout was not valid JSON"
    if stdout.len > 0:
      msg.add "\n\n" & stdout
    return ToolResult(output: msg, isError: true)
  return ToolResult(output: stdout, isError: exitCode != 0)

proc makeExtensionTool*(ext: ExtensionTool, workspace: string,
                        maxOutputBytes = 100_000): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: ext.name,
    description: ext.description,
    inputSchema: ext.inputSchema)
  let captured = ext
  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    return await runExtension(captured, input, workspace, maxOutputBytes)
  (def, run)

proc registerExtensions*(reg: var ToolRegistry, workspace: string,
                         maxOutputBytes = 100_000): seq[string] =
  ## Discover and register external tools. Built-in names always win.
  ## Returns warnings (invalid manifests, builtin collisions).
  let discovered = discoverExtensions(workspace)
  result = discovered.warnings
  for ext in discovered.tools:
    if isBuiltinName(ext.name):
      result.add "skipping extension '" & ext.name &
        "': name collides with a built-in tool"
      continue
    let pair = makeExtensionTool(ext, workspace, maxOutputBytes)
    reg.register(pair[0], pair[1])
