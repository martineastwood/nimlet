## Lifecycle events emitted by nimlet's coding-agent loop.

import std/json

type
  NimletEventKind* = enum
    neRunStarted
    neStepStarted
    neTextDelta
    neThinkingDelta
    neToolCalled
    neApprovalRequired
    neToolResult
    neStepFinished
    neRunFinished
    neError

  NimletEvent* = object
    kind*: NimletEventKind
    runId*: string
    sessionId*: string
    turnId*: string
    step*: int
    prompt*: string
    model*: string
    text*: string
    toolId*: string
    toolName*: string
    toolInput*: JsonNode
    toolOutput*: string
    isError*: bool
    durationMs*: int
    error*: string
    canRemember*: bool
