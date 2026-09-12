## Tool dispatcher: registers tools and executes them by name.

import std/[asyncdispatch, json, strutils, tables]
import nimgent

type
  ToolProc* = proc(input: JsonNode): Future[ToolResult] {.closure.}

  CancelCheck* = proc (): bool {.closure.}
  OutputCallback* = proc (output: string) {.closure.}

  ToolCapability* = enum
    tcRead = "read"
    tcWrite = "write"
    tcShell = "shell"
    tcNetwork = "network"
    tcUser = "user"

  ToolCapabilities* = set[ToolCapability]

  ToolEntry = object
    definition: ToolDefinition
    run: ToolProc
    capabilities: ToolCapabilities

  ToolRegistry* = object
    tools: OrderedTable[string, ToolEntry]

var activeCancel {.threadvar.}: CancelCheck
var activeOutput {.threadvar.}: OutputCallback

proc cancelRequested*(): bool =
  ## True when the in-flight `execute` should abort (Ctrl-C, Escape).
  not activeCancel.isNil and activeCancel()

proc streamOutput*(output: string) =
  if not activeOutput.isNil and output.len > 0: activeOutput(output)

const
  UnsafeToolCapabilities* = {tcWrite, tcShell, tcNetwork}

proc inferredCapabilities*(name: string): ToolCapabilities =
  case name.toLowerAscii
  of "read", "grep", "glob", "read_skill", "git": {tcRead}
  of "ask_user": {tcUser}
  of "edit", "write": {tcWrite}
  of "bash": {tcShell}
  else: UnsafeToolCapabilities

proc parseCapabilities*(value: JsonNode):
    tuple[ok: bool, capabilities: ToolCapabilities, err: string] =
  if value.isNil or value.kind == JNull:
    return (true, UnsafeToolCapabilities, "")
  if value.kind != JArray:
    return (false, {}, "capabilities must be an array")
  for item in value:
    if item.kind != JString:
      return (false, {}, "capabilities must contain strings")
    var found = false
    for capability in ToolCapability:
      if item.getStr.toLowerAscii == $capability:
        result.capabilities.incl capability
        found = true
        break
    if not found:
      return (false, {}, "unknown capability: " & item.getStr)
  result.ok = true

proc planSafe*(capabilities: ToolCapabilities): bool =
  for capability in capabilities:
    if capability notin {tcRead, tcUser}:
      return false
  true

proc register*(reg: var ToolRegistry, def: ToolDefinition, fn: ToolProc,
               capabilities: ToolCapabilities) =
  if reg.tools.len == 0:
    reg.tools = initOrderedTable[string, ToolEntry]()
  reg.tools[def.name] = ToolEntry(definition: def, run: fn,
    capabilities: capabilities)

proc register*(reg: var ToolRegistry, def: ToolDefinition, fn: ToolProc) =
  reg.register(def, fn, inferredCapabilities(def.name))

proc definitions*(reg: ToolRegistry): seq[ToolDefinition] =
  for entry in reg.tools.values:
    result.add entry.definition

proc restrict*(reg: var ToolRegistry, allowed: openArray[string]) =
  var kept = initOrderedTable[string, ToolEntry]()
  for name, entry in reg.tools:
    for wanted in allowed:
      if name.toLowerAscii == wanted.toLowerAscii:
        kept[name] = entry
        break
  reg.tools = kept

proc contains*(reg: ToolRegistry, name: string): bool =
  name in reg.tools

proc execute*(reg: ToolRegistry, name: string, input: JsonNode,
              shouldCancel: CancelCheck = nil,
              onOutput: OutputCallback = nil): Future[ToolResult] {.async.} =
  if name notin reg.tools:
    return toolFailure("unknown_tool", "Unknown tool: " & name,
      %*{"tool": name})
  let prev = activeCancel
  let prevOutput = activeOutput
  activeCancel = shouldCancel
  activeOutput = onOutput
  defer:
    activeCancel = prev
    activeOutput = prevOutput
  try:
    result = await reg.tools[name].run(input)
    if result.isError and result.error.code.len == 0:
      result.error = toolError("tool_error", result.output)
  except CatchableError as e:
    return toolFailure("exception", e.msg)
