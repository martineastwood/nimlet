## Lifecycle hooks: ephemeral JSON processes invoked by the agent.
##
## Same spawn protocol as external tools (runExtension). Fail-open on
## crash/timeout/bad JSON; only explicit {"allow": false} blocks.

import std/[algorithm, asyncdispatch, json, os, strutils]
import config
import extensions
import tools/tool

type
  HookEvent* = enum
    hePreToolCall = "pre_tool_call"
    hePostToolCall = "post_tool_call"
    heSessionStart = "session_start"
    heSessionEnd = "session_end"
    hePreCompact = "pre_compact"
    hePostCompact = "post_compact"
    heTurnStart = "turn_start"
    heTurnEnd = "turn_end"

  Hook* = object
    name*: string
    event*: HookEvent
    tools*: seq[string] ## empty = all tools (pre/post tool only)
    command*: seq[string]
    timeoutSeconds*: int
    dir*: string

  HookDiscoverResult* = object
    hooks*: seq[Hook]
    warnings*: seq[string]

  HookOutcome* = object
    allowed*: bool
    reason*: string
    warnings*: seq[string]
    ## Rewritten tool arguments from pre_tool_call (nil = unchanged).
    arguments*: JsonNode
    ## Rewritten tool result from post_tool_call.
    output*: string
    isError*: bool
    hasOutput*: bool
    hasIsError*: bool
    ## Extra compaction instruction from pre_compact.
    instruction*: string

proc parseEvent(s: string): tuple[ok: bool, event: HookEvent] =
  try:
    (true, parseEnum[HookEvent](s.strip.toLowerAscii))
  except ValueError:
    (false, hePreToolCall)

proc parseHookManifest(path: string): tuple[ok: bool, hook: Hook, err: string] =
  var doc: JsonNode
  try:
    doc = parseJson(readFile(path))
  except CatchableError as e:
    return (false, Hook(), "invalid JSON: " & e.msg)
  if doc.isNil or doc.kind != JObject:
    return (false, Hook(), "manifest must be a JSON object")

  let name = if "name" in doc: doc["name"].getStr.strip else: ""
  if name.len == 0:
    return (false, Hook(), "missing name")
  if "event" notin doc:
    return (false, Hook(), "missing event")
  let ev = parseEvent(doc["event"].getStr)
  if not ev.ok:
    return (false, Hook(), "unknown event: " & doc["event"].getStr)
  let command = parseCommandArray(doc)
  if not command.ok:
    return (false, Hook(), command.err)

  var tools: seq[string] = @[]
  if "tools" in doc:
    if doc["tools"].kind != JArray:
      return (false, Hook(), "tools must be an array")
    for item in doc["tools"]:
      if item.kind != JString or item.getStr.strip.len == 0:
        return (false, Hook(), "tools entries must be nonempty strings")
      tools.add item.getStr.strip.toLowerAscii

  let timeout = parseTimeoutSeconds(doc)
  if not timeout.ok:
    return (false, Hook(), timeout.err)

  result.ok = true
  result.hook = Hook(
    name: name,
    event: ev.event,
    tools: tools,
    command: command.command,
    timeoutSeconds: timeout.timeout,
    dir: path.parentDir)

proc discoverHooks*(workspace: string): HookDiscoverResult =
  ## Later roots override the same hook name: global → `.agent` → `.nimlet`.
  for dir in collectPluginDirs(workspace, "hooks", "hook.json"):
    let parsed = parseHookManifest(dir / "hook.json")
    if not parsed.ok:
      result.warnings.add "skipping " & dir & ": " & parsed.err
      continue
    result.hooks.overrideNamed(parsed.hook)
  result.hooks.sort(proc(a, b: Hook): int =
    let byName = cmp(a.name.toLowerAscii, b.name.toLowerAscii)
    if byName != 0: byName else: cmp(a.dir, b.dir))

proc matchesTool(hook: Hook, toolName: string): bool =
  if hook.tools.len == 0:
    return true
  let lower = toolName.toLowerAscii
  for t in hook.tools:
    if t == lower:
      return true
  false

proc asExtension(hook: Hook): ExtensionTool =
  ExtensionTool(
    name: hook.name,
    description: "",
    command: hook.command,
    timeoutSeconds: hook.timeoutSeconds,
    inputSchema: %*{"type": "object"},
    dir: hook.dir)

