## Persistent, language-neutral extensions over JSONL stdin/stdout.

import std/[asyncdispatch, atomics, json, os, osproc, streams, strutils,
  tables, times]
when defined(windows):
  import std/winlean
else:
  import posix
import config
import extensions
import trust
import nimgent
import tools/tool
import hooks

type
  ExtensionQuestionProc* = proc(prompt: string,
    options: seq[string]): Future[string] {.closure.}

  ExtensionCommand* = object
    name*: string
    description*: string
    extension*: int

  RegisteredTool* = object
    definition*: ToolDefinition
    extension*: int
    capabilities*: ToolCapabilities

  StatusEntry* = object
    key*: string
    text*: string

  ExtensionWidget* = object
    key*: string
    lines*: seq[string]
    placement*: string

  ExtensionNotice* = object
    level*: string
    message*: string

  ExtensionEntry* = object
    extension*: string
    data*: JsonNode

  IncomingMessage = tuple[extension: int, line: string]

  UpdateSignalProc* = proc(context: pointer) {.nimcall, gcsafe, raises: [].}

  UpdateSignal = object
    callback: Atomic[pointer]
    context: Atomic[pointer]

  ReaderArgs = object
    outputHandle: FileHandle
    extension: int
    inbox: ptr Channel[IncomingMessage]
    signal: ptr UpdateSignal

  ExtensionProcess = ref object
    name: string
    process: Process
    timeoutMs: int
    events: seq[string]
    reader: Thread[ReaderArgs]

  ExtensionRuntime* = ref object
    processes: seq[ExtensionProcess]
    commands*: seq[ExtensionCommand]
    tools*: seq[RegisteredTool]
    warnings*: seq[string]
    statuses*: seq[StatusEntry]
    widgets*: seq[ExtensionWidget]
    notices: seq[ExtensionNotice]
    entries: seq[ExtensionEntry]
    question*: ExtensionQuestionProc
    signal: UpdateSignal
    nextId: int
    inbox: ptr Channel[IncomingMessage]
    responses: Table[string, JsonNode]
    questions: seq[Future[void]]
    questionCompletedAt: float

proc commandSpec(path: string): tuple[ok: bool, name: string,
    command: seq[string], timeoutMs: int, err: string] =
  try:
    let doc = parseJson(readFile(path))
    if doc.kind != JObject: return (false, "", @[], 0, "manifest must be an object")
    let name = doc.getOrDefault("name").getStr.strip
    if name.len == 0: return (false, "", @[], 0, "missing name")
    if doc.getOrDefault("command").kind != JArray:
      return (false, "", @[], 0, "command must be an array")
    var command: seq[string]
    for item in doc["command"]:
      if item.kind != JString or item.getStr.len == 0:
        return (false, "", @[], 0, "command entries must be strings")
      command.add item.getStr
    if command.len == 0: return (false, "", @[], 0, "command must not be empty")
    var timeoutMs = 30_000
    if "response_timeout_seconds" in doc:
      let timeout = doc["response_timeout_seconds"]
      if timeout.kind == JNull:
        timeoutMs = -1
      elif timeout.kind == JInt and timeout.getInt > 0:
        timeoutMs = timeout.getInt * 1000
      else:
        return (false, "", @[], 0,
          "response_timeout_seconds must be a positive integer or null")
    (true, name, command, timeoutMs, "")
  except CatchableError as e:
    (false, "", @[], 0, e.msg)

proc extensionDirs(workspace: string): seq[string] =
  let root = if dirExists(workspace): expandFilename(workspace) else: workspace
  var bases = @[getHomeDir() / ".agents" / "extensions",
                nimletConfigDir() / "extensions"]
  if projectResourcesTrusted(root):
    bases.add root / ".agents" / "extensions"
    bases.add root / ".nimlet" / "extensions"
  for base in bases:
    if not dirExists(base): continue
    for kind, path in walkDir(base):
      if kind == pcDir and fileExists(path / "extension.json"): result.add path

proc send(process: Process, message: JsonNode) =
  process.inputStream.writeLine($message)
  process.inputStream.flush()

