## Tool dispatcher: registers tools and executes them by name.

import std/[asyncdispatch, json, tables]
import nimgent

type
  ToolProc* = proc(input: JsonNode): Future[ToolResult] {.closure.}

  CancelCheck* = proc (): bool {.closure.}

  ToolRegistry* = object
    tools: OrderedTable[string, ToolProc]
    definitions: seq[ToolDefinition]

var activeCancel {.threadvar.}: CancelCheck

proc cancelRequested*(): bool =
  ## True when the in-flight `execute` should abort (Ctrl-C, Escape).
  not activeCancel.isNil and activeCancel()

proc register*(reg: var ToolRegistry, def: ToolDefinition, fn: ToolProc) =
  if reg.tools.len == 0:
    reg.tools = initOrderedTable[string, ToolProc]()
  reg.tools[def.name] = fn
  reg.definitions.add def

proc definitions*(reg: ToolRegistry): seq[ToolDefinition] =
  reg.definitions

proc execute*(reg: ToolRegistry, name: string, input: JsonNode,
              shouldCancel: CancelCheck = nil): Future[ToolResult] {.async.} =
  if name notin reg.tools:
    return toolFailure("unknown_tool", "Unknown tool: " & name,
      %*{"tool": name})
  let prev = activeCancel
  activeCancel = shouldCancel
  defer: activeCancel = prev
  try:
    result = await reg.tools[name](input)
    if result.isError and result.error.code.len == 0:
      result.error = toolError("tool_error", result.output)
  except CatchableError as e:
    return toolFailure("exception", e.msg)
