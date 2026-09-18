## Lifecycle event vocabulary and mutation results for persistent extensions.

import std/json

type
  HookEvent* = enum
    hePreToolCall = "tool_call"
    hePostToolCall = "tool_result"
    heSessionStart = "session_start"
    heSessionEnd = "session_end"
    hePreCompact = "session_before_compact"
    hePostCompact = "session_compact"
    heTurnStart = "turn_start"
    heTurnEnd = "turn_end"
    heContext = "context"

  HookOutcome* = object
    allowed*: bool
    reason*: string
    warnings*: seq[string]
    arguments*: JsonNode
    output*: string
    isError*: bool
    hasOutput*: bool
    hasIsError*: bool
    instruction*: string
    hasCompaction*: bool
    summary*: string
    firstKeptIndex*: int
    details*: JsonNode
    system*: seq[string]
    messages*: JsonNode

proc sessionPayload*(sessionId, workspace: string): JsonNode =
  %*{"session_id": sessionId, "workspace": workspace}

proc turnPayload*(sessionId, workspace: string, interrupted = false): JsonNode =
  result = sessionPayload(sessionId, workspace)
  if interrupted: result["interrupted"] = %true

proc preToolPayload*(tool: string, arguments: JsonNode): JsonNode =
  %*{"tool": tool,
    "arguments": if arguments.isNil: newJObject() else: arguments}

proc postToolPayload*(tool: string, arguments: JsonNode, output: string,
                      isError: bool): JsonNode =
  %*{"tool": tool,
    "arguments": if arguments.isNil: newJObject() else: arguments,
    "output": output, "is_error": isError}

proc preCompactPayload*(sessionId, workspace, instruction: string,
                        tokensBefore: int, entries: JsonNode): JsonNode =
  %*{"session_id": sessionId, "workspace": workspace,
    "instruction": instruction, "tokens_before": tokensBefore,
    "entries": entries}

proc postCompactPayload*(sessionId, workspace: string, didCompact: bool,
                         summary: string, firstKeptIndex, tokensBefore: int,
                         message: string): JsonNode =
  %*{"session_id": sessionId, "workspace": workspace,
    "did_compact": didCompact, "summary": summary,
    "first_kept_index": firstKeptIndex, "tokens_before": tokensBefore,
    "message": message}