proc setStatus(runtime: ExtensionRuntime, key, text: string) =
  for i, status in runtime.statuses:
    if status.key == key:
      if text.len == 0: runtime.statuses.delete(i)
      else: runtime.statuses[i].text = text
      return
  if text.len > 0: runtime.statuses.add StatusEntry(key: key, text: text)

proc setWidget(runtime: ExtensionRuntime, widget: ExtensionWidget) =
  for i, current in runtime.widgets:
    if current.key == widget.key:
      if widget.lines.len == 0: runtime.widgets.delete(i)
      else: runtime.widgets[i] = widget
      return
  if widget.lines.len > 0: runtime.widgets.add widget

proc stringField(node: JsonNode, key: string): string =
  let value = node.getOrDefault(key)
  if not value.isNil and value.kind == JString: value.getStr else: ""

proc stringArray(node: JsonNode, key: string): seq[string] =
  let values = node.getOrDefault(key)
  if values.isNil or values.kind != JArray: return
  for value in values:
    if value.kind == JString: result.add value.getStr

proc captureActions(runtime: ExtensionRuntime, extension: int,
                    response: JsonNode) =
  let namespace = runtime.processes[extension].name
  let status = response.getOrDefault("status")
  if not status.isNil and status.kind == JObject:
    let key = status.stringField("key")
    if key.len > 0:
      runtime.setStatus(namespace & ":" & key,
        status.stringField("text"))
  let widget = response.getOrDefault("widget")
  if not widget.isNil and widget.kind == JObject:
    let key = widget.stringField("key")
    if key.len > 0:
      runtime.setWidget ExtensionWidget(key: namespace & ":" & key,
        lines: widget.stringArray("lines"),
        placement: widget.stringField("placement"))
  let notice = response.getOrDefault("notification")
  if not notice.isNil and notice.kind == JObject:
    let message = notice.stringField("message")
    if message.len > 0:
      runtime.notices.add ExtensionNotice(
        level: notice.stringField("level"), message: message)
  let entry = response.getOrDefault("entry")
  if not entry.isNil:
    runtime.entries.add ExtensionEntry(extension: namespace, data: entry)

proc readHandleLine(handle: FileHandle): string {.gcsafe.}

proc receive(process: Process, timeoutMs = 30_000): JsonNode =
  when defined(windows):
    ## Windows has no poll(2). PeekNamedPipe lets us wait for a complete JSONL
    ## record without turning a child response timeout into a blocked read.
    let deadline = epochTime() + timeoutMs.float / 1000.0
    let handle = Handle(process.outputHandle)
    while true:
      var available: int32
      var readCount: int32
      var probe: array[4096, char]
      if peekNamedPipe(handle, addr probe[0], probe.len.int32,
                       addr readCount, addr available, nil) and readCount > 0:
        var hasNewline = false
        for i in 0 ..< int(readCount):
          if probe[i] == '\n':
            hasNewline = true
            break
        if hasNewline:
          return parseJson(readHandleLine(process.outputHandle))
      if timeoutMs >= 0 and epochTime() >= deadline:
        raise newException(IOError, "extension response timed out")
      if process.peekExitCode() != -1:
        raise newException(IOError, "extension exited before responding")
      sleep(50)
  else:
    var descriptor = TPollfd(fd: process.outputHandle.cint, events: POLLIN)
    if poll(descriptor.addr, 1, timeoutMs.cint) <= 0:
      raise newException(IOError, "extension response timed out")
    parseJson(readHandleLine(process.outputHandle))

