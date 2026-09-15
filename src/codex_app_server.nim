## Minimal client for the local Codex App Server.

import std/[asyncdispatch, json, strtabs, strutils]
import nimgent
import config, jsonrpc_process
export jsonrpc_process

type
  CodexAppServer* = ref object
    rpc: JsonRpcProcess
    initializeResult*: JsonNode

  CodexApprovalProc* = proc (kind, reason, command, cwd: string):
      Future[string] {.closure.}

  CodexTurn = ref object
    threadId: string
    turnId: string
    model: string
    text: string
    error: string
    cancelled: bool
    callback: StreamCallback
    completion: Future[ProviderResponse]

  CodexProvider* = ref object of Provider
    appServer*: CodexAppServer
    workingDir*: string
    threadId*: string
    models*: seq[string]
    defaultModel*: string
    approval*: CodexApprovalProc
    activeTurn: CodexTurn

proc requestAsync*(server: CodexAppServer, methodName: string,
                   params: JsonNode = nil): Future[JsonNode] {.async.} =
  if server.isNil:
    raise newException(ValueError, "Codex App Server is nil")
  return await server.rpc.requestAsync(methodName, params)

proc notifyAsync*(server: CodexAppServer, methodName: string,
                  params: JsonNode = nil): Future[void] {.async.} =
  if server.isNil:
    raise newException(ValueError, "Codex App Server is nil")
  await server.rpc.notifyAsync(methodName, params)

proc respondAsync*(server: CodexAppServer, id, response: JsonNode): Future[void] {.async.} =
  if server.isNil:
    raise newException(ValueError, "Codex App Server is nil")
  await server.rpc.respondAsync(id, response)

proc accountReadAsync*(server: CodexAppServer,
                       refreshToken = false): Future[JsonNode] {.async.} =
  return await server.requestAsync("account/read", %*{
    "refreshToken": refreshToken
  })

proc loginStartAsync*(server: CodexAppServer, loginType: string,
                      apiKey = "", hostedSuccessPage = true):
                     Future[JsonNode] {.async.} =
  if loginType notin ["chatgpt", "chatgptDeviceCode", "apiKey"]:
    raise newException(ValueError, "unsupported Codex login type: " & loginType)
  var params = %*{"type": loginType}
  if loginType == "apiKey":
    if apiKey.len == 0:
      raise newException(ValueError, "Codex API-key login requires a key")
    params["apiKey"] = %apiKey
  elif loginType == "chatgpt":
    params["useHostedLoginSuccessPage"] = %hostedSuccessPage
    params["appBrand"] = %"chatgpt"
  return await server.requestAsync("account/login/start", params)

proc loginCancelAsync*(server: CodexAppServer,
                       loginId: string): Future[JsonNode] {.async.} =
  return await server.requestAsync("account/login/cancel", %*{
    "loginId": loginId
  })

proc logoutAsync*(server: CodexAppServer): Future[JsonNode] {.async.} =
  return await server.requestAsync("account/logout")

proc modelListAsync*(server: CodexAppServer, limit = 20,
                     includeHidden = false): Future[JsonNode] {.async.} =
  return await server.requestAsync("model/list", %*{
    "limit": limit,
    "includeHidden": includeHidden
  })

proc threadStartAsync*(server: CodexAppServer, model, cwd: string):
    Future[JsonNode] {.async.} =
  var params = newJObject()
  if model.len > 0: params["model"] = %model
  if cwd.len > 0: params["cwd"] = %cwd
  return await server.requestAsync("thread/start", params)

proc turnStartAsync*(server: CodexAppServer, threadId, input, model, cwd: string):
    Future[JsonNode] {.async.} =
  var params = %*{
    "threadId": threadId,
    "input": [{"type": "text", "text": input}]
  }
  if model.len > 0: params["model"] = %model
  if cwd.len > 0: params["cwd"] = %cwd
  return await server.requestAsync("turn/start", params)

proc turnInterruptAsync*(server: CodexAppServer, threadId, turnId: string):
    Future[JsonNode] {.async.} =
  return await server.requestAsync("turn/interrupt", %*{
    "threadId": threadId,
    "turnId": turnId
  })

