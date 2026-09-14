## Line-oriented JSON-RPC over a child process.

import std/[asyncdispatch, asyncfile, json, osproc, strtabs, strutils, tables]
when not defined(windows):
  import posix

type
  JsonRpcError* = object of CatchableError
    code*: int
    data*: JsonNode

  JsonRpcMessageProc* = proc (message: JsonNode) {.closure.}

  JsonRpcProcess* = ref object
    process: Process
    input: AsyncFile
    output: AsyncFile
    pending: Table[string, Future[JsonNode]]
    nextId: int
    reader: Future[void]
    includeVersion: bool
    onMessage: JsonRpcMessageProc
    closed: bool
    buffered: string

proc close*(client: JsonRpcProcess)

when not defined(windows):
  proc makeNonBlocking(handle: FileHandle) =
    let flags = fcntl(handle.cint, F_GETFL, 0)
    discard fcntl(handle.cint, F_SETFL, flags or O_NONBLOCK)

proc rpcError(message: string, code = 0,
              data: JsonNode = nil): ref JsonRpcError =
  let error = newException(JsonRpcError, message)
  error.code = code
  error.data = data
  error

proc failPending(client: JsonRpcProcess, error: ref CatchableError) =
  for _, future in client.pending.mpairs:
    if not future.finished:
      future.fail(error)
  client.pending.clear()

proc readLine(client: JsonRpcProcess): Future[string] {.async.} =
  ## asyncfile.readLine raises IndexDefect at EOF before Nim 2.2, so read chunks.
  while '\n' notin client.buffered:
    let chunk = await client.output.read(4096)
    if chunk.len == 0: break # EOF: drain whatever is left in the buffer
    client.buffered.add chunk
  let idx = client.buffered.find('\n')
  if idx < 0:
    result = client.buffered
    client.buffered.setLen(0)
  else:
    result = client.buffered[0 ..< idx]
    client.buffered.delete(0, idx)
  if result.len > 0 and result[^1] == '\r':
    result.setLen(result.len - 1)

proc readMessages(client: JsonRpcProcess) {.async.} =
  var failure: ref CatchableError
  try:
    while not client.closed:
      let line = await client.readLine()
      if line.len == 0:
        failure = rpcError("JSON-RPC process closed stdout")
        break
      let message = parseJson(line)
      if "id" in message and "method" notin message:
        let key = $message["id"]
        if key in client.pending:
          let future = client.pending[key]
          client.pending.del(key)
          if not future.finished:
            future.complete(message)
          continue
      if not client.onMessage.isNil:
        client.onMessage(message)
  except CatchableError as error:
    failure = rpcError("JSON-RPC process reader failed: " & error.msg)
  if not client.closed and not failure.isNil:
    client.failPending(failure)

proc requestAsync*(client: JsonRpcProcess, methodName: string,
                   params: JsonNode = nil): Future[JsonNode] {.async.} =
  if client.isNil or client.closed:
    raise rpcError("JSON-RPC process is closed")
  if methodName.len == 0:
    raise rpcError("JSON-RPC method must not be empty")
  let id = client.nextId
  inc client.nextId
  let key = $id
  let future = newFuture[JsonNode]("jsonRpcRequest")
  client.pending[key] = future
  var request = %*{"id": id, "method": methodName}
  if client.includeVersion:
    request["jsonrpc"] = %"2.0"
  if not params.isNil:
    request["params"] = params
  try:
    await client.input.write($request & "\n")
  except CatchableError as error:
    client.pending.del(key)
    raise rpcError("JSON-RPC process write failed: " & error.msg)
  let message = await future
  if "error" in message:
    let errorNode = message["error"]
    raise rpcError(errorNode.getOrDefault("message").getStr,
      errorNode.getOrDefault("code").getInt, errorNode.getOrDefault("data"))
  if "result" notin message:
    raise rpcError("JSON-RPC response has no result")
  message["result"]

proc respondAsync*(client: JsonRpcProcess, id, responsePayload: JsonNode): Future[void] {.async.} =
  ## Reply to a request initiated by the child process.
  if client.isNil or client.closed:
    raise rpcError("JSON-RPC process is closed")
  var response = newJObject()
  if client.includeVersion:
    response["jsonrpc"] = %"2.0"
  response["id"] = if id.isNil: newJNull() else: id
  response["result"] = if responsePayload.isNil: newJObject() else: responsePayload
  try:
    await client.input.write($response & "\n")
  except CatchableError as error:
    raise rpcError("JSON-RPC process write failed: " & error.msg)

proc notifyAsync*(client: JsonRpcProcess, methodName: string,
                  params: JsonNode = nil): Future[void] {.async.} =
  if client.isNil or client.closed:
    raise rpcError("JSON-RPC process is closed")
  if methodName.len == 0:
    raise rpcError("JSON-RPC method must not be empty")
  var notification = %*{"method": methodName}
  if client.includeVersion:
    notification["jsonrpc"] = %"2.0"
  if not params.isNil:
    notification["params"] = params
  try:
    await client.input.write($notification & "\n")
  except CatchableError as error:
    raise rpcError("JSON-RPC process write failed: " & error.msg)

proc connectJsonRpcProcessAsync*(command: seq[string], workingDir = "",
                                env: StringTableRef = nil,
                                includeVersion = true,
                                onMessage: JsonRpcMessageProc = nil):
                               Future[JsonRpcProcess] {.async.} =
  if command.len == 0 or command[0].len == 0:
    raise rpcError("JSON-RPC process command must not be empty")
  let args = if command.len > 1: command[1 .. ^1] else: @[]
  var options = {poUsePath}
  when defined(windows):
    options.incl {poDaemon, poInteractive}
  let process = startProcess(command[0], workingDir, args, env, options)
  when not defined(windows):
    makeNonBlocking(process.inputHandle)
    makeNonBlocking(process.outputHandle)
  new(result)
  result.process = process
  result.input = newAsyncFile(AsyncFD(process.inputHandle))
  result.output = newAsyncFile(AsyncFD(process.outputHandle))
  result.pending = initTable[string, Future[JsonNode]]()
  result.nextId = 1
  result.includeVersion = includeVersion
  result.onMessage = onMessage
  result.reader = result.readMessages()
  asyncCheck result.reader

proc connectJsonRpcProcess*(command: seq[string], workingDir = "",
                            env: StringTableRef = nil,
                            includeVersion = true,
                            onMessage: JsonRpcMessageProc = nil):
                           JsonRpcProcess =
  waitFor connectJsonRpcProcessAsync(command, workingDir, env, includeVersion,
    onMessage)

proc close*(client: JsonRpcProcess) =
  if client.isNil or client.closed: return
  client.closed = true
  client.failPending(rpcError("JSON-RPC process closed"))
  try:
    client.input.close()
  except CatchableError:
    discard
  try:
    client.output.close()
  except CatchableError:
    discard
  try:
    client.process.close()
  except CatchableError:
    discard