proc extensionLaunch(command: seq[string], dir: string):
    tuple[executable: string, args: seq[string]] =
  result.executable = if command[0].isAbsolute or '/' notin command[0]:
    command[0]
  else:
    dir / command[0]
  result.args = if command.len > 1: command[1 .. ^1] else: @[]
  when defined(windows):
    ## Windows does not execute a POSIX shebang when a script is passed to
    ## CreateProcess.  Keep manifests portable by selecting an interpreter
    ## for the common script extensions while leaving native executables
    ## unchanged.
    let suffix = result.executable.toLowerAscii
    if suffix.endsWith(".sh"):
      var interpreter = defaultShell()
      if interpreter.kind notin {shellBash, shellPosix}:
        let bash = findExe("bash")
        if bash.len > 0:
          interpreter = ShellSpec(kind: shellBash, executable: bash)
      if interpreter.kind in {shellBash, shellPosix}:
        let script = interpreter.commandInvocation(result.executable, result.args)
        return (interpreter.executable, interpreter.commandLine(script))
    elif suffix.endsWith(".ps1"):
      var interpreter = defaultShell()
      if interpreter.kind != shellPowerShell:
        let pwsh = findExe("pwsh")
        if pwsh.len > 0:
          interpreter = ShellSpec(kind: shellPowerShell, executable: pwsh)
      if interpreter.kind == shellPowerShell:
        return (interpreter.executable,
          @["-NoLogo", "-NoProfile", "-NonInteractive", "-File",
            result.executable] & result.args)
    elif suffix.endsWith(".cmd") or suffix.endsWith(".bat"):
      let cmd = findExe("cmd.exe")
      if cmd.len > 0:
        let interpreter = ShellSpec(kind: shellCmd, executable: cmd)
        let script = interpreter.commandInvocation(result.executable, result.args)
        return (interpreter.executable, @["/d", "/s", "/c", script])

proc readHandleLine(handle: FileHandle): string {.gcsafe.} =
  var ch: char
  while true:
    when defined(windows):
      var count: int32
      if winlean.readFile(Handle(handle), addr ch, 1, addr count, nil) == 0 or
          count == 0: return
    else:
      if posix.read(handle.cint, addr ch, 1) != 1: return
    if ch == '\n': return
    if ch != '\r': result.add ch

proc readMessages(args: ReaderArgs) {.thread.} =
  while true:
    let line = readHandleLine(args.outputHandle)
    if line.len == 0: break
    args.inbox[].send((args.extension, line))
    let callback = cast[UpdateSignalProc](args.signal.callback.load())
    if not callback.isNil: callback(args.signal.context.load())

proc startExtensions*(workspace, sessionId: string): ExtensionRuntime =
  new(result)
  result.inbox = cast[ptr Channel[IncomingMessage]](
    allocShared0(sizeof(Channel[IncomingMessage])))
  result.inbox[].open()
  for dir in extensionDirs(workspace):
    let spec = commandSpec(dir / "extension.json")
    if not spec.ok:
      result.warnings.add "skipping " & dir & ": " & spec.err
      continue
    let launch = extensionLaunch(spec.command, dir)
    var process: Process
    try:
      process = startProcess(launch.executable, workingDir = workspace,
        args = launch.args,
        options = {poUsePath})
      process.send(%*{"type": "initialize", "version": 1,
        "workspace": workspace, "session_id": sessionId})
      let registration = process.receive(spec.timeoutMs)
      if registration.getOrDefault("type").getStr != "register":
        raise newException(ValueError, "expected register response")
      if registration.getOrDefault("commands").kind != JArray:
        raise newException(ValueError, "register commands must be an array")
      let registeredEvents = registration.getOrDefault("events")
      if not registeredEvents.isNil and registeredEvents.kind != JArray:
        raise newException(ValueError, "register events must be an array")
      var events: seq[string]
      if not registeredEvents.isNil:
        for event in registeredEvents:
          if event.kind != JString:
            raise newException(ValueError, "register events must be strings")
          events.add event.getStr
      let processIndex = result.processes.len
      result.processes.add ExtensionProcess(name: spec.name, process: process,
        timeoutMs: spec.timeoutMs, events: events)
      for command in registration.getOrDefault("commands"):
        let name = command.getOrDefault("name").getStr.strip
        if name.len > 0:
          result.commands.add ExtensionCommand(name: name,
            description: command.getOrDefault("description").getStr,
            extension: processIndex)
      let tools = registration.getOrDefault("tools")
      if not tools.isNil and tools.kind notin {JNull, JArray}:
        raise newException(ValueError, "register tools must be an array")
      if not tools.isNil and tools.kind == JArray:
        for tool in tools:
          let name = tool.getOrDefault("name").getStr.strip
          let description = tool.getOrDefault("description").getStr
          let schema = tool.getOrDefault("input_schema")
          if name.len == 0 or description.len == 0 or schema.kind != JObject:
            raise newException(ValueError,
              "registered tools require name, description, and input_schema")
          let capabilities = parseCapabilities(tool.getOrDefault("capabilities"))
          if not capabilities.ok:
            raise newException(ValueError,
              "invalid capabilities for tool '" & name & "': " & capabilities.err)
          result.tools.add RegisteredTool(definition: ToolDefinition(name: name,
            description: description, inputSchema: schema), extension: processIndex,
            capabilities: capabilities.capabilities)
      createThread(result.processes[processIndex].reader, readMessages,
        ReaderArgs(outputHandle: process.outputHandle,
          extension: processIndex, inbox: result.inbox,
          signal: addr result.signal))
    except CatchableError as e:
      if not process.isNil:
        if process.running: process.terminate()
        process.close()
      result.warnings.add "extension '" & spec.name & "' failed to start: " & e.msg

