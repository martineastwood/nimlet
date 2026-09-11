## Long-running JSONL control protocol over stdin/stdout.

import std/[asyncdispatch, json, os, posix, strutils]
import nimgent
import agent, events, hooks, session
import ui/turn

type
  RpcWriter* = proc (event: JsonNode) {.closure.}
  RpcRuntime* = ref object
    agent: ptr Agent
    ui: TurnSink
    writeEvent: RpcWriter
    active: Future[bool]
    activeRequestId: string
    queuedRequestId: string
    queuedPrompt: string
    interrupted: bool
    shuttingDown*: bool
    turnFailed: bool
    hadFailure: bool
    sawErrorEvent: bool
    runId: string
    turnId: string
    step: int
    cancelRead, cancelWrite: cint

var rpcSigint {.volatile.}: cint
var rpcSignalWrite = -1.cint

proc handleRpcSigint() {.noconv, raises: [], gcsafe.} =
  rpcSigint = 1
  if rpcSignalWrite >= 0:
    var byte = '\1'
    discard posix.write(rpcSignalWrite, byte.addr, 1)

proc send(runtime: RpcRuntime, event: JsonNode) =
  if not runtime.writeEvent.isNil:
    runtime.writeEvent(event)
  else:
    stdout.writeLine($event)
    stdout.flushFile()

proc responseJson(id: string, ok: bool, state = "", error = ""): JsonNode =
  result = %*{"version": jsonEventVersion, "type": "response",
    "id": id, "ok": ok}
  if state.len > 0: result["state"] = %state
  if error.len > 0: result["error"] = %error

proc signalCancel(runtime: RpcRuntime) =
  runtime.interrupted = true
  if runtime.cancelWrite >= 0:
    var byte = '\1'
    discard posix.write(runtime.cancelWrite, byte.addr, 1)

proc drainCancel(runtime: RpcRuntime) =
  if runtime.cancelRead < 0: return
  var bytes: array[64, char]
  while posix.read(runtime.cancelRead, bytes.addr, bytes.len) > 0:
    discard