proc modelIds*(response: JsonNode): seq[string] =
  let data = response.getOrDefault("data")
  if data.isNil or data.kind != JArray: return
  for item in data:
    if item.isNil or item.kind != JObject: continue
    if item.getOrDefault("hidden").getBool: continue
    let id = item.getOrDefault("id").getStr
    let model = if id.len > 0: id else: item.getOrDefault("model").getStr
    if model.len > 0 and model notin result:
      result.add model

proc defaultModelId(response: JsonNode): string =
  let data = response.getOrDefault("data")
  if data.isNil or data.kind != JArray: return
  for item in data:
    if item.kind == JObject and item.getOrDefault("isDefault").getBool:
      result = item.getOrDefault("id").getStr
      if result.len == 0: result = item.getOrDefault("model").getStr
      return

proc modelIdsAsync*(server: CodexAppServer, limit = 20): Future[seq[string]] {.async.} =
  let response = await server.modelListAsync(limit)
  return response.modelIds

proc notifyDelta(turn: CodexTurn, event: StreamEvent): bool =
  if turn.callback.isNil: return true
  turn.callback(event)

proc completeTurn(turn: CodexTurn, response: ProviderResponse) =
  if not turn.completion.finished:
    turn.completion.complete(response)

proc failTurn(turn: CodexTurn, error: ref CatchableError) =
  if not turn.completion.finished:
    turn.completion.fail(error)

proc codexMessageHandler(provider: CodexProvider, message: JsonNode)
proc interruptActiveTurn(provider: CodexProvider) {.async.}

proc handleCodexRequest(provider: CodexProvider, message: JsonNode) {.async.} =
  let methodName = message.getOrDefault("method").getStr
  let params = message.getOrDefault("params")
  var response = newJObject()
  if methodName in ["item/commandExecution/requestApproval",
                    "item/fileChange/requestApproval"]:
    let kind = if methodName.startsWith("item/fileChange"):
      "file_change" else: "command"
    let command = params.getOrDefault("command").getStr
    let cwd = params.getOrDefault("cwd").getStr
    let reason = params.getOrDefault("reason").getStr
    let decision = if provider.approval.isNil:
      "accept"
    else:
      await provider.approval(kind, reason, command, cwd)
    response["decision"] = %(if decision.len > 0: decision else: "decline")
  elif methodName == "item/permissions/requestApproval":
    response["permissions"] = newJObject()
  elif methodName == "item/tool/requestUserInput":
    response["answers"] = newJObject()
  await provider.appServer.respondAsync(message.getOrDefault("id"), response)

proc codexMessageHandler(provider: CodexProvider, message: JsonNode) =
  if message.isNil or message.kind != JObject: return
  let methodName = message.getOrDefault("method").getStr
  if "id" in message and methodName.len > 0:
    asyncCheck provider.handleCodexRequest(message)
    return
  let turn = provider.activeTurn
  if turn.isNil: return
  let params = message.getOrDefault("params")
  case methodName
  of "item/agentMessage/delta":
    let delta = params.getOrDefault("delta").getStr
    if delta.len == 0: return
    turn.text.add delta
    if not turn.notifyDelta(StreamEvent(kind: seTextDelta, text: delta)):
      if not turn.cancelled:
        turn.cancelled = true
        asyncCheck provider.interruptActiveTurn()
  of "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
    let delta = params.getOrDefault("delta").getStr
    if delta.len > 0 and not turn.notifyDelta(
        StreamEvent(kind: seThinkingDelta, text: delta)):
      if not turn.cancelled:
        turn.cancelled = true
        asyncCheck provider.interruptActiveTurn()
  of "error":
    let error = params.getOrDefault("error")
    turn.error = if error.kind == JObject: error.getOrDefault("message").getStr
                 else: error.getStr
  of "turn/completed":
    let turnNode = params.getOrDefault("turn")
    let status = if turnNode.kind == JObject:
      turnNode.getOrDefault("status").getStr
    else:
      params.getOrDefault("status").getStr
    if turn.cancelled:
      turn.failTurn(newException(CancelledError, "Interrupted"))
    elif status notin ["completed", "succeeded", "" ]:
      let message = if turn.error.len > 0: turn.error
                    else: "Codex turn " & status
      turn.failTurn(newException(ProviderError, message))
    else:
      turn.completeTurn(ProviderResponse(
        model: turn.model,
        content: if turn.text.len > 0: @[text(turn.text)] else: @[],
        finishReason: frStop))
  else:
    discard