proc stop*(runtime: ExtensionRuntime) =
  if runtime.isNil: return
  for extension in runtime.processes:
    try: extension.process.send(%*{"type": "shutdown"})
    except CatchableError: discard
    if extension.process.running:
      extension.process.terminate()
      discard extension.process.waitForExit(100)
    joinThread(extension.reader)
    extension.process.close()
  runtime.processes.setLen(0)
  runtime.commands.setLen(0)
  runtime.tools.setLen(0)
  if not runtime.inbox.isNil:
    runtime.inbox[].close()
    deallocShared(runtime.inbox)
    runtime.inbox = nil

proc answerQuestion(runtime: ExtensionRuntime, extension: int,
                    request: JsonNode): Future[void] {.async.} =
  let options = request.stringArray("options")
  let answer = if runtime.question.isNil: ""
    else: await runtime.question(request.getOrDefault("prompt").getStr, options)
  runtime.processes[extension].process.send(%*{"type": "ui_response",
    "id": request.getOrDefault("id").getStr, "answer": answer,
    "cancelled": answer.len == 0})
  runtime.questionCompletedAt = epochTime()

proc setOnUpdate*(runtime: ExtensionRuntime,
                  callback: UpdateSignalProc, context: pointer = nil) =
  if runtime.isNil: return
  runtime.signal.context.store(context)
  runtime.signal.callback.store(cast[pointer](callback))

proc pump*(runtime: ExtensionRuntime) =
  if runtime.isNil: return
  while true:
    let incoming = runtime.inbox[].tryRecv()
    if not incoming.dataAvailable: break
    let message = try: parseJson(incoming.msg.line)
      except CatchableError: continue
    let kind = message.stringField("type")
    if kind == "response":
      runtime.responses[message.stringField("id")] = message
    elif kind == "ui_request" and
        message.stringField("method") == "question":
      runtime.questions.add runtime.answerQuestion(incoming.msg.extension,
        message)
    else:
      runtime.captureActions(incoming.msg.extension, message)
  for i in countdown(runtime.questions.high, 0):
    if runtime.questions[i].finished:
      runtime.questions.delete(i)

proc requestAsync(runtime: ExtensionRuntime, extension: int,
                  message: JsonNode): Future[JsonNode] {.async.} =
  let ext = runtime.processes[extension]
  let id = message.stringField("id")
  ext.process.send(message)
  let started = epochTime()
  while true:
    runtime.pump()
    if id in runtime.responses:
      result = runtime.responses[id]
      runtime.responses.del(id)
      runtime.captureActions(extension, result)
      return
    if cancelRequested():
      ext.process.send(%*{"type": "cancel", "id": message["id"]})
      raise newException(IOError, "extension request cancelled")
    if runtime.questions.len == 0 and ext.timeoutMs >= 0 and
        int((epochTime() - max(started, runtime.questionCompletedAt)) * 1000) >=
          ext.timeoutMs:
      raise newException(IOError, "extension response timed out")
    await sleepAsync(50)

proc invoke*(runtime: ExtensionRuntime, name,
             arguments: string): Future[JsonNode] {.async.} =
  for command in runtime.commands:
    if command.name.toLowerAscii != name.toLowerAscii: continue
    inc runtime.nextId
    let id = $runtime.nextId
    result = await runtime.requestAsync(command.extension,
      %*{"type": "command", "id": id, "name": command.name,
        "arguments": arguments})
    return
  raise newException(ValueError, "unknown extension command: " & name)

