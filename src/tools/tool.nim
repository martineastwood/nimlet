## Tool dispatcher: registers tools and executes them by name.

import std/[asyncdispatch, json, tables]
import nimgent

type
  ToolProc* = proc(input: JsonNode): Future[ToolResult] {.closure.}

  CancelCheck* = proc (): bool {.closure.}
  OutputCallback* = proc (output: string) {.closure.}

  ToolRegistry* = object
    tools: OrderedTable[string, ToolProc]
    definitions: seq[ToolDefinition]

var activeCancel {.threadvar.}: CancelCheck
var activeOutput {.threadvar.}: OutputCallback

proc cancelRequested*(): bool =
  ## True when the in-flight `execute` should abort (Ctrl-C, Escape).
  not activeCancel.isNil and activeCancel()

proc streamOutput*(output: string) =
  if not activeOutput.isNil and output.len > 0: activeOutput(output)

proc register*(reg: var ToolRegistry, def: ToolDefinition, fn: ToolProc) =
  if reg.tools.len == 0:
    reg.tools = initOrderedTable[string, ToolProc]()
  reg.tools[def.name] = fn
  reg.definitions.add def

proc definitions*(reg: ToolRegistry): seq[ToolDefinition] =
  reg.definitions

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
    result = await reg.tools[name](input)
    if result.isError and result.error.code.len == 0:
      result.error = toolError("tool_error", result.output)
  except CatchableError as e:
    return toolFailure("exception", e.msg)
