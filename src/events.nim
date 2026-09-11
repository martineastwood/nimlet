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
    neToolOutputDelta
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

const jsonEventVersion* = 1

proc eventType(kind: NimletEventKind): string =
  case kind
  of neRunStarted: "run_start"
  of neStepStarted: "step_start"
  of neTextDelta: "message_delta"
  of neThinkingDelta: "thinking_delta"
  of neToolCalled: "tool_call"
  of neApprovalRequired: "approval_required"
  of neToolOutputDelta: "tool_output_delta"
  of neToolResult: "tool_result"
  of neStepFinished: "step_end"
  of neRunFinished: "run_end"
  of neError: "error"

proc addIdentity(node: JsonNode, sessionId, turnId: string) =
  if sessionId.len > 0: node["session_id"] = %sessionId
  if turnId.len > 0: node["turn_id"] = %turnId

proc nimletEventJson*(event: NimletEvent): JsonNode =
  result = %*{"version": jsonEventVersion, "type": eventType(event.kind)}
  result.addIdentity(event.sessionId, event.turnId)
  if event.runId.len > 0: result["run_id"] = %event.runId
  case event.kind
  of neRunStarted:
    if event.prompt.len > 0: result["prompt"] = %event.prompt
  of neStepStarted, neStepFinished:
    result["step"] = %event.step
    if event.model.len > 0: result["model"] = %event.model
  of neTextDelta, neThinkingDelta:
    result["step"] = %event.step
    result["delta"] = %event.text
    if event.model.len > 0: result["model"] = %event.model
  of neToolCalled, neApprovalRequired:
    result["step"] = %event.step
    result["tool_id"] = %event.toolId
    result["tool_name"] = %event.toolName
    if not event.toolInput.isNil: result["input"] = event.toolInput
    if event.kind == neApprovalRequired:
      result["can_remember"] = %event.canRemember
  of neToolOutputDelta:
    result["step"] = %event.step
    result["tool_id"] = %event.toolId
    result["tool_name"] = %event.toolName
    result["delta"] = %event.toolOutput
  of neToolResult:
    result["step"] = %event.step
    result["tool_id"] = %event.toolId
    result["tool_name"] = %event.toolName
    result["output"] = %event.toolOutput
    result["is_error"] = %event.isError
  of neRunFinished:
    if event.model.len > 0: result["model"] = %event.model
  of neError:
    result["step"] = %event.step
    result["message"] = %event.error
  if event.durationMs > 0: result["duration_ms"] = %event.durationMs

proc sessionEventJson*(kind, sessionId: string, success = true): JsonNode =
  result = %*{"version": jsonEventVersion, "type": kind,
    "session_id": sessionId}
  if kind == "session_end": result["success"] = %success

proc messageEventJson*(sessionId, turnId, role, content: string,
                       model = "", final = true): JsonNode =
  result = %*{"version": jsonEventVersion, "type": "message",
    "role": role, "content": content}
  result.addIdentity(sessionId, turnId)
  if model.len > 0: result["model"] = %model
  if role == "assistant": result["final"] = %final

proc queueEventJson*(sessionId, action, content: string, depth: int,
                     requestId = "", mode = ""): JsonNode =
  result = %*{"version": jsonEventVersion, "type": "queue",
    "session_id": sessionId, "action": action, "depth": depth}
  if content.len > 0: result["content"] = %content
  if requestId.len > 0: result["request_id"] = %requestId
  if mode.len > 0: result["mode"] = %mode

proc diagnosticEventJson*(level, message: string): JsonNode =
  %*{"version": jsonEventVersion, "type": "diagnostic",
    "level": level, "message": message}
