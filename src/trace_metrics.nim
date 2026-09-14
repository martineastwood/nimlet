## Per-turn metrics collected from nimgent's completed trace spans.

import std/[json, times]
import nimgent

type
  TraceMetrics* = ref object
    turnId*: string
    active*: bool
    steps*: int
    modelCalls*: int
    retries*: int
    toolCalls*: int
    toolErrors*: int
    modelDurationMs*: int
    toolDurationMs*: int
    turnDurationMs*: int
    usage*: Usage
    failed*: bool
    cancelled*: bool
    lastError*: string
    startedNs: int64
    endedNs: int64

proc nowNs(): int64 = int64(epochTime() * 1_000_000_000)

proc newTraceMetrics*(): TraceMetrics = TraceMetrics()

proc reset*(metrics: TraceMetrics) =
  if metrics.isNil: return
  metrics.turnId = ""
  metrics.active = false
  metrics.steps = 0
  metrics.modelCalls = 0
  metrics.retries = 0
  metrics.toolCalls = 0
  metrics.toolErrors = 0
  metrics.modelDurationMs = 0
  metrics.toolDurationMs = 0
  metrics.turnDurationMs = 0
  metrics.usage = Usage()
  metrics.failed = false
  metrics.cancelled = false
  metrics.lastError = ""
  metrics.startedNs = 0
  metrics.endedNs = 0

proc beginTurn*(metrics: TraceMetrics, turnId: string) =
  if metrics.isNil: return
  metrics.reset()
  metrics.turnId = turnId
  metrics.active = true
  metrics.startedNs = nowNs()

proc finishTurn*(metrics: TraceMetrics) =
  if metrics.isNil or not metrics.active: return
  metrics.active = false
  metrics.endedNs = nowNs()
  metrics.turnDurationMs = int(max(0'i64,
    metrics.endedNs - metrics.startedNs) div 1_000_000)

proc hasData*(metrics: TraceMetrics): bool =
  not metrics.isNil and (metrics.steps > 0 or metrics.modelCalls > 0 or
    metrics.toolCalls > 0 or metrics.failed or metrics.cancelled)

proc intAttribute(span: TraceSpan, key: string): int =
  if span.isNil or span.attributes.isNil or span.attributes.kind != JObject or
      key notin span.attributes:
    return 0
  let value = span.attributes[key]
  case value.kind
  of JInt: value.getInt
  of JFloat: int(value.getFloat)
  else: 0

proc boolAttribute(span: TraceSpan, key: string): bool =
  if span.isNil or span.attributes.isNil or span.attributes.kind != JObject or
      key notin span.attributes:
    return false
  let value = span.attributes[key]
  if value.kind == JBool: value.getBool else: false

proc observe*(metrics: TraceMetrics, span: TraceSpan) =
  if metrics.isNil or span.isNil: return
  case span.kind
  of skStep:
    inc metrics.steps
  of skModel:
    inc metrics.modelCalls
    metrics.modelDurationMs += span.durationMs()
    metrics.usage.inputTokens += intAttribute(span, "input_tokens")
    metrics.usage.outputTokens += intAttribute(span, "output_tokens")
    metrics.usage.cacheReadTokens += intAttribute(span, "cache_read_tokens")
    metrics.usage.cacheWriteTokens += intAttribute(span, "cache_write_tokens")
    if boolAttribute(span, "will_retry"): inc metrics.retries
    if span.status == ssError: metrics.failed = true
    if span.status == ssCancelled: metrics.cancelled = true
  of skTool:
    inc metrics.toolCalls
    metrics.toolDurationMs += span.durationMs()
    if span.status == ssError or boolAttribute(span, "is_error"):
      inc metrics.toolErrors
    if span.status == ssError: metrics.failed = true
    if span.status == ssCancelled: metrics.cancelled = true
  of skRun:
    if span.status == ssError: metrics.failed = true
    if span.status == ssCancelled: metrics.cancelled = true
    if span.error.len > 0: metrics.lastError = span.error
  of skEmbedding:
    discard

proc traceSink*(metrics: TraceMetrics): TraceSink =
  if metrics.isNil: return
  result = proc (span: TraceSpan) = metrics.observe(span)