proc newRpcRuntime*(agent: ptr Agent, writeEvent: RpcWriter = nil): RpcRuntime =
  result = RpcRuntime(agent: agent, writeEvent: writeEvent, step: -1,
    cancelRead: -1, cancelWrite: -1)
  var fds: array[2, cint]
  if posix.pipe(fds) == 0:
    result.cancelRead = fds[0]
    result.cancelWrite = fds[1]
    discard fcntl(result.cancelRead, F_SETFL, O_NONBLOCK)
  let runtime = result
  var ui = consoleSink()
  ui.emit = proc (level: MsgLevel, text: string) =
    if level == mlError:
      runtime.turnFailed = true
      runtime.hadFailure = true
      if not runtime.sawErrorEvent:
        runtime.send diagnosticEventJson("error", text)
    elif level == mlWarn:
      runtime.send diagnosticEventJson("warning", text)
  ui.agentEvent = proc (event: NimletEvent) =
    if event.kind == neError: runtime.sawErrorEvent = true
    if event.runId.len > 0: runtime.runId = event.runId
    if event.turnId.len > 0: runtime.turnId = event.turnId
    if event.kind == neStepStarted: runtime.step = event.step
    if event.kind == neRunStarted:
      runtime.send messageEventJson(event.sessionId, event.turnId, "user",
        event.prompt)
    runtime.send event.nimletEventJson
  ui.commitGenerate = proc (response: ProviderResponse, final: bool) =
    if final or response.text.len > 0:
      runtime.send messageEventJson(runtime.agent[].session.id, runtime.turnId,
        "assistant", response.text, response.model, final)
  ui.toolStart = proc (call: ContentBlock) = discard
  ui.toolResult = proc (output: string, isError: bool) = discard
  ui.poll = proc () = discard
  ui.wasInterrupted = proc (): bool = runtime.interrupted
  ui.noteInterrupted = proc () = discard
  ui.showSession = proc (session: Session) =
    runtime.send sessionEventJson("session_start", session.id)
  ui.generate = proc (provider: Provider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
    var liveRequest = request
    liveRequest.wakeFd = runtime.cancelRead
    return await streamTextAsync(provider, liveRequest,
      proc (event: StreamEvent): bool =
        case event.kind
        of seTextDelta:
          runtime.send nimletEventJson(NimletEvent(kind: neTextDelta,
            runId: runtime.runId, sessionId: runtime.agent[].session.id,
            turnId: runtime.turnId, step: runtime.step, text: event.text,
            model: request.model))
        of seThinkingDelta:
          runtime.send nimletEventJson(NimletEvent(kind: neThinkingDelta,
            runId: runtime.runId, sessionId: runtime.agent[].session.id,
            turnId: runtime.turnId, step: runtime.step, text: event.text,
            model: request.model))
        else:
          discard
        not runtime.interrupted)
  runtime.ui = ui

proc close*(runtime: RpcRuntime) =
  if runtime.cancelRead >= 0:
    discard posix.close(runtime.cancelRead)
    runtime.cancelRead = -1
  if runtime.cancelWrite >= 0:
    discard posix.close(runtime.cancelWrite)
    runtime.cancelWrite = -1

proc startPrompt(runtime: RpcRuntime, id, prompt: string) =
  runtime.drainCancel()
  runtime.interrupted = false
  runtime.turnFailed = false
  runtime.sawErrorEvent = false
  runtime.activeRequestId = id
  runtime.active = processInputAsync(runtime.agent, prompt, runtime.ui)

proc handleRpcCommand*(runtime: RpcRuntime, command: JsonNode) =
  if command.isNil or command.kind != JObject:
    runtime.send responseJson("", false, error = "Command must be a JSON object.")
    return
  let idNode = command.getOrDefault("id")
  let typeNode = command.getOrDefault("type")
  if idNode.kind != JString or typeNode.kind != JString:
    runtime.send responseJson("", false,
      error = "Command requires string id and type fields.")
    return
  let id = idNode.getStr
  case typeNode.getStr
  of "prompt":
    let message = command.getOrDefault("message")
    if message.kind != JString or message.getStr.strip.len == 0:
      runtime.send responseJson(id, false, error = "prompt requires message.")
    elif runtime.shuttingDown:
      runtime.send responseJson(id, false, error = "RPC is shutting down.")
    elif runtime.active.isNil:
      runtime.send responseJson(id, true, state = "started")
      runtime.startPrompt(id, message.getStr)
    elif runtime.queuedPrompt.len == 0:
      runtime.queuedRequestId = id
      runtime.queuedPrompt = message.getStr
      runtime.send responseJson(id, true, state = "queued")
      runtime.send queueEventJson(runtime.agent[].session.id, "enqueue",
        runtime.queuedPrompt, 1, id)
    else:
      runtime.send responseJson(id, false, error = "Prompt queue is full.")
  of "interrupt":
    if not runtime.active.isNil: runtime.signalCancel()
    runtime.send responseJson(id, true,
      state = if runtime.active.isNil: "idle" else: "interrupting")
  of "get_state":
    var response = responseJson(id, true)
    response["session_id"] = %runtime.agent[].session.id
    response["busy"] = %(not runtime.active.isNil)
    response["queued"] = %(runtime.queuedPrompt.len > 0)
    response["mode"] = %($runtime.agent[].mode)
    runtime.send response
  of "shutdown":
    runtime.shuttingDown = true
    if runtime.queuedPrompt.len > 0:
      runtime.queuedPrompt = ""
      runtime.queuedRequestId = ""
      runtime.send queueEventJson(runtime.agent[].session.id, "clear", "", 0)
    if not runtime.active.isNil: runtime.signalCancel()
    runtime.send responseJson(id, true,
      state = if runtime.active.isNil: "stopped" else: "stopping")
  else:
    runtime.send responseJson(id, false,
      error = "Unknown RPC command: " & typeNode.getStr)

proc handleRpcLine*(runtime: RpcRuntime, line: string) =
  try:
    runtime.handleRpcCommand(parseJson(line))
  except CatchableError as e:
    runtime.send responseJson("", false, error = "Invalid JSON: " & e.msg)

proc pollRpc*(runtime: RpcRuntime): bool =
  if not runtime.active.isNil and runtime.active.finished:
    let active = runtime.active
    runtime.active = nil
    try:
      if not active.read: runtime.shuttingDown = true
    except CatchableError as e:
      runtime.turnFailed = true
      runtime.hadFailure = true
      runtime.send nimletEventJson(NimletEvent(kind: neError,
        sessionId: runtime.agent[].session.id, turnId: runtime.turnId,
        runId: runtime.runId, step: runtime.step, error: e.msg))
    runtime.drainCancel()
    runtime.interrupted = false
    if runtime.queuedPrompt.len > 0 and not runtime.shuttingDown:
      let id = runtime.queuedRequestId
      let prompt = runtime.queuedPrompt
      runtime.queuedRequestId = ""
      runtime.queuedPrompt = ""
      runtime.send queueEventJson(runtime.agent[].session.id, "dequeue", "", 0,
        id)
      runtime.startPrompt(id, prompt)
  not (runtime.shuttingDown and runtime.active.isNil)

proc runRpc*(agent: var Agent) =
  let runtime = newRpcRuntime(addr agent)
  defer:
    rpcSignalWrite = -1
    runtime.close()
  rpcSigint = 0
  rpcSignalWrite = runtime.cancelWrite
  setControlCHook(handleRpcSigint)
  runtime.send sessionEventJson("session_start", agent.session.id)
  var input = ""
  var eof = false
  while runtime.pollRpc():
    if rpcSigint != 0 and not runtime.shuttingDown:
      runtime.shuttingDown = true
      runtime.interrupted = true
      if runtime.queuedPrompt.len > 0:
        runtime.queuedPrompt = ""
        runtime.queuedRequestId = ""
        runtime.send queueEventJson(agent.session.id, "clear", "", 0)
    var ready = TPollfd(fd: STDIN_FILENO, events: POLLIN)
    if posix.poll(ready.addr, Tnfds(1), 0) > 0:
      var bytes: array[4096, char]
      let count = posix.read(STDIN_FILENO, bytes.addr, bytes.len)
      if count > 0:
        for i in 0 ..< count: input.add bytes[i]
      else:
        eof = true
    var newline = input.find('\n')
    while newline >= 0:
      let line = input[0 ..< newline].strip(chars = {'\r'})
      input = input[newline + 1 .. ^1]
      if line.strip.len > 0: runtime.handleRpcLine(line)
      newline = input.find('\n')
    if eof:
      if input.strip.len > 0: runtime.handleRpcLine(input)
      runtime.shuttingDown = true
      if not runtime.active.isNil: runtime.signalCancel()
    if hasPendingOperations(): asyncdispatch.poll(10)
    else: sleep(10)
  waitFor (addr agent).fireSessionHooks(heSessionEnd)
  runtime.send sessionEventJson("session_end", agent.session.id,
    not runtime.hadFailure)