proc recordDeny(result: var HookOutcome, doc: JsonNode) =
  result.allowed = false
  if "reason" in doc and doc["reason"].kind == JString and
     doc["reason"].getStr.len > 0:
    if result.reason.len == 0:
      result.reason = doc["reason"].getStr
    else:
      result.reason.add "; " & doc["reason"].getStr
  elif result.reason.len == 0:
    result.reason = "blocked by hook"

proc runHooks*(hooks: seq[Hook], event: HookEvent, payload: JsonNode,
               workspace: string, toolName = "",
               maxOutputBytes = 100_000,
               shouldCancel: CancelCheck = nil): Future[HookOutcome] {.async.} =
  ## Run matching hooks. Fail-open except explicit allow:false.
  ## pre_tool_call may rewrite arguments; post_tool_call may rewrite output.
  ## pre_compact may rewrite instruction. Mutations chain across hooks.
  result.allowed = true
  var payload = if payload.isNil: newJObject() else: copy(payload)
  for hook in hooks:
    if hook.event != event:
      continue
    if event in {hePreToolCall, hePostToolCall} and not hook.matchesTool(toolName):
      continue
    let res = await runExtension(hook.asExtension, payload, workspace,
      maxOutputBytes, shouldCancel)
    if res.isError:
      result.warnings.add "hook '" & hook.name & "' failed: " & res.output
      continue
    var doc: JsonNode
    try:
      doc = parseJson(res.output)
    except CatchableError as e:
      result.warnings.add "hook '" & hook.name & "' failed: " & e.msg
      continue
    if doc.kind != JObject:
      continue

    if event in {hePreToolCall, hePreCompact} and "allow" in doc and
       doc["allow"].kind == JBool and not doc["allow"].getBool:
      recordDeny(result, doc)
      # Still apply mutations from earlier hooks; stop running further denies' chain
      # but continue other hooks so all deniers can contribute reasons.
      continue

    case event
    of hePreToolCall:
      if "arguments" in doc and doc["arguments"].kind == JObject:
        result.arguments = doc["arguments"]
        payload["arguments"] = doc["arguments"]
    of hePostToolCall:
      if "output" in doc and doc["output"].kind == JString:
        result.output = doc["output"].getStr
        result.hasOutput = true
        payload["output"] = doc["output"]
      if "is_error" in doc and doc["is_error"].kind == JBool:
        result.isError = doc["is_error"].getBool
        result.hasIsError = true
        payload["is_error"] = doc["is_error"]
    of hePreCompact:
      if "instruction" in doc and doc["instruction"].kind == JString and
         doc["instruction"].getStr.len > 0:
        result.instruction = doc["instruction"].getStr
        payload["instruction"] = doc["instruction"]
    else:
      discard
  if not result.allowed and result.reason.len == 0:
    result.reason = "blocked by hook"

proc sessionPayload*(sessionId, workspace: string): JsonNode =
  %*{"session_id": sessionId, "workspace": workspace}

proc turnPayload*(sessionId, workspace: string, interrupted = false): JsonNode =
  result = sessionPayload(sessionId, workspace)
  if interrupted:
    result["interrupted"] = %true

proc preToolPayload*(tool: string, arguments: JsonNode): JsonNode =
  %*{
    "tool": tool,
    "arguments": if arguments.isNil: newJObject() else: arguments
  }

proc postToolPayload*(tool: string, arguments: JsonNode, output: string,
                      isError: bool): JsonNode =
  %*{
    "tool": tool,
    "arguments": if arguments.isNil: newJObject() else: arguments,
    "output": output,
    "is_error": isError
  }

proc preCompactPayload*(sessionId, workspace, instruction: string,
                        tokensBefore: int): JsonNode =
  %*{
    "session_id": sessionId,
    "workspace": workspace,
    "instruction": instruction,
    "tokens_before": tokensBefore
  }

proc postCompactPayload*(sessionId, workspace: string, didCompact: bool,
                         summary: string, firstKeptIndex, tokensBefore: int,
                         message: string): JsonNode =
  %*{
    "session_id": sessionId,
    "workspace": workspace,
    "did_compact": didCompact,
    "summary": summary,
    "first_kept_index": firstKeptIndex,
    "tokens_before": tokensBefore,
    "message": message
  }
