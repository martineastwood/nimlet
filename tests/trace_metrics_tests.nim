import std/[asyncdispatch, json, os, strutils, unittest]
import nimgent
import ../src/agent
import ../src/config
import ../src/session
import ../src/trace_metrics
import ../src/ui/turn

type TestProvider = ref object of Provider
  response: ProviderResponse
  lastTurnId: string

method generateAsync(provider: TestProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  provider.lastTurnId = request.turnId
  provider.response

suite "nimlet trace metrics":
  test "aggregates completed model, step, and tool spans":
    let metrics = newTraceMetrics()
    metrics.beginTurn("turn-1")
    metrics.observe(TraceSpan(kind: skModel, startNs: 0,
      endNs: 125_000_000, status: ssOk,
      attributes: %*{"input_tokens": 10, "output_tokens": 4,
        "cache_read_tokens": 2, "will_retry": true}))
    metrics.observe(TraceSpan(kind: skStep, startNs: 0, endNs: 1_000_000,
      status: ssOk, attributes: newJObject()))
    metrics.observe(TraceSpan(kind: skTool, startNs: 0,
      endNs: 50_000_000, status: ssError,
      attributes: %*{"tool_name": "bash", "is_error": true}))
    metrics.finishTurn()
    check metrics.hasData
    check metrics.steps == 1
    check metrics.modelCalls == 1
    check metrics.retries == 1
    check metrics.toolCalls == 1
    check metrics.toolErrors == 1
    check metrics.modelDurationMs == 125
    check metrics.toolDurationMs == 50
    check metrics.usage.inputTokens == 10
    check metrics.usage.outputTokens == 4
    check metrics.usage.cacheReadTokens == 2

  test "trace sink updates the collector":
    let metrics = newTraceMetrics()
    let sink = metrics.traceSink
    sink(TraceSpan(kind: skModel, startNs: 0, endNs: 1_000_000,
      status: ssOk, attributes: %*{"input_tokens": 7}))
    check metrics.modelCalls == 1
    check metrics.usage.inputTokens == 7

  test "agent turns pass tracing through to nimgent":
    let root = getTempDir() / "nimlet-trace-metrics-test"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.workspace = root
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    defer: agent.stopExtensions()
    let provider = TestProvider(name: "test", response: ProviderResponse(
      model: "test/model", content: @[text("done")],
      usage: Usage(inputTokens: 11, outputTokens: 3),
      finishReason: frEndTurn))
    agent.provider = provider
    agent.session.addUserMessage("hello")
    var ui = consoleSink(traced = true)
    ui.emit = proc (level: MsgLevel, value: string) = discard
    ui.commitGenerate = proc (response: ProviderResponse, final: bool) = discard
    agent.runTurn(ui)
    check provider.lastTurnId == agent.traceMetrics.turnId
    check provider.lastTurnId.len > 0
    check agent.traceMetrics.modelCalls == 1
    check agent.traceMetrics.steps == 1
    check agent.traceMetrics.usage.inputTokens == 11
    check agent.traceMetrics.usage.outputTokens == 3
    var output = ""
    ui.emit = proc (level: MsgLevel, value: string) = output.add value
    check agent.processInput("/stats", ui)
    check "Turn usage: ↑11  ↓3" in output
    check "calls 1" in output
