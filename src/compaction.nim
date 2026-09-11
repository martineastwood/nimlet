## Pi-style lossy compaction: summarize older turns, keep recent verbatim.
##
## Full history stays on disk. Only the model-facing message list changes.

import std/[json, strutils]
import session
import images
import nimgent

const
  defaultReserveTokens* = 16_384
  defaultKeepRecentTokens* = 20_000
  compactionMaxTokens* = 4096

  summarySystemPrompt = """
You are compacting a coding-agent session into structured working memory.
Write a concise markdown summary with these sections when relevant:

## Goal
## Current task
## Important decisions
## Files inspected
## Files modified
## Important symbols/locations
## Commands run and results
## Errors/failures
## Outstanding work
## User preferences/instructions
## Next likely steps

Preserve exact code snippets only when materially important.
Do not invent facts. Prefer concrete paths, commands, and outcomes.
""".strip

proc estimateTokens*(text: string): int =
  ## Cheap char/4 estimate (same order of magnitude as pi).
  max(1, (text.len + 3) div 4)

proc estimateContentTokens(parts: openArray[ContentBlock], workspace = "",
                           toolOutCap = -1): int =
  for part in parts:
    case part.kind
    of ckText:
      result += estimateTokens(part.text)
    of ckThinking:
      result += estimateTokens(part.thinking)
    of ckToolUse:
      result += estimateTokens(part.name)
      if not part.input.isNil: result += estimateTokens($part.input)
    of ckToolResult:
      let n = estimateTokens(part.output)
      result += (if toolOutCap >= 0: min(n, toolOutCap) else: n)
      for img in part.images:
        result += imageTokenEstimate(img, workspace)
    of ckImage:
      result += imageTokenEstimate(part.toImage, workspace)
    of ckFile:
      result += (if part.file.data.len == 0: 2000
                 else: estimateTokens(part.file.data))
    of ckSource:
      result += estimateTokens(part.source.url & part.source.title)

proc estimateMessageTokens*(message: Message, workspace = ""): int =
  ## Estimate one provider message using the same cheap heuristic as sessions.
  estimateContentTokens(message.content, workspace)

proc estimateRequestTokens*(request: ProviderRequest, workspace = ""): int =
  ## Estimate the context occupied by the complete provider request.
  ##
  ## Session history is not the whole request: stable system instructions and
  ## tool schemas can be substantial, especially for an agent with extensions.
  for system in request.system:
    result += estimateTokens(system)
  for message in request.messages:
    result += estimateMessageTokens(message, workspace)
  for tool in request.tools:
    result += estimateTokens(tool.name & tool.description)
    if not tool.inputSchema.isNil:
      result += estimateTokens($tool.inputSchema)
    if not tool.hostedOptions.isNil:
      result += estimateTokens($tool.hostedOptions)

proc estimateEventTokens*(event: SessionEvent, workspace = ""): int =
  case event.kind
  of sekUser, sekAssistant:
    result = estimateContentTokens(event.message.content, workspace)
  of sekToolResult:
    result = estimateTokens(event.toolOutput)
    for img in event.toolImages:
      result += imageTokenEstimate(img, workspace)
  of sekCompaction:
    result += estimateTokens(event.summary)
  of sekExtension, sekName, sekSelection:
    discard
proc latestCompaction*(session: Session): tuple[found: bool, index: int] =
  for i in countdown(session.events.high, 0):
    if session.events[i].kind == sekCompaction:
      return (true, i)
  (false, -1)

proc estimatedContextTokens*(session: Session): int =
  ## Prefer the last provider-reported prompt size, plus events appended after
  ## that request. A later tool result or user message otherwise goes unseen.
  var assistantIndex = -1
  for i in countdown(session.events.high, 0):
    if session.events[i].kind == sekAssistant:
      assistantIndex = i
      break
  if assistantIndex >= 0:
    let compact = session.latestCompaction
    let used = contextTokens(session.events[assistantIndex].usage)
    if used > 0 and (not compact.found or compact.index < assistantIndex):
      result = used
      for i in assistantIndex ..< session.events.len:
        result += estimateEventTokens(session.events[i], session.workspace)
      return
  for msg in session.messagesForModel:
    result += estimateContentTokens(msg.content, session.workspace)

proc estimatedContextTokens*(session: Session, request: ProviderRequest): int =
  ## Prefer provider usage when available, but never omit request-only content.
  max(estimatedContextTokens(session),
      estimateRequestTokens(request, session.workspace))

proc shouldCompact*(session: Session, contextWindow, reserveTokens: int): bool =
  if contextWindow <= 0: return false
  let limit = contextWindow - max(0, reserveTokens)
  if limit <= 0: return true
  estimatedContextTokens(session) > limit

proc shouldCompact*(session: Session, request: ProviderRequest,
                    contextWindow, reserveTokens: int): bool =
  ## Request-aware variant used by the agent loop.
  if contextWindow <= 0: return false
  let limit = contextWindow - max(0, reserveTokens)
  if limit <= 0: return true
  estimatedContextTokens(session, request) > limit

