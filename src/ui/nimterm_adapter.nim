## Boundary adapters from agent lifecycle events to nimterm's generic UI events.

import nimterm/events
import ../events

proc toAgentUiEvent*(event: NimletEvent): AgentUiEvent =
  let kind = case event.kind
    of neRunStarted: ueRunStarted
    of neStepStarted: ueStepStarted
    of neTextDelta: ueTextDelta
    of neThinkingDelta: ueThinkingDelta
    of neToolCalled: ueToolCalled
    of neApprovalRequired: ueApprovalRequired
    of neToolOutputDelta: ueToolOutputDelta
    of neToolResult: ueToolResult
    of neStepFinished: ueStepFinished
    of neRunFinished: ueRunFinished
    of neError: ueError
  result = AgentUiEvent(
    kind: kind, runId: event.runId,
    sessionId: event.sessionId, turnId: event.turnId, step: event.step,
    prompt: event.prompt, model: event.model, text: event.text,
    toolId: event.toolId, toolName: event.toolName, toolInput: event.toolInput,
    toolOutput: event.toolOutput, isError: event.isError,
    durationMs: event.durationMs, error: event.error)
  if event.kind == neApprovalRequired:
    result.approvalChoices.add ApprovalChoice(id: "once", key: "enter", label: "once")
    if event.canRemember:
      result.approvalChoices.add ApprovalChoice(id: "session", key: "s", label: "session")
      result.approvalChoices.add ApprovalChoice(id: "project", key: "p", label: "project")
    result.approvalChoices.add ApprovalChoice(id: "deny", key: "n", label: "deny")
    result.cancelChoiceId = "deny"