proc interruptActiveTurn(provider: CodexProvider) {.async.} =
  let turn = provider.activeTurn
  if turn.isNil or turn.turnId.len == 0: return
  try:
    discard await provider.appServer.turnInterruptAsync(turn.threadId, turn.turnId)
  except CatchableError:
    discard
  turn.failTurn(newException(CancelledError, "Interrupted"))

proc latestUserText(request: ProviderRequest): string =
  for i in countdown(request.messages.high, 0):
    if request.messages[i].role != roleUser: continue
    for part in request.messages[i].content:
      if part.kind == ckText:
        if result.len > 0: result.add "\n"
        result.add part.text
    if result.len > 0: return

proc ensureThread(provider: CodexProvider, model: string): Future[string] {.async.} =
  if provider.threadId.len > 0: return provider.threadId
  let response = await provider.appServer.threadStartAsync(model, provider.workingDir)
  result = response.getOrDefault("thread").getOrDefault("id").getStr
  if result.len == 0:
    raise newException(ProviderError, "Codex thread/start returned no thread id")
  provider.threadId = result

method generateAsync*(provider: CodexProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  return await provider.generateStreamAsync(request, nil)

method generateStreamAsync*(provider: CodexProvider, request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  if not provider.activeTurn.isNil:
    raise newException(ProviderError, "Codex provider already has an active turn")
  let input = request.latestUserText
  if input.len == 0:
    raise newException(ProviderError, "Codex turn requires a user message")
  let threadId = await provider.ensureThread(request.model)
  let turn = CodexTurn(threadId: threadId, model: request.model,
    callback: onEvent, completion: newFuture[ProviderResponse]("codexTurn"))
  provider.activeTurn = turn
  try:
    let response = await provider.appServer.turnStartAsync(threadId, input,
      request.model, provider.workingDir)
    turn.turnId = response.getOrDefault("turn").getOrDefault("id").getStr
    if turn.turnId.len == 0:
      raise newException(ProviderError, "Codex turn/start returned no turn id")
    return await turn.completion
  finally:
    provider.activeTurn = nil

proc refreshModelsAsync*(provider: CodexProvider): Future[seq[string]] {.async.} =
  let response = await provider.appServer.modelListAsync()
  provider.models = response.modelIds
  provider.defaultModel = response.defaultModelId
  return provider.models

proc connectCodexAppServerAsync*(command: seq[string] = @[
    "codex", "app-server"], workingDir = "",
    env: StringTableRef = nil,
    onMessage: JsonRpcMessageProc = nil): Future[CodexAppServer] {.async.} =
  let rpc = await connectJsonRpcProcessAsync(command, workingDir, env,
    includeVersion = false, onMessage = onMessage)
  try:
    let initialized = await rpc.requestAsync("initialize", %*{
      "clientInfo": {
        "name": "nimlet",
        "title": "Nimlet",
        "version": nimletVersion
      }
    })
    await rpc.notifyAsync("initialized")
    return CodexAppServer(rpc: rpc, initializeResult: initialized)
  except CatchableError:
    rpc.close()
    raise

proc connectCodexAppServer*(command: seq[string] = @[
    "codex", "app-server"], workingDir = "",
    env: StringTableRef = nil,
    onMessage: JsonRpcMessageProc = nil): CodexAppServer =
  waitFor connectCodexAppServerAsync(command, workingDir, env, onMessage)

proc close*(server: CodexAppServer) =
  if not server.isNil:
    server.rpc.close()

proc newCodexProviderAsync*(workingDir = "", command: seq[string] = @[
    "codex", "app-server"]): Future[CodexProvider] {.async.} =
  new(result)
  result.name = "codex"
  result.workingDir = workingDir
  let provider = result
  result.appServer = await connectCodexAppServerAsync(command, workingDir,
    onMessage = proc (message: JsonNode) = provider.codexMessageHandler(message))
  try:
    discard await result.refreshModelsAsync()
  except CatchableError:
    discard

proc newCodexProvider*(workingDir = "", command: seq[string] = @[
    "codex", "app-server"]): CodexProvider =
  waitFor newCodexProviderAsync(workingDir, command)

proc close*(provider: CodexProvider) =
  if not provider.isNil and not provider.appServer.isNil:
    provider.appServer.close()