proc findCutIndex*(session: Session, keepRecentTokens: int,
                   fromIndex = 0): int =
  ## First index of the kept (verbatim) region, or -1 if nothing to compact.
  if session.events.len == 0 or fromIndex >= session.events.len:
    return -1
  var tokens = 0
  var i = session.events.high
  while i >= fromIndex:
    tokens += estimateEventTokens(session.events[i], session.workspace)
    if tokens >= max(1, keepRecentTokens):
      var cut = i
      # Start at the user turn so assistant/tool events stay paired with it.
      while cut > fromIndex and session.events[cut].kind != sekUser:
        dec cut
      if session.events[cut].kind != sekUser:
        return -1
      if cut <= fromIndex:
        return -1
      return cut
    dec i
  -1

proc serializeEvent(event: SessionEvent, toolCap = 2000): string =
  case event.kind
  of sekUser:
    result = "user:\n"
    for part in event.message.content:
      case part.kind
      of ckText: result.add part.text & "\n"
      of ckImage: result.add "[" & part.mimeType & "]\n"
      of ckFile: result.add "[" & fileLabel(part.file) & "]\n"
      of ckSource: result.add "[" & part.source.title & "](" & part.source.url & ")\n"
      else: discard
  of sekAssistant:
    result = "assistant:\n"
    for part in event.message.content:
      case part.kind
      of ckText: result.add part.text & "\n"
      of ckThinking: result.add "(thinking omitted)\n"
      of ckToolUse:
        result.add "tool_call " & part.name & " " & $part.input & "\n"
      of ckImage:
        result.add "[" & part.mimeType & "]\n"
      of ckFile:
        result.add "[" & fileLabel(part.file) & "]\n"
      of ckSource:
        result.add "[" & part.source.title & "](" & part.source.url & ")\n"
      of ckToolResult:
        discard
  of sekToolResult:
    var outp = event.toolOutput
    if outp.len > toolCap * 4:
      outp = outp[0 ..< toolCap * 4] & "\n…(truncated)…"
    result = "tool_result"
    if event.toolError: result.add " ERROR"
    result.add ":\n" & outp & "\n"
    if event.toolImages.len > 0:
      result.add "[" & $event.toolImages.len & " image]\n"
  of sekCompaction, sekExtension, sekName, sekSelection:
    result = ""

proc serializeRange*(session: Session, startIdx, endIdx: int): string =
  ## Serialize events [startIdx, endIdx) for the summarizer.
  var parts: seq[string] = @[]
  let hi = min(endIdx, session.events.len)
  for i in startIdx ..< hi:
    let chunk = serializeEvent(session.events[i])
    if chunk.len > 0: parts.add chunk
  parts.join("\n")

proc buildSummaryPrompt*(previousSummary, conversation, instruction: string): string =
  result = ""
  if previousSummary.len > 0:
    result.add "<previous-summary>\n"
    result.add previousSummary
    result.add "\n</previous-summary>\n\n"
  if instruction.len > 0:
    result.add "<compaction-instructions>\n"
    result.add instruction
    result.add "\n</compaction-instructions>\n\n"
  result.add "<conversation>\n"
  result.add conversation
  result.add "\n</conversation>\n\n"
  result.add "Produce the updated structured summary now."

proc generateSummary*(provider: Provider, model: string,
                      previousSummary, conversation, instruction: string,
                      onEvent: StreamCallback = nil): string =
  let prompt = buildSummaryPrompt(previousSummary, conversation, instruction)
  let req = ProviderRequest(
    model: model,
    system: @[summarySystemPrompt],
    messages: @[userMessage(prompt)],
    tools: @[],
    maxTokens: compactionMaxTokens,
    options: newJObject()
  )
  var response: ProviderResponse
  var acc = ""
  if onEvent.isNil:
    response = generateText(provider, req)
  else:
    var cancelled = false
    let abort = proc (): bool = not onEvent(StreamEvent(kind: seWake))
    response = streamText(provider, req, proc (ev: StreamEvent): bool =
      if ev.kind == seTextDelta:
        acc.add ev.text
      if not onEvent(ev):
        cancelled = true
        return false
      true, abort = abort)
    if cancelled:
      raise newException(ValueError, "compaction interrupted")
  result = acc.strip
  if result.len == 0:
    result = response.text.strip
  if result.len == 0:
    raise newException(ValueError, "compaction produced an empty summary")

type
  CompactionResult* = object
    didCompact*: bool
    summary*: string
    firstKeptIndex*: int
    tokensBefore*: int
    message*: string

proc prepareAndCompact*(session: var Session, provider: Provider, model: string,
                        keepRecentTokens: int,
                        instruction = "",
                        onEvent: StreamCallback = nil): CompactionResult =
  ## Summarize older events; append a compaction event. No-op if cut not found.
  let tokensBefore = estimatedContextTokens(session)
  result.tokensBefore = tokensBefore

  let prev = session.latestCompaction
  var fromIndex = 0
  var previousSummary = ""
  if prev.found:
    previousSummary = session.events[prev.index].summary
    fromIndex = session.events[prev.index].firstKeptIndex

  let cut = findCutIndex(session, keepRecentTokens, fromIndex)
  if cut < 0:
    result.message = "Nothing to compact (recent history fits in keep window)."
    return

  let conversation = serializeRange(session, fromIndex, cut)
  if conversation.strip.len == 0:
    result.message = "Nothing to compact (empty range)."
    return

  let summary = generateSummary(provider, model, previousSummary,
                                conversation, instruction, onEvent)
  session.addCompaction(summary, cut, tokensBefore)
  result.didCompact = true
  result.summary = summary
  result.firstKeptIndex = cut
  result.message = "Compacted up to event #" & $cut &
    "; kept recent verbatim (" & $tokensBefore & " tokens before)."