proc registerTools*(runtime: ExtensionRuntime, registry: var ToolRegistry,
                    plan: ptr ToolRegistry = nil) =
  if runtime.isNil: return
  for tool in runtime.tools:
    if isBuiltinName(tool.definition.name):
      runtime.warnings.add "extension tool '" & tool.definition.name &
        "' collides with a built-in tool"
      continue
    let registered = tool
    proc run(input: JsonNode): Future[ToolResult] {.async.} =
      inc runtime.nextId
      let id = $runtime.nextId
      let response = await runtime.requestAsync(registered.extension,
        %*{"type": "tool", "id": id, "name": registered.definition.name,
          "arguments": input})
      return ToolResult(output: response.getOrDefault("content").getStr,
        isError: response.getOrDefault("is_error").getBool)
    registry.register(registered.definition, run, registered.capabilities)
    if not plan.isNil and registered.capabilities.planSafe:
      plan[].register(registered.definition, run, registered.capabilities)

proc takeNotices*(runtime: ExtensionRuntime): seq[ExtensionNotice] =
  if runtime.isNil: return
  result = runtime.notices
  runtime.notices.setLen(0)

proc takeEntries*(runtime: ExtensionRuntime): seq[ExtensionEntry] =
  if runtime.isNil: return
  result = runtime.entries
  runtime.entries.setLen(0)

proc statusTexts*(runtime: ExtensionRuntime): seq[string] =
  if runtime.isNil: return
  for status in runtime.statuses: result.add status.text

proc widgetLines*(runtime: ExtensionRuntime): seq[string] =
  if runtime.isNil: return
  for widget in runtime.widgets: result.add widget.lines

proc dispatch*(runtime: ExtensionRuntime, event: HookEvent,
               payload: JsonNode): Future[HookOutcome] {.async.} =
  result.allowed = true
  if runtime.isNil: return
  var payload = if payload.isNil: newJObject() else: copy(payload)
  for i, extension in runtime.processes:
    if $event notin extension.events: continue
    inc runtime.nextId
    let id = $runtime.nextId
    var response: JsonNode
    try:
      response = await runtime.requestAsync(i,
        %*{"type": "event", "id": id, "event": $event, "payload": payload})
    except CatchableError as e:
      result.warnings.add "extension '" & extension.name & "': " & e.msg
      continue
    let allow = response.getOrDefault("allow")
    if not allow.isNil and allow.kind == JBool and not allow.getBool:
      result.allowed = false
      let reason = response.getOrDefault("reason").getStr
      result.reason.add(if result.reason.len == 0: reason else: "; " & reason)
      continue
    case event
    of hePreToolCall:
      let arguments = response.getOrDefault("arguments")
      if not arguments.isNil and arguments.kind == JObject:
        result.arguments = arguments
        payload["arguments"] = arguments
    of hePostToolCall:
      let output = response.getOrDefault("output")
      if not output.isNil and output.kind == JString:
        result.output = output.getStr
        result.hasOutput = true
        payload["output"] = output
      let isError = response.getOrDefault("is_error")
      if not isError.isNil and isError.kind == JBool:
        result.isError = isError.getBool
        result.hasIsError = true
        payload["is_error"] = isError
    of hePreCompact:
      let instruction = response.getOrDefault("instruction")
      if not instruction.isNil and instruction.kind == JString:
        result.instruction = instruction.getStr
      let compaction = response.getOrDefault("compaction")
      if not compaction.isNil and compaction.kind == JObject:
        let summary = compaction.getOrDefault("summary")
        let firstKept = compaction.getOrDefault("first_kept_index")
        if not summary.isNil and summary.kind == JString and
            not firstKept.isNil and firstKept.kind == JInt:
          result.summary = summary.getStr
          result.firstKeptIndex = firstKept.getInt
          result.details = compaction.getOrDefault("details")
          result.hasCompaction = result.summary.len > 0
    else:
      discard
  if not result.allowed and result.reason.len == 0:
    result.reason = "blocked by extension"
