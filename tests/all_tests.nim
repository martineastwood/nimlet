import std/[asyncdispatch, json, os, sequtils, strutils, times, unittest]
when defined(posix):
  import posix
import ../src/workspace
import ../src/images
import ../src/session
import ../src/config
import ../src/trust
import ../src/agent
import ../src/events
import nimterm/markdown
import nimterm/app as termapp
import nimterm/[backend, canvas, geometry]
import ../src/ui/diff
import ../src/ui/turn
import ../src/ui/nimterm_adapter
import ../src/ui/nimterm_preview
import ../src/ui/nimterm_screen
import ../src/ui/tool_summary
import nimterm/ansi
import nimterm/input
import nimterm/keys
import nimterm/style
import nimterm/theme
import nimterm/events
import nimterm/widgets/question
import nimterm/widgets/input
import nimterm/widgets/transcript
import nimterm/widget
import ../src/models_dev
import ../src/compaction
import ../src/permissions
import ../src/instructions
import ../src/skills
import ../src/commands
import nimgent
import nimgent/providers/[anthropic, openrouter]
import ../src/tools/[tool, read_tool, edit_tool, write_tool, bash_tool, search_tool]
import ../src/extensions
import ../src/extension_runtime
import ../src/hooks
import ../src/main
import ../src/rpc
import ../src/codex_app_server
import ../src/editor
import ../src/keybindings
import ../src/shell

proc freshDir(): string

type DecoderBackend = ref object of TerminalBackend
  decoder: InputDecoder
  chunks: seq[string]
  dimensions: Size
  frame: Canvas
  resized: bool
  nowMs: int64

method size(backend: DecoderBackend): Size = backend.dimensions

method readEvent(backend: DecoderBackend, timeoutMs: int): UiEvent =
  discard timeoutMs
  if backend.resized:
    backend.resized = false
    return UiEvent(kind: uiResize, width: backend.dimensions.w,
      height: backend.dimensions.h)
  var input = backend.decoder.nextEvent(backend.nowMs)
  if input.key == keyNone and input.mouse == mouseNone and
      input.scrollDelta == 0 and input.focus == focusNone and
      backend.chunks.len > 0:
    backend.decoder.feed(backend.chunks[0])
    backend.chunks.delete(0)
    input = backend.decoder.nextEvent(backend.nowMs)
  inc backend.nowMs
  input.toUiEvent(backend.dimensions.w, backend.dimensions.h)

method present(backend: DecoderBackend, frame: Canvas) = backend.frame = frame

proc feed(backend: DecoderBackend, chunks: varargs[string]) =
  for chunk in chunks: backend.chunks.add chunk

suite "nimterm event source":
  test "idle polling tolerates an empty async dispatcher":
    pumpAsyncDispatcher()

  test "failed turns become UI errors instead of escaping":
    let future = newFuture[bool]("failedTurn")
    future.fail(newException(ValueError, "turn exploded"))
    let events = termapp.poll(newNimletTurnSource(future))
    check events.len == 1
    check events[0].kind == uiError
    check events[0].sourceId == "agent-turn"
    check events[0].error == "turn exploded"

  test "controller recovers from failure and accepts another submission":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(nil, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    let failed = newFuture[bool]("failedControllerTurn")
    failed.fail(newException(ValueError, "turn exploded"))
    controller.supervise(failed)
    check app.step()
    check not controller.busy
    check controller.errorCount == 1
    controller.handleAction(app, UiAction(sourceId: "screen", kind: "submit",
      value: "/plan"))
    for _ in 0 .. 3: discard app.step()
    check not controller.busy
    check agent.mode == modePlan

suite "nimterm agent events":
  test "adapts nimlet events without exposing them to nimterm":
    let event = NimletEvent(kind: neToolResult, runId: "run-1",
      toolId: "call-1", toolOutput: "ok")
    let uiEvent = event.toAgentUiEvent
    check uiEvent.kind == ueToolResult
    check uiEvent.toolId == event.toolId
    check uiEvent.toolOutput == event.toolOutput

  test "ask_user returns the interactive answer to the model":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    var ui = consoleSink()
    ui.question = proc (prompt: string,
                        options: seq[QuestionOption]): Future[QuestionAnswer] {.async.} =
      check prompt == "Choose a mode"
      check options.len == 2
      return QuestionAnswer(selected: 1, text: "Act")
    var calls = 0
    ui.generate = proc (provider: Provider,
                        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      inc calls
      if calls == 1:
        return ProviderResponse(content: @[toolUse("question-1", "ask_user",
          %*{"question": "Choose a mode", "options": ["Plan", "Act"]})],
          finishReason: frToolUse)
      return ProviderResponse(content: @[text("done")], finishReason: frEndTurn)
    check agent.processInput("start", ui)
    check calls == 2
    check agent.session.events[^2].toolOutput == "Act"

proc freshDir(): string =
  result = getTempDir() / ("nimlet-test-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1_000_000))
  createDir(result)

suite "Codex App Server transport":
  when not defined(windows):
    test "speaks JSON-RPC over a child process and completes initialize":
      let server = connectCodexAppServer(@[
        "sh", "-c",
        "read line; printf '%s\\n' '{\"id\":1,\"result\":{\"server\":\"fixture\"}}'; read line; read line; printf '%s\\n' '{\"id\":2,\"result\":{\"account\":\"fixture\"}}'"])
      defer: server.close()
      check server.initializeResult["server"].getStr == "fixture"

      let result = waitFor server.requestAsync("account/read")
      check result["account"].getStr == "fixture"

    test "typed auth requests use the Codex account methods":
      let server = connectCodexAppServer(@[
        "sh", "-c",
        "read line; printf '%s\\n' '{\"id\":1,\"result\":{\"server\":\"fixture\"}}'; read line; read line; printf '%s\\n' '{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"planType\":\"plus\"}}}'; read line; printf '%s\\n' '{\"id\":3,\"result\":{\"type\":\"chatgpt\",\"loginId\":\"login-1\",\"authUrl\":\"https://chatgpt.com/login\"}}'; read line; printf '%s\\n' '{\"id\":4,\"result\":{}}'"])
      defer: server.close()
      let account = waitFor server.accountReadAsync()
      check account["account"]["type"].getStr == "chatgpt"
      let login = waitFor server.loginStartAsync("chatgpt")
      check login["loginId"].getStr == "login-1"
      discard waitFor server.logoutAsync()

    test "Codex provider starts a thread and streams a turn":
      let script = "read line; printf '%s\\n' '{\"id\":1,\"result\":{}}'; " &
        "read line; read line; printf '%s\\n' '{\"id\":2,\"result\":{\"data\":[{\"id\":\"gpt-test\",\"isDefault\":true}]}}'; " &
        "read line; printf '%s\\n' '{\"id\":3,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; " &
        "read line; printf '%s\\n' '{\"id\":4,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'; " &
        "printf '%s\\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"hello\"}}'; " &
        "printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}'"
      let provider = newCodexProvider(command = @["sh", "-c", script])
      defer: provider.close()
      check provider.models == @["gpt-test"]
      var deltas = ""
      let response = waitFor provider.generateStreamAsync(ProviderRequest(
        model: "gpt-test", messages: @[userMessage("hello")]),
        proc (event: StreamEvent): bool =
          if event.kind == seTextDelta: deltas.add event.text
          true)
      check deltas == "hello"
      check response.text == "hello"

proc invoke(pair: (ToolDefinition, ToolProc), input: JsonNode): ToolResult =
  waitFor pair[1](input)

proc writeExt(root, folder, name, runBody: string, timeout = 30,
              capabilities: seq[string] = @[]) =
  let dir = root / folder / "tools" / name
  createDir(dir)
  var manifest = %*{
    "name": name,
    "description": "Test tool " & name,
    "command": ["./run"],
    "input_schema": {"type": "object", "properties": {}}
  }
  if timeout != 30:
    manifest["timeout_seconds"] = %timeout
  if capabilities.len > 0:
    manifest["capabilities"] = %capabilities
  writeFile(dir / "tool.json", $manifest)
  writeFile(dir / "run", "#!/bin/sh\n" & runBody & "\n")
  inclFilePermissions(dir / "run", {fpUserExec, fpGroupExec, fpOthersExec})

proc writeHook(root, folder, name, event, runBody: string,
               tools: seq[string] = @[], timeout = 30) =
  let dir = root / folder / "hooks" / name
  createDir(dir)
  var manifest = %*{
    "name": name,
    "event": event,
    "command": ["./run"]
  }
  if tools.len > 0:
    manifest["tools"] = %tools
  if timeout != 30:
    manifest["timeout_seconds"] = %timeout
  writeFile(dir / "hook.json", $manifest)
  writeFile(dir / "run", "#!/bin/sh\n" & runBody & "\n")
  inclFilePermissions(dir / "run", {fpUserExec, fpGroupExec, fpOthersExec})

type
  TestProvider = ref object of Provider
    responses: seq[ProviderResponse]
    callCount: int

method generateAsync(provider: TestProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  result = provider.responses[min(provider.callCount, provider.responses.high)]
  inc provider.callCount

suite "rpc mode":
  test "commands are correlated and steering prompts queue":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(name: "test", responses: @[
      ProviderResponse(model: "test/model", content: @[text("first")],
        finishReason: frEndTurn),
      ProviderResponse(model: "test/model", content: @[text("second")],
        finishReason: frEndTurn)])
    var output: seq[JsonNode]
    let runtime = newRpcRuntime(addr agent,
      proc (event: JsonNode) = output.add event)
    defer: runtime.close()

    runtime.handleRpcLine("""{"id":"one","type":"prompt","message":"A"}""")
    runtime.handleRpcLine("""{"id":"two","type":"steer","message":"B"}""")
    let responses = output.filterIt(it.getOrDefault("type").getStr == "response")
    let queue = output.filterIt(it.getOrDefault("type").getStr == "queue")
    check responses[0]["id"].getStr == "one"
    check responses[0]["state"].getStr == "started"
    check responses[1]["id"].getStr == "two"
    check responses[1]["state"].getStr == "queued"
    check queue[0]["request_id"].getStr == "two"

    for _ in 0 .. 100:
      pumpAsyncDispatcher()
      discard runtime.pollRpc()
    runtime.handleRpcLine("""{"id":"state","type":"get_state"}""")
    check output[^1]["id"].getStr == "state"
    check not output[^1]["busy"].getBool
    check not output[^1]["queued"].getBool
    check output[^1]["steering_mode"].getStr == "one-at-a-time"
    check output[^1]["follow_up_mode"].getStr == "one-at-a-time"
    check output.filterIt(it.getOrDefault("type").getStr == "message" and
      it.getOrDefault("role").getStr == "assistant").mapIt(
        it["content"].getStr) == @["first", "second"]

  test "invalid commands and shutdown return JSON responses":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    var output: seq[JsonNode]
    let runtime = newRpcRuntime(addr agent,
      proc (event: JsonNode) = output.add event)
    defer: runtime.close()

    runtime.handleRpcLine("not json")
    runtime.handleRpcLine("""{"id":"bad","type":"wat"}""")
    runtime.handleRpcLine("""{"id":"bye","type":"shutdown"}""")
    check not output[0]["ok"].getBool
    check output[1]["id"].getStr == "bad"
    check not output[1]["ok"].getBool
    check output[2]["id"].getStr == "bye"
    check output[2]["state"].getStr == "stopped"
    check not runtime.pollRpc()

suite "black-box terminal integration":
  test "transcript shows a scrollbar when content overflows":
    let transcript = newTranscriptWidget()
    for i in 0 .. 12:
      transcript.appendStatus("line " & $i)
    var canvas = newCanvas(size(20, 4))
    render(transcript, canvas, rect(0, 0, 20, 4))
    check canvas.lineText(0).endsWith("┊")
    check canvas.lineText(3).endsWith("┃")

  test "transcript search finds, cycles, and highlights matches":
    let transcript = newTranscriptWidget()
    transcript.appendStatus("first needle")
    transcript.appendStatus("no match")
    transcript.appendStatus("second needle")
    transcript.searchStyle = Style(foreground: ansi16(1))
    var canvas = newCanvas(size(30, 6))
    render(transcript, canvas, rect(0, 0, 30, 6))
    check transcript.setSearch("NEEDLE") == 2
    check transcript.searchIndex == 0
    check transcript.nextSearch()
    check transcript.searchIndex == 1
    check transcript.nextSearch(backwards = true)
    check transcript.searchIndex == 0
    check transcript.setSearch("NEEDLE") == 2
    check transcript.searchIndex == 0
    render(transcript, canvas, rect(0, 0, 30, 6))
    check canvas.getCell(8, 0).style == transcript.searchStyle
    transcript.clearSearch()
    check transcript.searchMatches.len == 0

  test "resume picker filters sessions and prepares rename or delete":
    let root = freshDir()
    defer: removeDir(root)
    var named = initSession(root / "named.jsonl", "named")
    named.workspace = root
    named.addUserMessage("repair the parser")
    named.setName("Parser cleanup")
    let screen = newNimtermScreen("test", root, root, ModelPicker())
    screen.composer.setText("/resume parser")
    screen.refreshMenu()
    check screen.menu.items.mapIt(it.label) == @["/resume named"]
    check screen.handle(UiEvent(kind: uiKey, key: keyCtrlR)).handled
    check screen.composer.text == "/session rename named "
    screen.composer.setText("/resume ")
    screen.refreshMenu()
    check screen.handle(UiEvent(kind: uiKey, key: keyCtrlD)).handled
    check screen.composer.text == "/session delete named"

  test "enter submits after mouse focus moves through the transcript and composer":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[text("done")], finishReason: frEndTurn)])
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    screen.transcript.appendUser("copy me")
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    app.dispatch(UiEvent(kind: uiMouse, mouse: umPress,
      x: screen.transcript.area.x + 2, y: screen.transcript.area.y))
    app.dispatch(UiEvent(kind: uiMouse, mouse: umRelease,
      x: screen.transcript.area.x + 5, y: screen.transcript.area.y))
    app.dispatch(UiEvent(kind: uiMouse, mouse: umPress,
      x: screen.composer.area.x + 2, y: screen.composer.area.y))
    backend.feed("hello\r")
    for _ in 0 .. 30: discard app.step()
    check not controller.busy
    check agent.session.events[0].message.content[0].text == "hello"

  test "raw bytes submit a turn, render its result, and survive resize":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[text("terminal result")],
        finishReason: frEndTurn)])
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("he", "llo", "\r")
    for _ in 0 .. 30: discard app.step()
    check not controller.busy
    check agent.session.events[0].message.content[0].text == "hello"
    check "terminal result" in backend.frame.plainText
    backend.dimensions = size(72, 22)
    backend.resized = true
    check app.step()
    check backend.frame.size == size(72, 22)

  test "submitted messages appear once in the transcript":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[text("done")], finishReason: frEndTurn)])
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    discard newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("hello\r")
    for _ in 0 .. 30: discard app.step()
    check screen.transcript.transcript.items.filterIt(it.text == "hello").len == 1

  test "slash commands can follow one another":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("/provider anthropic\r")
    for _ in 0 .. 100: discard app.step()
    check agent.config.provider == "anthropic"
    check not controller.busy
    check app.focus == screen
    backend.feed("/model")
    for _ in 0 .. 20: discard app.step()
    check screen.menu.items.len > 0
    backend.feed("\r/exit\r")
    for _ in 0 .. 100: discard app.step()
    check not app.running

  test "status bar is visible before the first message":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    config.model = "startup-model"
    var agent = initAgent(config)
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    discard newNimletController(screen, addr app, addr agent)
    app.render()
    check "startup-model" in backend.frame.plainText
    check backend.frame.lineText(backend.frame.size.h - 1).endsWith(
      "openrouter/startup-model:off")
    check "#" & agent.session.id notin backend.frame.plainText

  test "composer is transparent with a muted rule and cyan prompt":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    app.render()
    let promptY = screen.composer.area.y + screen.composer.paddingTop
    let ruleY = screen.composer.area.y - 1
    check backend.frame.lineText(ruleY).startsWith("─")
    check backend.frame.getCell(10, promptY).style.background.kind == colorDefault
    check backend.frame.getCell(0, ruleY).style.background.kind == colorDefault
    check backend.frame.getCell(2, promptY).glyph.int == ord('>')
    check backend.frame.getCell(2, promptY).style.foreground.kind != colorDefault

  test "activity has its own row above the input rule":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    screen.busy = true
    screen.activity = "Waiting for model…"
    screen.footer = screen.statusLine("[act] · startup-model")
    var app = termapp.newApp(backend, screen)
    app.render()
    let activityY = screen.composer.area.y - 2
    let ruleY = screen.composer.area.y - 1
    let footerY = backend.frame.size.h - 1
    check "Waiting for model…" in backend.frame.lineText(activityY)
    check backend.frame.lineText(ruleY).startsWith("─")
    check backend.frame.lineText(footerY).startsWith("[act] · startup-model")
    check "Waiting for model…" notin backend.frame.lineText(footerY)
    let inputY = screen.composer.area.y
    screen.activity = "Responding with a longer status message…"
    app.render()
    check screen.composer.area.y == inputY
    check backend.frame.lineText(footerY).startsWith("[act] · startup-model")

  test "banner shortens the home directory":
    check displayPath(getHomeDir() / "repos" / "project") ==
      "~" / "repos" / "project"

  test "session id can be selected from the banner":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    let agent = initAgent(config)
    let id = agent.session.id
    let body = "Workspace: " & root & " · Session: " & id
    let backend = DecoderBackend(dimensions: size(140, 18))
    let screen = newNimtermScreen(body, root, config.sessionDir,
      ModelPicker(), id)
    var app = termapp.newApp(backend, screen)
    app.render()
    let line = screen.header.body.splitLines[0]
    let markerStart = line.find("Session: ")
    let first = ansiVisibleWidth(line[0 ..< markerStart]) + "Session: ".len
    let x = screen.header.area.x + 1 + first
    let y = screen.header.area.y + 1
    var response = screen.handle(UiEvent(kind: uiMouse, x: x, y: y,
      mouse: umPress))
    check response.captureMouse
    discard screen.handle(UiEvent(kind: uiMouse, x: x + id.len - 1, y: y,
      mouse: umDrag))
    response = screen.handle(UiEvent(kind: uiMouse, x: x + id.len - 1, y: y,
      mouse: umRelease))
    check response.action.kind == "copy"
    check response.action.value == id

  test "new session updates the banner session id":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    let oldId = agent.session.id
    let body = "Workspace: " & root & " · Session: " & oldId
    let backend = DecoderBackend(dimensions: size(140, 18))
    let screen = newNimtermScreen(body, root, config.sessionDir,
      ModelPicker(), oldId)
    var app = termapp.newApp(backend, screen)
    discard newNimletController(screen, addr app, addr agent)
    app.render()
    check ("Session: " & oldId) in backend.frame.plainText
    backend.feed("/new\r")
    for _ in 0 .. 100: discard app.step()
    check agent.session.id != oldId
    check ("Session: " & agent.session.id) in backend.frame.plainText
    check ("Session: " & oldId) notin backend.frame.plainText

  test "fork picker opens on Enter and leaves the selected prompt in the composer":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    let oldId = agent.session.id
    agent.session.addUserMessage("first prompt")
    agent.session.addAssistantResponse(ProviderResponse(content: @[text("answer")]))
    agent.session.addUserMessage("second prompt")
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker(), oldId)
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("/fork\r\r")
    for _ in 0 .. 100: discard app.step()
    check not controller.busy
    check agent.session.id != oldId
    check agent.session.events.len == 0
    check screen.composer.text == "first prompt"

  test "split key sequences route through a modal question":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[toolUse("question-1", "ask_user",
        %*{"question": "Choose", "options": ["Plan", "Act"]})],
        finishReason: frToolUse),
      ProviderResponse(content: @[text("selected")], finishReason: frEndTurn)])
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("ask\r")
    for _ in 0 .. 30:
      discard app.step()
      if controller.awaitingQuestion: break
    check controller.awaitingQuestion
    backend.feed("\e[", "B", "\r")
    for _ in 0 .. 50: discard app.step()
    check not controller.busy
    check agent.session.events[^2].toolOutput == "Act"
    check "selected" in backend.frame.plainText

  test "transcript scrolls while a question is awaiting an answer":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    for i in 0 ..< 40:
      screen.transcript.appendUser("message " & $i)
    screen.questionWidget = newQuestion("Choose", @[
      QuestionOption(label: "Plan"), QuestionOption(label: "Act")])
    let backend = DecoderBackend(dimensions: size(60, 18))
    var app = termapp.newApp(backend, screen)
    app.render()
    let atTail = screen.transcript.viewport.offset
    app.dispatch(UiEvent(kind: uiKey, key: keyPageUp))
    check screen.transcript.viewport.offset < atTail
    let aboveOptions = screen.transcript.viewport.offset
    app.dispatch(UiEvent(kind: uiKey, key: keyPageDown))
    check screen.transcript.viewport.offset > aboveOptions

  test "keyboard approval resumes a tool turn":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[toolUse("tool-1", "bash",
        %*{"command": "printf approved"})], finishReason: frToolUse),
      ProviderResponse(content: @[text("finished")], finishReason: frEndTurn)])
    let backend = DecoderBackend(dimensions: size(60, 18))
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(backend, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    app.render()
    backend.feed("run\r")
    for _ in 0 .. 30:
      discard app.step()
      if controller.awaitingApproval: break
    check controller.awaitingApproval
    backend.feed("\r")
    for _ in 0 .. 10: discard app.step()
    ## Creating a native Git Bash/PowerShell child has measurable startup
    ## cost on Windows. Poll until the turn settles rather than relying on a
    ## fixed delay that is fragile on a busy Windows host.
    let deadline = epochTime() + (if defined(windows): 5.0 else: 1.0)
    while controller.busy and epochTime() < deadline:
      discard app.step()
      waitFor sleepAsync(25)
    discard app.step()
    check not controller.busy
    var approved = false
    for event in agent.session.events:
      if event.kind == sekToolResult and "approved" in event.toolOutput:
        approved = true
    check approved
    check "finished" in backend.frame.plainText

suite "workspace and file tools":
  test "read returns numbered lines and version":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "sample.txt", "one\ntwo\nthree\n")
    let result = invoke(makeReadTool(initWorkspace(root)),
      %*{"path": "sample.txt", "start_line": 2, "end_line": 2})
    check not result.isError
    check "version:" in result.output
    check "2 | two" in result.output

  test "read paginates large text without rejecting the file":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "large.txt", "line\n".repeat(100_000))
    let first = invoke(makeReadTool(initWorkspace(root)),
      %*{"path": "large.txt"})
    check not first.isError
    check "output truncated" in first.output
    let page = invoke(makeReadTool(initWorkspace(root)), %*{
      "path": "large.txt", "start_line": 50_000, "end_line": 50_001
    })
    check not page.isError
    check "50000 | line" in page.output
    check "50001 | line" in page.output

  test "read rejects traversal":
    let root = freshDir()
    defer: removeDir(root)
    let result = invoke(makeReadTool(initWorkspace(root)), %*{"path": "../escape"})
    check result.isError
    check "outside the workspace" in result.output

  test "edit performs one exact replacement":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "sample.txt"
    writeFile(path, "before\nkeep\n")
    let version = fileVersion(path)
    let result = invoke(makeEditTool(initWorkspace(root)), %*{
      "path": "sample.txt",
      "old_text": "before",
      "new_text": "after",
      "expected_version": version
    })
    check not result.isError
    check readFile(path) == "after\nkeep\n"

  test "edit rejects ambiguous and stale replacements":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "sample.txt"
    writeFile(path, "same\nsame\n")
    let edit = makeEditTool(initWorkspace(root))
    check invoke(edit, %*{"path": "sample.txt", "old_text": "same",
      "new_text": "new"}).isError
    let stale = invoke(edit, %*{"path": "sample.txt", "old_text": "same\nsame\n",
      "new_text": "new", "expected_version": "stale"})
    check stale.isError
    check "version changed" in stale.output

  test "edit applies several unique replacements or none":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "sample.txt"
    writeFile(path, "aaa\nbbb\nccc\n")
    let edit = makeEditTool(initWorkspace(root))
    let ok = invoke(edit, %*{
      "path": "sample.txt",
      "replacements": [
        {"old_text": "aaa", "new_text": "AAA"},
        {"old_text": "ccc", "new_text": "CCC"}
      ]
    })
    check not ok.isError
    check "replacements: 2" in ok.output
    check readFile(path) == "AAA\nbbb\nCCC\n"
    writeFile(path, "same\nsame\nkeep\n")
    let bad = invoke(edit, %*{
      "path": "sample.txt",
      "replacements": [
        {"old_text": "keep", "new_text": "kept"},
        {"old_text": "same", "new_text": "x"}
      ]
    })
    check bad.isError
    check readFile(path) == "same\nsame\nkeep\n"

  test "grep and glob find workspace files":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / "src")
    writeFile(root / "src" / "a.nim", "proc hello =\n  discard\n")
    writeFile(root / "src" / "b.txt", "hello world\n")
    writeFile(root / "readme.md", "hello docs\n")
    check globMatch("src/a.nim", "**/*.nim")
    check globMatch("a.nim", "**/*.nim")
    check globMatch("src/a.nim", "src/*")
    check not globMatch("src/a.nim", "*.nim")
    let grep = invoke(makeGrepTool(initWorkspace(root)),
      %*{"pattern": "hello", "glob": "**/*.nim"})
    check not grep.isError
    check "src/a.nim:1:" in grep.output
    check "b.txt" notin grep.output
    let grepRe = invoke(makeGrepTool(initWorkspace(root)),
      %*{"pattern": "proc\\s+hello"})
    check not grepRe.isError
    check "src/a.nim:1:" in grepRe.output
    let badRe = invoke(makeGrepTool(initWorkspace(root)), %*{"pattern": "("})
    check badRe.isError
    check "invalid pattern" in badRe.output
    let glob = invoke(makeGlobTool(initWorkspace(root)),
      %*{"pattern": "**/*.txt"})
    check not glob.isError
    check "src/b.txt" in glob.output
    check "a.nim" notin glob.output

  test "write creates and protects existing files":
    let root = freshDir()
    defer: removeDir(root)
    let write = makeWriteTool(initWorkspace(root))
    check not invoke(write, %*{"path": "new.txt", "content": "hello"}).isError
    check invoke(write, %*{"path": "new.txt", "content": "no"}).isError
    check not invoke(write, %*{"path": "new.txt", "content": "yes",
      "overwrite": true}).isError
    check readFile(root / "new.txt") == "yes"

suite "permissions":
  test "workspace tools are automatic and shell grants are scoped":
    let root = freshDir()
    defer: removeDir(root)
    let policy = newPermissionPolicy(root)
    let read = toolUse("read-1", "read", %*{"path": "README.md"})
    let status = toolUse("bash-1", "bash", %*{"command": "git   status"})
    let diff = toolUse("bash-2", "bash", %*{"command": "git diff"})
    check policy.check(read) == pcAllow
    check policy.check(status) == pcAsk
    policy.remember(status, pdAllowSession)
    check policy.check(status) == pcAllow
    check policy.check(diff) == pcAsk

  test "project grants survive reload and can be cleared":
    let root = freshDir()
    defer: removeDir(root)
    let status = toolUse("bash-1", "bash", %*{"command": "git status"})
    var policy = newPermissionPolicy(root)
    policy.remember(status, pdAllowProject)
    policy = newPermissionPolicy(root)
    check policy.check(status) == pcAllow
    policy.clearProject()
    check policy.check(status) == pcAsk

suite "bash tool":
  test "streams output while running":
    let root = freshDir()
    defer: removeDir(root)
    var reg: ToolRegistry
    let bash = makeBashTool(root)
    reg.register(bash[0], bash[1])
    var streamed = ""
    let result = waitFor reg.execute("bash",
      %*{"command": "printf first; sleep 0.05; printf second"},
      onOutput = proc (output: string) = streamed.add output)
    check not result.isError
    check "first" in streamed
    check "second" in streamed

  test "captures output and exit code":
    let root = freshDir()
    defer: removeDir(root)
    let bash = makeBashTool(root)
    let success = invoke(bash, %*{"command": "printf hello"})
    check not success.isError
    check "exit_code: 0" in success.output
    check "hello" in success.output
    let failureCommand = if defaultShell().kind == shellPowerShell:
      "Write-Error error; exit 3"
    else:
      "printf error >&2; exit 3"
    let failure = invoke(bash, %*{"command": failureCommand})
    check failure.isError
    check "exit_code: 3" in failure.output
    check "stderr:" in failure.output

  test "enforces timeout":
    let root = freshDir()
    defer: removeDir(root)
    let result = invoke(makeBashTool(root),
      %*{"command": "sleep 2", "timeout_seconds": 1})
    check result.isError
    check "TIMEOUT" in result.output

  test "cancels a running command":
    let root = freshDir()
    defer: removeDir(root)
    var reg: ToolRegistry
    let bash = makeBashTool(root)
    reg.register(bash[0], bash[1])
    let t0 = epochTime()
    let result = waitFor reg.execute("bash", %*{"command": "sleep 5"},
      proc (): bool = true)
    check result.isError
    check "INTERRUPTED" in result.output
    check epochTime() - t0 < 2.0

  test "keeps the async dispatcher live while a command runs":
    let root = freshDir()
    defer: removeDir(root)
    var reg: ToolRegistry
    let bash = makeBashTool(root)
    reg.register(bash[0], bash[1])
    var cancelled = false
    proc cancelSoon() {.async.} =
      await sleepAsync(50)
      cancelled = true
    asyncCheck cancelSoon()
    let result = waitFor reg.execute("bash", %*{"command": "sleep 5"},
      proc (): bool = cancelled)
    check result.isError
    check "INTERRUPTED" in result.output

  test "cancel kills the process group":
    let root = freshDir()
    defer: removeDir(root)
    var reg: ToolRegistry
    let bash = makeBashTool(root)
    reg.register(bash[0], bash[1])
    let result = when defined(windows):
      ## Windows cancellation stops the shell process itself; process-group
      ## termination is not portable without assigning a Job Object.
      waitFor reg.execute("bash", %*{"command": "Start-Sleep 8"},
        proc (): bool = true)
    else:
      let pidPath = root / "pid"
      waitFor reg.execute("bash",
        %*{"command": "sleep 8 &\necho $! > pid\nwait", "timeout_seconds": 3},
        proc (): bool =
          # Wait is event-driven; this test's cancel signal is a file, not an fd.
          for _ in 0 .. 50:
            if fileExists(pidPath): return true
            sleep(10)
          false)
    check result.isError
    check "INTERRUPTED" in result.output
    when not defined(windows):
      let child = readFile(pidPath).strip.parseInt
      sleep(50)
      check posix.kill(Pid(child), 0) != 0

suite "session":
  test "extension entries persist without entering model context":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "extension.jsonl"
    var session = initSession(path, "extension")
    session.addUserMessage("hello")
    session.addExtensionEntry("counter", %*{"turns": 1})
    let loaded = initSession(path, "extension")
    check loaded.extensionEntries("counter") == @[%*{"turns": 1}]
    check loaded.messagesForModel.len == 1

  test "JSONL round trip and partial final line recovery":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "session.jsonl"
    var original = initSession(path, "test")
    original.addUserMessage("hello")
    original.addAssistantResponse(ProviderResponse(content: @[text("world")]))
    check original.events.len == 2
    var file = open(path, fmAppend)
    file.write("{\"type\":\"assistant\"")
    file.close()
    let recovered = initSession(path, "test")
    check recovered.events.len == 2
    check recovered.messages.len == 2
    check recovered.messages[0].content[0].text == "hello"
    check recovered.messages[1].content[0].text == "world"

  test "appending after a torn tail preserves a backup and survives another restart":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "torn.jsonl"
    var original = initSession(path, "torn")
    original.addUserMessage("before crash")
    let damaged = readFile(path) & "{\"type\":\"assistant\""
    writeFile(path, damaged)
    var recovered = initSession(path, "torn")
    check readFile(path) == damaged
    recovered.addUserMessage("after crash")
    let reloaded = initSession(path, "torn")
    check reloaded.events.len == 2
    check reloaded.messages[^1].content[0].text == "after crash"
    var backups = 0
    ## `walkFiles` does not match a full Windows path containing a wildcard
    ## consistently across Nim's supported Windows runtimes.  Enumerate the
    ## already-known directory and apply the exact recovery-file prefix.
    for kind, backup in walkDir(root):
      if kind == pcFile and backup.startsWith(path & ".recovery-"):
        check readFile(backup) == damaged
        inc backups
    check backups == 1
    writeFile(path, readFile(path).strip)
    var noNewline = initSession(path, "torn")
    noNewline.addUserMessage("one more")
    check initSession(path, "torn").events.len == 3

  test "crash recovery closes only missing local tool results and is idempotent":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "tools.jsonl"
    var original = initSession(path, "tools")
    let done = toolUse("done", "write", %*{"path": "done.txt"})
    let pending = toolUse("pending", "bash", %*{"command": "some action"})
    original.addUserMessage("work")
    original.addAssistantResponse(ProviderResponse(content: @[
      done, pending, toolUse("hosted", "web_search", %*{}, hosted = "web_search")]),
      "anthropic", "claude-sonnet-4-6")
    original.addToolResult(done, "already completed", false)
    var recovered = initSession(path, "tools")
    check recovered.recoverInterruptedTools() == 1
    check recovered.events[^1].toolId == "pending"
    check recovered.events[^1].toolError
    check "outcome is unknown" in recovered.events[^1].toolOutput
    check recovered.recoverInterruptedTools() == 0
    var restarted = initSession(path, "tools")
    check restarted.recoverInterruptedTools() == 0
    check restarted.messages[2].content.len == 2

  test "tool use parse_error round-trips":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "pe.jsonl"
    var original = initSession(path, "pe")
    original.addAssistantResponse(ProviderResponse(content: @[
      toolUseFromArgs("c1", "echo", "{nope")]))
    let recovered = initSession(path, "pe")
    check recovered.messages[0].content[0].parseError.len > 0

  test "native Google parts and tool signatures round-trip":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "google.jsonl"
    var original = initSession(path, "google")
    var call = toolUse("native-id", "lookup", %*{"name": "Alice"})
    call.thoughtSignature = "opaque-signature"
    call.googlePart = %*{"functionCall": {"id": "native-id", "name": "lookup",
      "args": {"name": "Alice"}}, "thoughtSignature": "opaque-signature"}
    var answer = text("done")
    answer.googlePart = %*{"text": "done", "thoughtSignature": "answer-signature"}
    original.addAssistantResponse(ProviderResponse(content: @[call, answer]),
      "google", "gemini-3.5-flash-lite")
    let recovered = initSession(path, "google")
    check recovered.messages[0].content[0].thoughtSignature == "opaque-signature"
    check recovered.messages[0].content[0].googlePart == call.googlePart
    check recovered.messages[0].content[1].googlePart == answer.googlePart

  test "lists sessions newest first":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "older.jsonl", "")
    writeFile(root / "newer.jsonl", "")
    writeFile(root / "skip.txt", "")
    setLastModificationTime(root / "older.jsonl", fromUnix(1_000))
    setLastModificationTime(root / "newer.jsonl", fromUnix(2_000))
    let infos = listSessions(root, limit = 0)
    check infos.mapIt(it.id) == @["newer", "older"]
    check listSessions(root / "missing", limit = 0).len == 0

  test "lists sessions with first-user preview and relative age":
    let root = freshDir()
    defer: removeDir(root)
    var older = initSession(root / "older.jsonl", "older")
    older.addUserMessage("fix the failing parser test\nand more")
    var newer = initSession(root / "newer.jsonl", "newer")
    newer.addUserMessage("a".repeat(80))
    writeFile(root / "empty.jsonl", "")
    setLastModificationTime(root / "older.jsonl", fromUnix(1_000))
    setLastModificationTime(root / "newer.jsonl", fromUnix(2_000))
    setLastModificationTime(root / "empty.jsonl", fromUnix(1_500))
    let infos = listSessions(root)
    check infos.len == 3
    check infos[0].id == "newer"
    check infos[0].preview.startsWith("aaa")
    check infos[0].preview.endsWith("…")
    check infos[1].id == "empty"
    check infos[1].preview == "(empty)"
    check infos[2].id == "older"
    check infos[2].preview == "fix the failing parser test"
    let now = fromUnix(1_000 + 3600)
    check relativeAge(fromUnix(1_000), now) == "1h ago"
    check relativeAge(fromUnix(1_000), fromUnix(1_030)) == "just now"
    check relativeAge(fromUnix(1_000), fromUnix(1_000 + 90)) == "1m ago"
    check relativeAge(fromUnix(1_000), fromUnix(1_000 + 86400)) == "1d ago"
    let line = sessionListLine(infos[2], "older", now)
    check "1h ago" in line
    check "fix the failing parser test" in line
    check "#older" in line
    check "(current)" in line
    check peekSession(root, "older").preview == "fix the failing parser test"

  test "session search reaches older matches and trash restores them":
    let root = freshDir()
    defer: removeDir(root)
    for i in 0 ..< sessionListLimit + 2:
      let id = "s" & $i
      var sess = initSession(root / (id & ".jsonl"), id)
      sess.addUserMessage(if i == 0: "needle in an older session"
                          else: "ordinary session")
      setLastModificationTime(root / (id & ".jsonl"), fromUnix(1_000 + i))
    let matches = searchSessions(root, "", "needle")
    check matches.mapIt(it.id) == @["s0"]
    check sessionMatches(matches[0], "NEEDLE older")
    let deleted = trashSession(root, "s0")
    check deleted.ok
    check not fileExists(root / "s0.jsonl")
    check listTrashedSessionIds(root) == @["s0"]
    let restored = restoreSession(root, "s0")
    check restored.ok
    check fileExists(root / "s0.jsonl")
    check initSession(root / "s0.jsonl", "s0").events.len == 1

  test "session name round-trips and labels the picker":
    let root = freshDir()
    defer: removeDir(root)
    var sess = initSession(root / "named.jsonl", "named")
    sess.addUserMessage("the first user prompt is long")
    sess.setName("Fix parser")
    let reloaded = initSession(root / "named.jsonl", "named")
    check reloaded.name == "Fix parser"
    check reloaded.events[^1].kind == sekName
    let info = peekSession(root, "named")
    check info.name == "Fix parser"
    check info.preview == "the first user prompt is long"
    check "Fix parser" in sessionLabel(info)
    check "the first user prompt is long" notin sessionLabel(info)

  test "workspace header round trip and listing filter":
    let root = freshDir()
    defer: removeDir(root)
    var here = initSession(root / "here.jsonl", "here")
    here.workspace = "/proj/here"
    here.addUserMessage("this repo")
    var there = initSession(root / "there.jsonl", "there")
    there.workspace = "/proj/there"
    there.addUserMessage("other repo")
    var orphan = initSession(root / "orphan.jsonl", "orphan")
    orphan.addUserMessage("no header")
    setLastModificationTime(root / "there.jsonl", fromUnix(3_000))
    setLastModificationTime(root / "here.jsonl", fromUnix(2_000))
    setLastModificationTime(root / "orphan.jsonl", fromUnix(1_000))
    let reloaded = initSession(root / "here.jsonl", "here")
    check reloaded.workspace == "/proj/here"
    check reloaded.events.len == 1
    let raw = readFile(root / "here.jsonl")
    check raw.startsWith("{\"type\":\"session\"")
    let hereInfos = listSessions(root, "/proj/here")
    check hereInfos.len == 1
    check hereInfos[0].id == "here"
    check hereInfos[0].workspace == "/proj/here"
    let thereInfos = listSessions(root, "/proj/there")
    check thereInfos.mapIt(it.id) == @["there"]
    check listSessions(root, limit = 0).mapIt(it.id) == @[
      "there", "here", "orphan"]
    check peekSession(root, "there").workspace == "/proj/there"

  test "session picker caps at newest 20":
    let root = freshDir()
    defer: removeDir(root)
    for i in 0 ..< sessionListLimit + 3:
      let id = "s" & $i
      writeFile(root / (id & ".jsonl"), "")
      setLastModificationTime(root / (id & ".jsonl"), fromUnix(1_000 + i))
    let infos = listSessions(root)
    check infos.len == sessionListLimit
    check infos[0].id == "s" & $(sessionListLimit + 2)
    check listSessions(root, limit = 0).len == sessionListLimit + 3

  test "fork copies the prefix before a selected user message":
    let root = freshDir()
    defer: removeDir(root)
    var sess = initSession(root / "source.jsonl", "source")
    sess.workspace = root
    sess.addUserMessage("first")
    sess.addAssistantResponse(ProviderResponse(content: @[text("answer")]))
    sess.addUserMessage("second")
    let choices = sess.forkChoices
    check choices.len == 2
    check choices[0].eventIndex == 0
    check choices[0].text == "first"
    check choices[1].eventIndex == 2
    let forked = forkSession(sess, choices[1].eventIndex)
    check forked.id != sess.id
    check forked.workspace == root
    check forked.events.len == 2
    check forked.events[0].kind == sekUser
    check forked.events[1].kind == sekAssistant
    let loaded = initSession(forked.path, forked.id)
    check loaded.events.len == 2
    check loaded.messages[0].content[0].text == "first"

suite "OpenRouter provider":
  test "configuration defaults to OpenRouter":
    let root = freshDir()
    defer: removeDir(root)
    let config = loadConfig(root, root / "config.json")
    check config.provider == "openrouter"
    check config.model == "deepseek/deepseek-v4-flash-0731"
    check config.apiKeySource == "{env:OPENROUTER_API_KEY}"
    check config.endpoint == "https://openrouter.ai/api/v1/chat/completions"
    check nimletConfigDir().extractFilename == ".nimlet"

  test "plugin dirs are global, then .agent, then .nimlet":
    let root = freshDir()
    defer: removeDir(root)
    let ws = expandFilename(root)
    check pluginRoots(root, "hooks") == @[
      nimletConfigDir() / "hooks",
      ws / ".agent" / "hooks",
      ws / ".nimlet" / "hooks"]
    createDir(root / ".agent" / "hooks" / "x")
    writeFile(root / ".agent" / "hooks" / "x" / "hook.json", "{}")
    createDir(root / ".nimlet" / "hooks" / "y")
    writeFile(root / ".nimlet" / "hooks" / "y" / "hook.json", "{}")
    check collectPluginDirs(root, "hooks", "hook.json") ==
      @[ws / ".agent" / "hooks" / "x", ws / ".nimlet" / "hooks" / "y"]

  test "openai provider defaults and thinking map to reasoning.effort":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(root / "config.json", """{"default_provider":"openai"}""")
    var config = loadConfig(root, root / "config.json")
    check config.provider == "openai"
    check config.model == "gpt-5"
    check config.apiKeySource == "{env:OPENAI_API_KEY}"
    check config.endpoint == "https://api.openai.com/v1/responses"
    config.thinking = "high"
    check providerOptions(config)["reasoning"]["effort"].getStr == "high"
    config.thinking = "none"
    check "reasoning" notin providerOptions(config)

  test "hyper provider defaults and thinking map to reasoning.effort":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(root / "config.json", """{"default_provider":"hyper"}""")
    var config = loadConfig(root, root / "config.json")
    check config.provider == "hyper"
    check config.model == "deepseek-v4-flash"
    check config.apiKeySource == "{env:HYPER_API_KEY}"
    check config.endpoint == "https://hyper.charm.land/v1/chat/completions"
    config.thinking = "high"
    check providerOptions(config)["reasoning"]["effort"].getStr == "high"
    config.thinking = "none"
    check "reasoning" notin providerOptions(config)

  test "google provider defaults and thinking use the native transport":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(root / "config.json", """{"default_provider":"google"}""")
    var config = loadConfig(root, root / "config.json")
    check config.provider == "google"
    check config.model == "gemini-3.5-flash-lite"
    check config.apiKeySource == "{env:AI_STUDIO_API_KEY}"
    check config.endpoint == "https://generativelanguage.googleapis.com/v1beta"
    config.thinking = "high"
    check providerOptions(config)["reasoning_effort"].getStr == "high"
    let agent = initAgent(config)
    check agent.provider.name == "google"
    check agent.provider.supports(pcHostedTools)

suite "persistent agent sessions":
  test "new session files can be resumed":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    check agent.session.workspace == config.workspace
    let firstId = agent.session.id
    agent.session.addUserMessage("keep this")
    check fileExists(config.sessionDir / (firstId & ".jsonl"))
    check "\"type\":\"session\"" in readFile(config.sessionDir / (firstId & ".jsonl"))

    agent.session = initSession(config.sessionDir / (firstId & ".jsonl"), firstId)
    check agent.processInput("/new", consoleSink())
    let secondId = agent.session.id
    check secondId != firstId
    check agent.processInput("/resume " & firstId, consoleSink())
    check agent.session.id == firstId
    check agent.session.events.len == 1
    check agent.session.messages[0].content[0].text == "keep this"
    check agent.processInput("/resume", consoleSink())
    check agent.processInput("/name Fix parser", consoleSink())
    check agent.session.name == "Fix parser"
    check agent.processInput("/model other/model", consoleSink())
    check agent.config.model == "other/model"

  test "assistant usage is restored into status text":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "sess.jsonl"
    var session = initSession(path, "status1")
    var usage = Usage(inputTokens: 10, outputTokens: 4, cacheReadTokens: 8,
      cacheReported: true)
    session.addAssistantResponse(ProviderResponse(
      model: "test/model", usage: usage,
      content: @[text("hi")]))
    let reloaded = initSession(path, "status1")
    let (found, model, got) = reloaded.lastAssistant
    check found
    check model == "test/model"
    check got.inputTokens == 10
    check got.outputTokens == 4
    check got.cacheReadTokens == 8
    var agent = Agent(config: AgentConfig(provider: "test", model: "fallback",
      contextWindow: 100),
                      session: reloaded)
    let status = agent.statusFooter
    check "fallback" notin status
    check "↑10" in status
    check "↓4" in status
    check "R8" in status
    check "ctx 10%" in status
    check status.find("ctx 10%") >= 0
    let right = stripAnsi(agent.statusFooterRight)
    check right == "test/fallback:off"
    check "status1" notin status
    check " · " in status
    check status.find(" · ") > 0

  test "narrow status drops optional fields cleanly":
    var agent = Agent(mode: modeAct, yolo: true,
      config: AgentConfig(model: "a-very-long-model-name"))
    let status = agent.statusFooter(20)
    check "[act]" in status
    check "[yolo]" in status
    check "a-very-long-model-name" notin status

  test "stats shows detailed usage on demand":
    var session = initSession()
    session.addAssistantResponse(ProviderResponse(model: "test/model",
      usage: Usage(inputTokens: 10, outputTokens: 4), content: @[text("hi")]))
    var agent = Agent(config: AgentConfig(provider: "openrouter",
      model: "test/model", contextWindow: 100), session: session)
    var output = ""
    var ui = consoleSink()
    ui.emit = proc (level: MsgLevel, value: string) = output.add value
    check parseSlash("/stats").kind == slStats
    check parseSlash("/stats now").kind == slError
    check agent.processInput("/stats", ui)
    check "Provider: openrouter" in output
    check "Latest: ↑10" in output
    check "Context: 10 / 100 (10%)" in output
    check "Session: ↑10" in output

  test "context percent uses anthropic-style split totals":
    var usage = Usage(inputTokens: 100, outputTokens: 1, cacheReadTokens: 900,
      cacheReported: true)
    check contextTokens(usage) == 1000
    var session = initSession()
    session.addAssistantResponse(ProviderResponse(
      model: "claude", usage: usage, content: @[text("x")]))
    var agent = Agent(config: AgentConfig(model: "claude", contextWindow: 2000),
                      session: session)
    check "ctx 50%" in agent.statusFooter

  test "resume restores last model and warns on foreign workspace":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    createDir(config.sessionDir)
    var sess = initSession(config.sessionDir / "chat1.jsonl", "chat1")
    sess.workspace = "/other/project"
    sess.addUserMessage("hello")
    sess.addAssistantResponse(ProviderResponse(
      model: "kept/model", content: @[text("hi")]))
    var agent = initAgent(config, "chat1")
    check agent.config.model == "kept/model"
    check agent.session.workspace == "/other/project"
    agent.config.model = "fallback/model"
    var warns: seq[string] = @[]
    proc captureEmit(level: MsgLevel, text: string) =
      if level == mlWarn: warns.add text
    let ui = TurnSink(
      emit: captureEmit,
      render: proc() = discard,
      onChange: proc() = discard,
      commitGenerate: proc(response: ProviderResponse, final: bool) = discard,
      toolStart: proc(call: ContentBlock) = discard,
      toolResult: proc(output: string, isError: bool) = discard,
      poll: proc() = discard,
      wasInterrupted: proc(): bool = false,
      noteInterrupted: proc() = discard,
      generate: proc(provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] =
        provider.generateAsync(request)
    )
    check agent.processInput("/resume chat1", ui)
    check agent.config.model == "kept/model"
    check warns.len == 1
    check "/other/project" in warns[0]

  test "fork switches sessions and restores the selected prompt":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    agent.session.addUserMessage("first")
    agent.session.addAssistantResponse(ProviderResponse(content: @[text("answer")]))
    agent.session.addUserMessage("second")
    var shown = ""
    var selected = ""
    var ui = consoleSink()
    ui.showSession = proc (session: Session) = shown = session.id
    ui.setEditorText = proc (text: string) = selected = text
    check agent.processInput("/fork 2", ui)
    check shown == agent.session.id
    check selected == "second"
    check agent.session.id != ""
    check agent.session.events.len == 2
    check agent.session.messages[0].content[0].text == "first"
    check fileExists(agent.session.path)
    ui.generate = proc (provider: Provider,
                        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      return ProviderResponse(content: @[text("continued")], finishReason: frEndTurn)
    check agent.processInput(selected, ui)
    let forkId = agent.session.id
    check agent.session.events.len == 4
    let resumed = initAgent(config, forkId)
    check resumed.session.events.len == 4
    check resumed.session.messages[^2].content[0].text == "second"

suite "agent turn persistence":
  test "plan mode limits advertised and executed tools, act restores normal tools":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "inspect.txt", "safe content")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    config.webSearch = true
    var agent = initAgent(config)
    var executed = false
    agent.tools.register(ToolDefinition(name: "read"), proc (input: JsonNode): Future[ToolResult] {.async.} =
      executed = true
      return ToolResult(output: "overridden"))
    agent.tools.register(ToolDefinition(name: "custom"), proc (input: JsonNode): Future[ToolResult] {.async.} =
      executed = true
      return ToolResult(output: "custom"))
    var ui = consoleSink()
    check agent.processInput("/plan", ui)
    check agent.mode == modePlan
    check "[plan]" in agent.statusFooter
    let request = agent.buildRequest()
    var names: seq[string]
    for tool in request.tools: names.add tool.name
    check names == @["read", "grep", "glob", "git", "read_skill", "ask_user"]
    check "Current mode: PLAN" in request.system.join("\n")
    check "one targeted search/read/history" in request.system.join("\n")
    var turns = 0
    ui.generate = proc (provider: Provider,
        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      inc turns
      if turns == 1:
        return ProviderResponse(content: @[
          toolUse("read1", "read", %*{"path": "inspect.txt"}),
          toolUse("write1", "write", %*{"path": "forbidden.txt", "content": "bad"}),
          toolUse("bash1", "bash", %*{"command": "touch forbidden.txt"}),
          toolUse("custom1", "custom", %*{})], finishReason: frToolUse)
      return ProviderResponse(content: @[text("Here is the plan.")], finishReason: frEndTurn)
    check agent.processInput("investigate", ui)
    check turns == 2
    check not executed
    check not fileExists(root / "forbidden.txt")
    check "safe content" in agent.session.events[2].toolOutput
    for i in 3..5:
      check agent.session.events[i].toolError
      check "plan mode" in agent.session.events[i].toolOutput
    check agent.processInput("/act", ui)
    check agent.mode == modeAct
    check "[act]" in agent.statusFooter
    var hasBash = false
    for tool in agent.buildRequest().tools:
      if tool.name == "bash": hasBash = true
    check hasBash
    check not fileExists(config.writePath)

  test "mode switching reaches the next request":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    var requests: seq[ProviderRequest]
    var ui = consoleSink()
    ui.generate = proc (provider: Provider,
                        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      requests.add request
      return ProviderResponse(content: @[text("done")], finishReason: frEndTurn)
    agent.mode = modePlan
    check agent.mode == modePlan
    check agent.processInput("describe the work", ui)
    agent.mode = modeAct
    check agent.mode == modeAct
    check agent.processInput("implement the plan", ui)
    check requests.len == 2
    check "Current mode: PLAN" in requests[0].system.join("\n")
    check requests[0].system[^1].startsWith("Current mode: PLAN")
    check "Current mode: ACT (authoritative)" in requests[1].system.join("\n")
    check requests[1].system[^1].startsWith("Current mode: ACT (authoritative)")
    check requests[0].tools.len < requests[1].tools.len

  test "thinking-only final response gets a user-facing follow-up":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.mode = modePlan
    var requests: seq[ProviderRequest]
    var shown: seq[string]
    var notices: seq[string]
    var replies = @[
      ProviderResponse(content: @[
        ContentBlock(kind: ckThinking, thinking: "I will share the plan next.")],
        finishReason: frEndTurn),
      ProviderResponse(content: @[text("Here is the plan.")],
        finishReason: frEndTurn)]
    var replyIndex = 0
    var ui = consoleSink()
    ui.emit = proc (level: MsgLevel, value: string) = notices.add value
    ui.commitGenerate = proc (response: ProviderResponse, final: bool) =
      if final: shown.add response.text
    ui.generate = proc (provider: Provider,
                        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      requests.add request
      result = replies[replyIndex]
      inc replyIndex

    check agent.processInput("make a plan", ui)
    check requests.len == 2
    check shown == @["", "Here is the plan."]
    check notices.len == 1
    check "no user-facing answer" in notices[0]
    check requests[1].messages[^1].content[0].text.startsWith(
      "Your previous response ended after internal reasoning")
    # The recovery prompt is request-local and never appears in the transcript.
    check agent.session.events.len == 3
    check agent.session.events[^1].message.content[0].text == "Here is the plan."

  test "cancelled generation leaves no partial assistant and can continue":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    var ui = consoleSink()
    var interrupted = 0
    ui.noteInterrupted = proc () = inc interrupted
    ui.generate = proc (provider: Provider,
        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      raiseCancelledError()
    check agent.processInput("first attempt", ui)
    check interrupted == 1
    check agent.session.events.len == 1
    ui.generate = proc (provider: Provider,
        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      return ProviderResponse(content: @[text("done")], finishReason: frEndTurn)
    check agent.processInput("try again", ui)
    check agent.session.events.len == 3
    let restarted = initSession(agent.session.path, agent.session.id)
    check restarted.events.len == 3
    check restarted.events[^1].kind == sekAssistant

  test "resume restores the requested provider and model, repairs tools, and continues":
    let root = freshDir()
    defer: removeDir(root)
    let configPath = root / "config.json"
    writeFile(configPath, """{"default_provider":"hyper","default_model":"hyper-choice",
      "agent":{"compaction_enabled":false}}""")
    var config = loadConfig(root, configPath)
    config.sessionDir = root / "sessions"
    createDir(config.sessionDir)
    var sess = initSession(config.sessionDir / "resume.jsonl", "resume")
    sess.workspace = root
    sess.addUserMessage("do work")
    sess.addAssistantResponse(ProviderResponse(model: "reported-version",
      content: @[toolUse("pending", "bash", %*{"command": "must not execute"})]),
      "anthropic", "claude-sonnet-4-6")
    let beforeConfig = readFile(configPath)
    var agent = initAgent(config, "resume")
    check agent.config.provider == "anthropic"
    check agent.provider.name == "anthropic"
    check agent.config.model == "claude-sonnet-4-6"
    check agent.session.events[^1].kind == sekToolResult
    var ui = consoleSink()
    var generated = 0
    ui.generate = proc (provider: Provider,
        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      inc generated
      check provider.name == "anthropic"
      check request.model == "claude-sonnet-4-6"
      check request.messages[2].content[0].kind == ckToolResult
      check request.messages[2].content[0].isError
      return ProviderResponse(model: "reported-version", content: @[text("continued")], finishReason: frEndTurn)
    ui.toolStart = proc (call: ContentBlock) = check false
    check agent.processInput("continue", ui)
    check generated == 1
    let restarted = initAgent(config, "resume")
    check restarted.config.provider == "anthropic"
    check restarted.config.model == "claude-sonnet-4-6"
    agent.applyProvider("hyper", persist = false)
    check agent.processInput("/resume resume", ui)
    check agent.config.provider == "anthropic"
    check agent.config.model == "claude-sonnet-4-6"
    check readFile(configPath) == beforeConfig

  test "output-token limits continue the turn":
    var config = loadConfig()
    config.contextWindow = 1_000_000
    config.compactionEnabled = false
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[text("part one")], finishReason: frMaxTokens),
        ProviderResponse(content: @[text("part two")], finishReason: frStop)
      ])
    var agent = Agent(config: config, provider: provider, session: initSession())
    agent.session.addUserMessage("do the work")
    var finals: seq[bool]
    let ui = TurnSink(
      emit: proc(level: MsgLevel, text: string) = discard,
      render: proc() = discard,
      onChange: proc() = discard,
      commitGenerate: (proc(response: ProviderResponse, final: bool) =
        finals.add final),
      toolStart: proc(call: ContentBlock) = discard,
      toolResult: proc(output: string, isError: bool) = discard,
      poll: proc() = discard,
      wasInterrupted: proc(): bool = false,
      noteInterrupted: proc() = discard,
      generate: proc(provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] =
        provider.generateAsync(request)
    )
    agent.runTurn(ui)

    check provider.callCount == 2
    check finals == @[false, true]
    check agent.session.messages.len == 3
    check agent.session.messages[1].content[0].text == "part one"
    check agent.session.messages[2].content[0].text == "part two"

  test "steering interrupts after tools and follow-ups wait for completion":
    var config = loadConfig()
    config.contextWindow = 1_000_000
    config.compactionEnabled = false
    var reg: ToolRegistry
    reg.register(ToolDefinition(name: "touch"),
      proc(input: JsonNode): Future[ToolResult] {.async.} =
        return ToolResult(output: "ok"))
    let steeringProvider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[toolUse("call-1", "touch", %*{})],
          finishReason: frToolUse),
        ProviderResponse(content: @[text("steered")], finishReason: frEndTurn)])
    var steeringReady = false
    var steeringRequests: seq[ProviderRequest]
    var steeringAgent = Agent(config: config, provider: steeringProvider,
      session: initSession(), tools: reg)
    steeringAgent.session.addUserMessage("start")
    var steeringUi = consoleSink()
    steeringUi.generate = proc(provider: Provider,
                               request: ProviderRequest): Future[ProviderResponse] {.async.} =
      steeringRequests.add request
      return await provider.generateAsync(request)
    steeringUi.toolResult = proc(output: string, isError: bool) =
      steeringReady = true
    steeringUi.takeSteering = proc(): seq[string] =
      if steeringReady:
        steeringReady = false
        return @["steer"]
    steeringAgent.runTurn(steeringUi)
    check steeringProvider.callCount == 2
    check steeringRequests[1].messages[^1].content[0].text == "steer"

    let followProvider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[text("first")], finishReason: frEndTurn),
        ProviderResponse(content: @[text("followed")], finishReason: frEndTurn)])
    var followAvailable = false
    var followQueued = false
    var followRequests: seq[ProviderRequest]
    var followAgent = Agent(config: config, provider: followProvider,
      session: initSession())
    followAgent.session.addUserMessage("start")
    var followUi = consoleSink()
    followUi.generate = proc(provider: Provider,
                             request: ProviderRequest): Future[ProviderResponse] {.async.} =
      followRequests.add request
      return await provider.generateAsync(request)
    followUi.commitGenerate = proc(response: ProviderResponse, final: bool) =
      if final and not followQueued:
        followQueued = true
        followAvailable = true
    followUi.takeFollowUp = proc(): seq[string] =
      if followAvailable:
        followAvailable = false
        return @["follow"]
    followAgent.runTurn(followUi)
    check followProvider.callCount == 2
    check followRequests[1].messages[^1].content[0].text == "follow"

  test "runTurn emits normalized lifecycle events":
    var config = loadConfig()
    config.contextWindow = 1_000_000
    config.compactionEnabled = false
    var reg: ToolRegistry
    reg.register(ToolDefinition(name: "touch"), proc(input: JsonNode): Future[ToolResult] {.async.} =
      return ToolResult(output: "ok"))
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(model: "test/model", content: @[
          toolUse("call-1", "touch", %*{})], finishReason: frToolUse),
        ProviderResponse(model: "test/model", content: @[text("done")],
          finishReason: frEndTurn)
      ])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), tools: reg)
    agent.session.addUserMessage("go")
    var kinds: seq[NimletEventKind]
    var toolIds: seq[string]
    proc captureAgentEvent(event: NimletEvent) =
      kinds.add event.kind
      if event.kind == neToolCalled:
        toolIds.add event.toolId
    let ui = TurnSink(
      emit: proc(level: MsgLevel, text: string) = discard,
      render: proc() = discard,
      onChange: proc() = discard,
      commitGenerate: proc(response: ProviderResponse, final: bool) = discard,
      agentEvent: captureAgentEvent,
      toolStart: proc(call: ContentBlock) = discard,
      toolResult: proc(output: string, isError: bool) = discard,
      poll: proc() = discard,
      wasInterrupted: proc(): bool = false,
      noteInterrupted: proc() = discard,
      generate: proc(provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] =
        provider.generateAsync(request)
    )
    agent.runTurn(ui)
    check kinds == @[neRunStarted, neStepStarted, neToolCalled, neToolResult,
      neStepFinished, neStepStarted, neStepFinished, neRunFinished]
    check toolIds == @["call-1"]

  test "interrupted tool rounds get synthetic results":
    var config = loadConfig()
    config.contextWindow = 1_000_000
    config.compactionEnabled = false
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[
          text("working"),
          toolUse("one", "read", %*{"path": "one.txt"}),
          toolUse("two", "read", %*{"path": "two.txt"})
        ]),
        ProviderResponse(content: @[text("recovered")])
      ])
    var agent = Agent(config: config, provider: provider, session: initSession())
    agent.session.addUserMessage("inspect both files")
    var polls = 0
    let ui = TurnSink(
      emit: proc(level: MsgLevel, text: string) = discard,
      render: proc() = discard,
      onChange: proc() = discard,
      commitGenerate: proc(response: ProviderResponse, final: bool) = discard,
      toolStart: proc(call: ContentBlock) = discard,
      toolResult: proc(output: string, isError: bool) = discard,
      poll: proc() = (inc polls),
      wasInterrupted: proc(): bool = polls > 0,
      noteInterrupted: proc() = discard,
      generate: proc(provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] =
        provider.generateAsync(request)
    )
    agent.runTurn(ui)

    check agent.session.events.len == 4
    check agent.session.events[2].kind == sekToolResult
    check agent.session.events[3].kind == sekToolResult
    check agent.session.events[2].toolError
    check agent.session.events[3].toolError
    check agent.session.messages[2].content.len == 2
    check agent.session.messages[2].content[0].toolUseId == "one"
    check agent.session.messages[2].content[1].toolUseId == "two"

suite "slash commands":
  test "parses Codex auth commands":
    check parseSlash("/login").kind == slLogin
    check parseSlash("/login device").arg == "device"
    check parseSlash("/login browser").arg == "browser"
    check parseSlash("/login nope").kind == slError
    check parseSlash("/logout").kind == slLogout
    check parseSlash("/auth").kind == slAuth
    check parseSlash("/auth extra").kind == slError
    check commandSuggestions("/login ") ==
      @["/login browser", "/login device"]
    check commandSuggestions("/login d") == @["/login device"]
    check commandSuggestions("/login b") == @["/login browser"]

  test "suggests commands and validates arguments":
    check "/model [name]" in commandSuggestions("/mo")
    check "/models refresh" in commandSuggestions("/mo")
    check "/provider [name]" in commandSuggestions("/pr")
    check "/thinking high" in commandSuggestions("/thinking ")
    check "/web on" in commandSuggestions("/web ")
    check "/provider hyper" in commandSuggestions("/provider ")
    check "/provider hyper" in commandSuggestions("/provider hy")
    check "/provider google" in commandSuggestions("/provider go")
    check "/copy" in commandSuggestions("/co")
    check parseSlash("/copy").kind == slCopy
    check "takes no arguments" in commandError("/copy extra")
    check parseSlash("/help").kind == slHelp
    check parseSlash("/provider").kind == slProvider
    check parseSlash("/provider").arg.len == 0
    check parseSlash("/provider hyper").kind == slProvider
    check parseSlash("/provider hyper").arg == "hyper"
    check parseSlash("/provider google").arg == "google"
    check parseSlash("/yolo").kind == slYolo
    check parseSlash("/yolo on").arg == "on"
    check parseSlash("/yolo off").arg == "off"
    check "Usage: /yolo [on|off]" in commandError("/yolo maybe")
    check "Unknown provider" in commandError("/provider nope")
    check parseSlash("hello").kind == slNone
    check parseSlash("/thinking high").kind == slThinking
    check parseSlash("/thinking high").arg == "high"
    check parseSlash("/settings").kind == slSettings
    check commandError("/settings now") == "/settings takes no arguments"
    check parseSlash("/session").kind == slSession
    check parseSlash("/session rename abc123 Parser cleanup").arg ==
      "rename abc123 Parser cleanup"
    check parseSlash("/session delete abc123").arg == "delete abc123"
    check parseSlash("/session restore abc123").arg == "restore abc123"
    check parseSlash("/models refresh").kind == slModelsRefresh
    check parseSlash("/model refresh").kind == slError
    check parseSlash("/model").kind == slModel
    check parseSlash("/model").arg.len == 0
    check parseSlash("/model anthropic/claude-sonnet-4").kind == slModel
    check parseSlash("/model anthropic/claude-sonnet-4").arg == "anthropic/claude-sonnet-4"
    check parseSlash("/resume").kind == slResume
    check parseSlash("/resume").arg.len == 0
    check parseSlash("/resume abc").kind == slResume
    check parseSlash("/resume abc").arg == "abc"
    check parseSlash("/fork").kind == slFork
    check parseSlash("/fork").arg.len == 0
    check parseSlash("/fork 2").kind == slFork
    check parseSlash("/fork 2").arg == "2"
    check "Usage: /fork [message]" in commandError("/fork nope")
    check parseSlash("/name").kind == slName
    check parseSlash("/name").arg.len == 0
    check parseSlash("/name Fix parser").kind == slName
    check parseSlash("/name Fix parser").arg == "Fix parser"
    check parseSlash("/reload").kind == slReload
    check "takes no arguments" in commandError("/reload extra")
    check resumeOpensPicker("/resume")
    check not resumeOpensPicker("/resume abc")
    check forkOpensPicker("/fork")
    check not forkOpensPicker("/fork 1")
    check not resumeOpensPicker("hello")
    check commandError("/models refresh") == ""
    check "did you mean /models refresh" in commandError("/model refresh")
    check "Unknown command" in commandError("/definitely-not-a-command")
    check "Invalid thinking level" in commandError("/thinking extreme")
    check parseSlash("/web").kind == slWeb
    check parseSlash("/web").arg.len == 0
    check parseSlash("/web on").arg == "on"
    check parseSlash("/web off").arg == "off"
    check "Invalid /web value" in commandError("/web maybe")

  test "settings changes and persists queue modes":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    var config = loadConfig(root, path)
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    var prompts: seq[string]
    var ui = consoleSink()
    ui.question = proc(prompt: string,
                       options: seq[QuestionOption]): Future[QuestionAnswer] {.async.} =
      prompts.add prompt
      if prompt == "Settings":
        check options.len == 1
        return QuestionAnswer(selected: 0)
      check prompt == "Queue"
      check options.len == 4
      return QuestionAnswer(selected: 1)
    check agent.processInput("/settings", ui)
    check prompts == @["Settings", "Queue"]
    check agent.config.steeringMode == "all"
    check agent.config.followUpMode == "one-at-a-time"
    let restored = loadConfig(root, path)
    check restored.steeringMode == "all"
    check restored.followUpMode == "one-at-a-time"

  test "copy sends the latest assistant text to the interface":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    agent.session.addAssistantResponse(ProviderResponse(
      content: @[text("older")]))
    agent.session.addUserMessage("next")
    agent.session.addAssistantResponse(ProviderResponse(
      content: @[text("latest"), toolUse("call", "read", %*{})]))
    var copied = ""
    var notices: seq[string]
    var ui = consoleSink()
    ui.copyText = proc (text: string) = copied = text
    ui.emit = proc (level: MsgLevel, text: string) = notices.add text
    check agent.processInput("/copy", ui)
    check copied == "latest"
    check notices == @["Copied latest assistant response."]

  test "model picker recents then substring search":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    writeFile(cache, $(%*{
      "openrouter": {
        "models": {
          "deepseek/deepseek-v4-flash-0731": {"limit": {"context": 128000}},
          "anthropic/claude-sonnet-4": {"limit": {"context": 200000}}
        }
      },
      "anthropic": {
        "models": {
          "claude-sonnet-4-6": {"limit": {"context": 200000}}
        }
      }
    }))
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    let picker = ModelPicker(
      currentModel: "deepseek/deepseek-v4-flash-0731",
      defaultModel: "deepseek/deepseek-v4-flash-0731",
      currentProvider: "openrouter")
    let recents = commandSuggestions("/model ", picker = picker)
    check recents[0] == "/model deepseek/deepseek-v4-flash-0731"
    check "/model anthropic/claude-sonnet-4" in recents
    let short = commandSuggestions("/model d", picker = picker)
    check short == @["/model deepseek/deepseek-v4-flash-0731"]
    let hits = commandSuggestions("/model clau", picker = picker)
    check "/model anthropic/claude-sonnet-4" in hits
    check "/model claude-sonnet-4-6" notin hits
    let other = ModelPicker(
      currentModel: "claude-sonnet-4-6",
      defaultModel: "claude-sonnet-4-6",
      currentProvider: "anthropic")
    let otherHits = commandSuggestions("/model clau", picker = other)
    check "/model claude-sonnet-4-6" in otherHits
    check "/model anthropic/claude-sonnet-4" notin otherHits
    check commandSuggestionDescription("/model claude-sonnet-4-6") ==
      "anthropic  200k"
    check commandSuggestionDescription("/model deepseek/deepseek-v4-flash-0731") ==
      "openrouter  128k"

  test "catalog cache is stale when missing or old":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    check modelsDevCacheStale()
    writeFile(cache, "{}")
    check not modelsDevCacheStale()
    setLastModificationTime(cache, fromUnix(1_000))
    check modelsDevCacheStale()

  test "/model stays on the current provider":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    writeFile(cache, $(%*{
      "openrouter": {"models": {"deepseek/x": {"limit": {"context": 1000}}}},
      "openai": {"models": {"gpt-5": {"limit": {"context": 1048576}}}},
      "anthropic": {"models": {"claude-sonnet-4-6": {"limit": {"context": 200000}}}}
    }))
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    putEnv("OPENROUTER_API_KEY", "or-test")
    putEnv("OPENAI_API_KEY", "oa-test")
    putEnv("ANTHROPIC_API_KEY", "an-test")
    defer:
      delEnv("OPENROUTER_API_KEY")
      delEnv("OPENAI_API_KEY")
      delEnv("ANTHROPIC_API_KEY")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    check agent.config.provider == "openrouter"
    check agent.processInput("/model gpt-5", consoleSink())
    check agent.config.model == "gpt-5"
    check agent.config.provider == "openrouter"
    check agent.processInput("/model claude-sonnet-4-6", consoleSink())
    check agent.config.model == "claude-sonnet-4-6"
    check agent.config.provider == "openrouter"
    check agent.processInput("/provider anthropic", consoleSink())
    check agent.config.provider == "anthropic"
    check agent.config.model == "claude-sonnet-4-6"
    check agent.processInput("/model not-in-catalog", consoleSink())
    check agent.config.model == "not-in-catalog"
    check agent.config.provider == "anthropic"
    let again = loadConfig(root, root / "config.json")
    check again.model == "not-in-catalog"
    check again.provider == "anthropic"

  test "/provider switches wired providers without a catalog entry":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(root / "config.json", """{"default_provider":"openrouter"}""")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    check agent.config.provider == "openrouter"
    check agent.processInput("/provider hyper", consoleSink())
    check agent.config.provider == "hyper"
    check agent.provider.name == "hyper"
    check agent.config.endpoint == "https://hyper.charm.land/v1/chat/completions"
    check agent.processInput("/model deepseek-v4-pro", consoleSink())
    check agent.config.model == "deepseek-v4-pro"
    check agent.config.provider == "hyper"
    let again = loadConfig(root, root / "config.json")
    check again.provider == "hyper"
    check again.model == "deepseek-v4-pro"

  test "slash skill names expand and appear in suggestions":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "skills" / "review")
    writeFile(root / ".nimlet" / "skills" / "review" / "SKILL.md",
      "---\nname: review\ndescription: Structured review.\n---\n\nBe thorough.\n")
    check "/skill:review" in commandSuggestions("/skill:r", root)
    check parseSlash("/skill:review", root).kind == slSkill
    check parseSlash("/skill:review", root).skillName == "review"
    check commandError("/skill:review", root) == ""
    check commandError("/skill:review the diff", root) == ""
    check "Unknown command" in commandError("/skill:review", root / "empty")
    let expanded = expandSkill(root, parseSlash("/skill:review src/foo.nim", root))
    check "Follow the \"review\" skill." in expanded
    check "Be thorough." in expanded
    check "src/foo.nim" in expanded
    check commandSuggestionDescription("/skill:review", root) == "Structured review."

  test "prompt templates expand as bare slash commands":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "prompts")
    writeFile(root / ".nimlet" / "prompts" / "review.md",
      "---\ndescription: Review a target.\n---\nReview $ARGUMENTS carefully.\n")
    check "/review" in commandSuggestions("/re", root)
    let cmd = parseSlash("/review src/foo.nim", root)
    check cmd.kind == slPrompt
    check expandPrompt(root, cmd) == "Review src/foo.nim carefully."
    check commandSuggestionDescription("/review", root) == "Review a target."

  test "discovers portable project .agents prompts":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".agents" / "prompts")
    writeFile(root / ".agents" / "prompts" / "portable.md", "Shared $@.")
    check "/portable" in commandSuggestions("/port", root)
    check expandPrompt(root, parseSlash("/portable request", root)) ==
      "Shared request."

  test "malformed commands remain visible to validation":
    check parseSlash("/model refresh").kind == slError
    check "/models refresh" in commandSuggestions("/model refresh")

  test "resume suggestions list session ids with previews":
    let root = freshDir()
    defer: removeDir(root)
    var sess = initSession(root / "abc123.jsonl", "abc123")
    sess.workspace = root
    sess.addUserMessage("fix the parser")
    setLastModificationTime(root / "abc123.jsonl", fromUnix(1_000))
    check "/resume abc123" in commandSuggestions("/resume", root, root)
    check "/resume abc123" in commandSuggestions("/resume ", root, root)
    check "/resume abc123" in commandSuggestions("/resume ab", root, root)
    check "/resume abc123" in commandSuggestions("/resume parser", root, root)
    check commandSuggestions("/re", root, root).len > 0
    check "/resume abc123" notin commandSuggestions("/re", root, root)
    let desc = commandSuggestionDescription("/resume abc123", root, root)
    check "fix the parser" in desc
    check "/resume [query|ID]" in commandSuggestions("/resume")

  test "fork suggestions list user messages with previews":
    let root = freshDir()
    defer: removeDir(root)
    var sess = initSession(root / "current.jsonl", "current")
    sess.addUserMessage("first question")
    sess.addAssistantResponse(ProviderResponse(content: @[text("answer")]))
    sess.addUserMessage("second question")
    let choices = sess.forkChoices
    check commandSuggestions("/fork", root, root, ModelPicker(), -1,
      choices) == @["/fork 1", "/fork 2"]
    check commandSuggestions("/fork ", root, root, ModelPicker(), -1,
      choices) == @["/fork 1", "/fork 2"]
    check commandSuggestions("/fork 2", root, root, ModelPicker(), -1,
      choices) == @["/fork 2"]
    check commandSuggestionDescription("/fork 2", root, root, choices) ==
      "second question"

  test "edit hunk replaces ok body; write is all plus":
    let input = %*{"old_text": "before", "new_text": "after"}
    let plain = formatToolHunk("edit", input, false)
    check plain == @["- before", "+ after"]
    let colored = formatToolHunk("edit", input, true)
    check colored.len == 2
    check "\e[31m" in colored[0]
    check "- before" in colored[0]
    check "\e[32m" in colored[1]
    check "+ after" in colored[1]
    check formatToolHunk("write", %*{"content": "hello\nworld"}, false) ==
      @["+ 1 | hello", "+ 2 | world"]
    check formatToolHunk("edit", %*{"replacements": [
      {"old_text": "a", "new_text": "A"},
      {"old_text": "b", "new_text": "B"}
    ]}, false) == @["- a", "+ A", "- b", "+ B"]
  test "edit hunks number lines from the tool's span report":
    let outp = "OK — f.nim\nversion: abc\nlines: 12-14 > 12-13, 20-21 > 20-22"
    let spans = parseHunkSpans(outp)
    check spans == @[(12, 14, 12, 13), (20, 21, 20, 22)]
    let hunk = formatToolHunk("edit", %*{"replacements": [
        {"old_text": "a\nb\n\nc", "new_text": "a\nB"},
        {"old_text": "d\ne", "new_text": "d\ne\nf"}
      ]}, false, spans)
    check hunk == @["- 12 | a", "- 13 | b", "- 14 | ", "- 15 | c",
                    "+ 12 | a", "+ 13 | B",
                    "- 20 | d", "- 21 | e", "+ 20 | d", "+ 21 | e", "+ 22 | f"]
    check parseHunkSpans("OK — f.nim\nversion: abc").len == 0
    check parseHunkSpans("lines: nope > more").len == 0

  test "edit tool reports spans and renders numbered hunks":
    let applied = applyReplacements("one\ntwo\nthree\nfour\nfive",
      @[(("two\nthree"), ("TWO\nTHREE\nTWO"))])
    check applied.ok
    check applied.spans == @[(2, 3, 2, 4)]
    let outp = "OK — f.nim\nversion: abc\nlines: " & reportSpans(applied.spans)
    check outp.endsWith("lines: 2-3 > 2-4")
    # Full numbered rebuild, beyond the collapsed preview's 2-plus cap:
    check formatToolHunk("edit", %*{"old_text": "two\nthree",
      "new_text": "TWO\nTHREE\nTWO"}, false, applied.spans) ==
      @["- 2 | two", "- 3 | three", "+ 2 | TWO", "+ 3 | THREE", "+ 4 | TWO"]

suite "project instructions and skills":
  test "project trust gates local resources but not context files":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "local", "cat >/dev/null; echo '{\"ok\":true}'")
    createDir(root / ".nimlet" / "skills" / "local")
    writeFile(root / ".nimlet" / "skills" / "local" / "SKILL.md",
      "---\nname: local\ndescription: Local skill.\n---\n\nUse it.\n")
    writeFile(root / ".nimlet" / "SYSTEM.md", "Local system.\n")
    writeFile(root / "AGENTS.md", "Local instructions.\n")
    let trust = resolveProjectTrust(root, trustDeny)
    check trust.required
    check not trust.trusted
    check ".nimlet/tools/local/tool.json" in trust.resources
    setProjectResourcesTrusted(root, false)
    check discoverExtensions(root).tools.filterIt(it.name == "local").len == 0
    check discoverSkills(root).filterIt(it.name == "local").len == 0
    check not loadSystemPrompt(root).replacementFound
    check "Local instructions." in loadProjectInstructions(root)
    setProjectResourcesTrusted(root, true)
    clearSkillCache()
    check discoverExtensions(root).tools.filterIt(it.name == "local").len == 1
    check discoverSkills(root).filterIt(it.name == "local").len == 1
    check loadSystemPrompt(root).replacementFound

  test "trust flags parse independently from tool permissions":
    check parseCliArgs(["--approve"]).trustOverride == trustApprove
    check parseCliArgs(["--no-approve"]).trustOverride == trustDeny
    check parseCliArgs(["--approve", "--no-approve"]).error.len > 0
    check parseSlash("/trust").kind == slTrust
    check parseSlash("/trust on").arg == "on"
    check "Usage: /trust [on|off]" in commandError("/trust maybe")

  test "loads AGENTS files from repository root to workspace":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    createDir(root / "backend")
    createDir(root / "frontend")
    writeFile(root / "AGENTS.md", "Use Nim.\n")
    writeFile(root / "backend" / "AGENTS.md", "Run backend tests.\n")
    writeFile(root / "frontend" / "AGENTS.md", "Use the frontend stack.\n")

    let isolated = root / "no-global.md"
    let paths = instructionPaths(root / "backend", isolated)
    let prompt = loadProjectInstructions(root / "backend", isolated)
    check paths.len == 2
    check prompt.find("Use Nim.") < prompt.find("Run backend tests.")
    check "Use the frontend stack." notin prompt

  test "global AGENTS.md precedes the repository chain":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    writeFile(root / "AGENTS.md", "Use Nim.\n")
    let global = root / "global-agents.md"
    writeFile(global, "Be terse.\n")
    let paths = instructionPaths(root, global)
    check paths.len == 2
    check paths[0] == global
    check paths[1] == expandFilename(root) / "AGENTS.md"
    let prompt = loadProjectInstructions(root, global)
    check prompt.find("Be terse.") < prompt.find("Use Nim.")
    check "path=\"global\"" in prompt

  test "AGENTS.override.md replaces AGENTS.md at the same scope":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    createDir(root / "backend")
    writeFile(root / "AGENTS.md", "Use Nim.\n")
    writeFile(root / "backend" / "AGENTS.md", "Use the old backend rules.\n")
    writeFile(root / "backend" / "AGENTS.override.md",
      "Use the replacement backend rules.\n")

    let paths = instructionPaths(root / "backend", root / "global.md")
    let prompt = loadProjectInstructions(root / "backend", root / "global.md")
    check paths == @[expandFilename(root) / "AGENTS.md",
                     expandFilename(root) / "backend" / "AGENTS.override.md"]
    check "Use the replacement backend rules." in prompt
    check "Use the old backend rules." notin prompt

    createDir(root / "backend" / "src")
    writeFile(root / "backend" / "src" / "main.nim", "discard\n")
    check scopedInstructionPaths(root, "backend/src/main.nim") ==
      @[expandFilename(root) / "backend" / "AGENTS.override.md"]

  test "CLAUDE.md is the fallback context file":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    writeFile(root / "CLAUDE.md", "Use the Claude project rules.\n")
    check instructionPaths(root, root / "global.md") ==
      @[expandFilename(root) / "CLAUDE.md"]
    check "Use the Claude project rules." in
      loadProjectInstructions(root, root / "global.md")

  test "scoped instructions load only when a nested path is read":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    createDir(root / "backend" / "src")
    writeFile(root / "AGENTS.md", "Use Nim.\n")
    writeFile(root / "backend" / "AGENTS.md", "Run backend tests.\n")
    writeFile(root / "backend" / "src" / "main.nim", "discard\n")
    let rootPath = expandFilename(root) / "AGENTS.md"
    check scopedInstructionPaths(root, "backend/src/main.nim") ==
      @[expandFilename(root) / "backend" / "AGENTS.md"]
    let scoped = loadScopedInstructions(root, "backend/src/main.nim", @[rootPath])
    check "Run backend tests." in scoped
    check "Use Nim." notin scoped

  test "discovers skill metadata and loads bodies lazily":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "skills" / "review")
    writeFile(root / ".nimlet" / "skills" / "review" / "SKILL.md",
      "---\nname: review\ndescription: Review changes carefully.\n---\n\n" &
      "# Review\n\nKeep the secret detail.\n")

    let skills = discoverSkills(root)
    check skills.len >= 1
    var found = false
    for skill in skills:
      if skill.name == "review":
        found = true
        check skill.description == "Review changes carefully."
    check found
    let metadata = skillMetadataPrompt(root)
    check "review: Review changes carefully." in metadata
    check "Keep the secret detail." notin metadata
    let loaded = loadSkill(root, "review")
    check loaded.ok
    check "Keep the secret detail." in loaded.content
    let toolResult = invoke(makeSkillTool(root), %*{"name": "review"})
    check not toolResult.isError
    check "Keep the secret detail." in toolResult.output

  test ".nimlet skills override .agent skills with the same name":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".agent" / "skills" / "review")
    createDir(root / ".nimlet" / "skills" / "review")
    writeFile(root / ".agent" / "skills" / "review" / "SKILL.md",
      "---\nname: review\ndescription: From .agent.\n---\n")
    writeFile(root / ".nimlet" / "skills" / "review" / "SKILL.md",
      "---\nname: review\ndescription: From .nimlet.\n---\n")
    clearSkillCache()
    let skills = discoverSkills(root)
    var desc = ""
    for skill in skills:
      if skill.name == "review":
        desc = skill.description
    check desc == "From .nimlet."

  test "discovers portable project .agents skills":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".agents" / "skills" / "portable")
    writeFile(root / ".agents" / "skills" / "portable" / "SKILL.md",
      "---\nname: portable\ndescription: Shared skill.\n---\n")
    clearSkillCache()
    check "/skill:portable" in commandSuggestions("/skill:", root)

  test "agent request contains instructions and skill metadata":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".git")
    createDir(root / ".nimlet" / "skills" / "testing")
    writeFile(root / "AGENTS.md", "Always run the focused test first.\n")
    writeFile(root / ".nimlet" / "skills" / "testing" / "SKILL.md",
      "---\nname: testing\ndescription: Focused test workflow.\n---\n")
    clearSkillCache()
    var config = loadConfig(root)
    config.sessionDir = root / "sessions"
    config.contextWindow = 128_000
    let agent = initAgent(config)
    let request = agent.buildRequest()
    let system = request.system.join("\n")
    check "Always run the focused test first." in system
    check "testing: Focused test workflow." in system
    var hasSkillTool = false
    for definition in request.tools:
      if definition.name == "read_skill":
        hasSkillTool = true
    check hasSkillTool

  test "base system prompt is present without AGENTS.md":
    let root = freshDir()
    let cwd = getCurrentDir()
    defer:
      setCurrentDir(cwd)
      removeDir(root)
    setCurrentDir(root)
    var config = loadConfig(root)
    config.sessionDir = root / "sessions"
    config.contextWindow = 128_000
    let request = initAgent(config).buildRequest()
    let system = request.system.join("\n")
    check "version token" in system
    check "Do not commit" in system
    check "Project instructions" notin system

  test "SYSTEM.md replaces the base prompt and APPEND_SYSTEM.md is appended":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet")
    writeFile(root / ".nimlet" / "SYSTEM.md", "Custom system contract.\n")
    writeFile(root / ".nimlet" / "APPEND_SYSTEM.md",
      "Additional system contract.\n")
    let loaded = loadSystemPrompt(root)
    check loaded.replacementFound
    check "Custom system contract." in loaded.replacement
    check "Additional system contract." in loaded.appended
    var config = loadConfig(root)
    config.sessionDir = root / "sessions"
    config.contextWindow = 128_000
    let system = initAgent(config).buildRequest.system.join("\n")
    check "Custom system contract." in system
    check "Additional system contract." in system
    check "version token" notin system

suite "models.dev catalog":
  test "lookup uses cached api.json without network":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    let fixture = %*{
      "openrouter": {
        "models": {
          "deepseek/deepseek-v4-flash-0731": {
            "id": "deepseek/deepseek-v4-flash-0731",
            "limit": {"context": 1_000_000, "output": 384_000}
          }
        }
      },
      "anthropic": {
        "models": {
          "claude-sonnet-4-6": {
            "id": "claude-sonnet-4-6",
            "limit": {"context": 200_000, "output": 64_000}
          }
        }
      }
    }
    writeFile(cache, $fixture)
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    check lookupContextWindow("openrouter", "deepseek/deepseek-v4-flash-0731") == 1_000_000
    check lookupContextWindow("anthropic", "claude-sonnet-4-6") == 200_000
    check lookupContextWindow("anthropic", "missing-model") == 0
    var config = loadConfig()
    config.provider = "openrouter"
    config.model = "deepseek/deepseek-v4-flash-0731"
    config.contextWindow = 0
    check config.effectiveContextWindow == 1_000_000
    config.contextWindow = 42_000
    check config.effectiveContextWindow == 42_000

  test "lookup missing provider does not crash":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    writeFile(cache, "{}")
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    check lookupContextWindow("openrouter", "any/model") == 0
    var config = loadConfig()
    config.provider = "openrouter"
    config.model = "any/model"
    config.contextWindow = 0
    check config.effectiveContextWindow == guessContextWindow(config.model)

suite "compaction":
  test "findCutIndex keeps a recent user-bound window":
    var session = initSession()
    # Older turns
    for i in 1..5:
      session.addUserMessage("old user " & $i & " " & "x".repeat(400))
      session.addAssistantResponse(ProviderResponse(
        content: @[text("old ass " & $i & " " & "y".repeat(400))]))
    # Recent turn
    session.addUserMessage("recent user " & "z".repeat(100))
    session.addAssistantResponse(ProviderResponse(
      content: @[text("recent ass " & "w".repeat(100))]))
    # keepRecent small so cut lands in the older region
    let cut = findCutIndex(session, keepRecentTokens = 80)
    check cut > 0
    check cut < session.events.len
    check session.events[cut].kind == sekUser

  test "messagesForModel uses summary + kept tail":
    var session = initSession()
    session.addUserMessage("ancient")
    session.addAssistantResponse(ProviderResponse(content: @[text("old reply")]))
    session.addUserMessage("recent")
    session.addAssistantResponse(ProviderResponse(content: @[text("new reply")]))
    # Keep from event index 2 ("recent")
    session.addCompaction("## Goal\nShip it", 2, 999)
    let msgs = session.messagesForModel
    check msgs.len >= 2
    check "<summary>" in msgs[0].content[0].text
    check "Ship it" in msgs[0].content[0].text
    check msgs[1].content[0].text == "recent"
    # Raw messages() still has everything
    check session.messages.len == 4

  test "shouldCompact respects reserve headroom":
    var session = initSession()
    session.addAssistantResponse(ProviderResponse(
      usage: Usage(inputTokens: 90_000),
      content: @[text("hi")]))
    check shouldCompact(session, 100_000, 16_384)
    check not shouldCompact(session, 100_000, 5_000)

  test "context estimate includes events after reported usage":
    var session = initSession()
    let call = toolUse("tool-1", "read", %*{"path": "large.txt"})
    session.addUserMessage("read the large file")
    session.addAssistantResponse(ProviderResponse(
      usage: Usage(inputTokens: 1_000),
      content: @[call]))
    session.addToolResult(call, "x".repeat(4_000), false)
    check estimatedContextTokens(session) > 1_000

  test "request context estimate includes system instructions and tool schemas":
    var session = initSession()
    session.addUserMessage("hello")
    let request = ProviderRequest(
      system: @["instructions".repeat(400)],
      messages: session.messagesForModel,
      tools: @[ToolDefinition(name: "large_tool", description: "describe".repeat(100),
        inputSchema: %*{"type": "object", "properties": {
          "value": {"type": "string".repeat(100)}}})])
    check estimateRequestTokens(request) > estimatedContextTokens(session)
    check shouldCompact(session, request, 1_000, 0)

  test "cut starts at the user turn before a large assistant response":
    var session = initSession()
    session.addUserMessage("old request")
    session.addAssistantResponse(ProviderResponse(content: @[text("old reply")]))
    session.addUserMessage("recent request")
    session.addAssistantResponse(ProviderResponse(
      content: @[text("z".repeat(1_000))]))
    check findCutIndex(session, keepRecentTokens = 10) == 2

  test "iterative summary prompt includes previous summary":
    let prompt = buildSummaryPrompt("prev bits", "user:\nhello\n", "keep DB work")
    check "<previous-summary>" in prompt
    check "prev bits" in prompt
    check "<compaction-instructions>" in prompt
    check "keep DB work" in prompt
    check "<conversation>" in prompt

  test "compaction event round-trips in JSONL":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "c.jsonl"
    var session = initSession(path, "c1")
    session.addUserMessage("a")
    session.addUserMessage("b")
    session.addCompaction("## Goal\nX", 1, 42)
    let reloaded = initSession(path, "c1")
    check reloaded.events.len == 3
    check reloaded.events[^1].kind == sekCompaction
    check reloaded.events[^1].summary == "## Goal\nX"
    check reloaded.events[^1].firstKeptIndex == 1
    check reloaded.events[^1].tokensBefore == 42

suite "json config":
  test "queue delivery modes load and persist":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"agent":{"steering_mode":"all","follow_up_mode":"one-at-a-time"}}""")
    var config = loadConfig(root, path)
    check config.steeringMode == "all"
    check config.followUpMode == "one-at-a-time"
    config.followUpMode = "all"
    persistQueueModes(config)
    let restored = loadConfig(root, path)
    check restored.steeringMode == "all"
    check restored.followUpMode == "all"

  test "provider models survive switches and restart without losing settings":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"default_provider":"hyper","default_model":"custom-hyper",
      "providers":{"anthropic":{"endpoint":"https://example.com/messages"}}}""")
    var config = loadConfig(root, path)
    config.switchProvider("anthropic")
    check config.model == "claude-sonnet-4-6"
    check config.apiKeySource == "{env:ANTHROPIC_API_KEY}"
    config.model = "custom-claude"
    config.switchProvider("hyper")
    check config.model == "custom-hyper"
    persistModel(config)
    var restored = loadConfig(root, path)
    restored.switchProvider("anthropic")
    check restored.model == "custom-claude"
    check restored.endpoint == "https://example.com/messages"
    restored.switchProvider("anthropic")
    check restored.model == "custom-claude"
    expect ValueError: restored.switchProvider("unsupported")
    check restored.provider == "anthropic"

  test "doctor reports config layers and key presence without secrets":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"default_provider":"anthropic","providers":{"anthropic":{
      "endpoint":"https://user:password@example.com/v1/messages?key=hidden#fragment"}}}""")
    writeFile(root / "auth.json", """{"anthropic":{"type":"api_key","key":"secret-value"}}""")
    let report = doctorReport(loadConfig(root, path, authPath = root / "auth.json"))
    check "auth " & (root / "auth.json") & " (api_key) set" in report
    check path in report
    check "https://example.com/v1/messages" in report
    for secret in ["secret-value", "password", "hidden", "fragment"]:
      check secret notin report
    check parseSlash("/doctor").kind == slDoctor
    check parseSlash("/doctor test").arg == "test"
    check parseSlash("/doctor invalid").kind == slError
    check parseSlash("/doctor test extra").kind == slError

  test "API keys resolve from auth.json and environment":
    let root = freshDir()
    defer: removeDir(root)
    putEnv("OPENAI_API_KEY", "from-env")
    defer: delEnv("OPENAI_API_KEY")
    let path = root / "config.json"
    writeFile(path, """{"default_provider":"openai"}""")
    check loadConfig(root, path, authPath = root / "auth.json").apiKey == "from-env"
    writeFile(root / "auth.json", """{"openai":{"type":"api_key","key":"from-auth"}}""")
    let config = loadConfig(root, path, authPath = root / "auth.json")
    check config.apiKey == "from-auth"
    check config.apiKeyDescription == "auth " & (root / "auth.json") & " (api_key)"

  test "doctor test uses an isolated request and leaves session and config untouched":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    let before = agent.session.events.len
    var calls = 0
    var ui = consoleSink()
    ui.generate = proc (provider: Provider,
        request: ProviderRequest): Future[ProviderResponse] {.async.} =
      inc calls
      check request.tools.len == 0
      check request.messages.len == 1
      check request.maxTokens == 64
      return ProviderResponse(model: "tested", finishReason: frEndTurn)
    check agent.processInput("/doctor", ui)
    check calls == 0
    check agent.processInput("/doctor test", ui)
    check calls == 1
    check agent.session.events.len == before
    check not fileExists(config.writePath)

  test "project overlays global and becomes the write target":
    let root = freshDir()
    defer: removeDir(root)
    let globalFile = root / "global.json"
    createDir(root / ".nimlet")
    writeFile(globalFile, """{"default_model":"from-global","agent":{"max_tokens":1}}""")
    writeFile(root / ".nimlet" / "config.json", """{"default_model":"from-project"}""")
    let config = loadConfig(root, "", globalFile)
    check config.model == "from-project"
    check config.maxTokens == 1
    check sameFile(config.writePath, root / ".nimlet" / "config.json")

  test "persist patches model keys without dropping others":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"default_model":"old","agent":{"max_tokens":7}}""")
    var config = loadConfig(root, path)
    check config.maxTokens == 7
    config.model = "picked/id"
    config.provider = "anthropic"
    persistModel(config)
    let doc = parseJson(readFile(path))
    check doc["default_model"].getStr == "picked/id"
    check doc["default_provider"].getStr == "anthropic"
    check doc["agent"]["max_tokens"].getInt == 7

  test "persist patches thinking without dropping other agent keys":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"agent": {"max_tokens": 7, "thinking": "low"}}""")
    var config = loadConfig(root, path)
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    check agent.setThinking("high") == "high"
    let doc = parseJson(readFile(path))
    check doc["agent"]["thinking"].getStr == "high"
    check doc["agent"]["max_tokens"].getInt == 7
    let again = loadConfig(root, path)
    check again.thinking == "high"

  test "persist patches web_search and buildRequest gates on provider":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, """{"default_provider":"openrouter","agent":{"max_tokens":7}}""")
    var config = loadConfig(root, path)
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    check not agent.config.webSearch
    check not webSearchActive(agent.config)
    check agent.setWebSearch(true) == "on (no effect until openai, anthropic, or google)"
    var hosted = false
    for t in agent.buildRequest().tools:
      if t.hosted == "web_search": hosted = true
    check not hosted
    let doc = parseJson(readFile(path))
    check doc["agent"]["web_search"].getBool
    check doc["agent"]["max_tokens"].getInt == 7
    agent.applyProvider("anthropic", persist = false)
    check webSearchActive(agent.config)
    hosted = false
    var sawHint = false
    let req = agent.buildRequest()
    for t in req.tools:
      if t.hosted == "web_search": hosted = true
    for s in req.system:
      if "web_search" in s: sawHint = true
    check hosted
    check sawHint
    agent.applyProvider("google", persist = false)
    check webSearchActive(agent.config)
    check agent.buildRequest().tools[^1].hosted == "web_search"
    check agent.setWebSearch(false) == "off"
    check "web_search" notin readFile(path)

  test "persist creates global when no project config exists":
    let root = freshDir()
    defer: removeDir(root)
    let globalFile = root / "global.json"
    var config = loadConfig(root, "", globalFile)
    check config.writePath == globalFile
    config.model = "picked/id"
    config.provider = "openrouter"
    persistModel(config)
    check fileExists(globalFile)
    let doc = parseJson(readFile(globalFile))
    check doc["default_model"].getStr == "picked/id"
    check doc["default_provider"].getStr == "openrouter"

  test "persist creates project config when project config directory exists":
    let root = freshDir()
    defer: removeDir(root)
    let globalFile = root / "global.json"
    createDir(root / ".nimlet")
    writeFile(globalFile, """{"default_model":"global/model"}""")
    var config = loadConfig(root, "", globalFile)
    config.model = "hyper/model"
    config.provider = "hyper"
    persistModel(config)
    let projectFile = root / ".nimlet" / "config.json"
    check fileExists(projectFile)
    let doc = parseJson(readFile(projectFile))
    check doc["default_model"].getStr == "hyper/model"
    check doc["default_provider"].getStr == "hyper"
    check parseJson(readFile(globalFile))["default_model"].getStr == "global/model"

suite "thinking / reasoning options":
  test "modern Claude uses adaptive effort while legacy budgets are counted once":
    var config = AgentConfig(provider: "anthropic", model: "claude-sonnet-4-6",
      thinking: "xhigh", maxTokens: 4096)
    let options = providerOptions(config)
    check options["thinking"]["type"].getStr == "adaptive"
    check options["output_config"]["effort"].getStr == "max"
    check thinkingStatus(config) == "max"
    check thinkingChoices(config.provider, config.model) == @["none", "low", "medium", "high", "max"]
    check buildAnthropicBody(ProviderRequest(model: config.model,
      maxTokens: config.maxTokens, options: options))["max_tokens"].getInt == 4096
    config.thinking = "none"
    check providerOptions(config)["thinking"]["type"].getStr == "disabled"
    check thinkingStatus(config) == "off"
    let legacy = anthropicThinkingOptions("claude-sonnet-4-5", "high")
    let body = buildAnthropicBody(ProviderRequest(model: "claude-sonnet-4-5",
      maxTokens: 4096, options: legacy))
    check body["max_tokens"].getInt == 20096

  test "openrouter options carry effort":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    var config = loadConfig()
    config.provider = "openrouter"
    config.thinking = "high"
    let opts = providerOptions(config)
    check opts["reasoning"]["effort"].getStr == "high"

  test "anthropic options map to budget tokens":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    var config = loadConfig()
    config.provider = "anthropic"
    config.thinking = "medium"
    let opts = providerOptions(config)
    check opts["thinking"]["type"].getStr == "enabled"
    check opts["thinking"]["budget_tokens"].getInt == 8000

  test "none omits anthropic thinking block":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    var config = loadConfig()
    config.provider = "anthropic"
    config.thinking = "none"
    let opts = providerOptions(config)
    check "thinking" notin opts

  test "agent buildRequest includes reasoning":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(root / "config.json", """{"agent": {"thinking": "low"}}""")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.provider = "openrouter"
    var agent = initAgent(config)
    let req = agent.buildRequest()
    check req.options["reasoning"]["effort"].getStr == "low"
    check agent.setThinking("high") == "high"
    check agent.buildRequest().options["reasoning"]["effort"].getStr == "high"

  test "snap effort to nearest catalog rung":
    check snapToEfforts("medium", ["high", "xhigh"]) == "high"
    check snapToEfforts("max", ["high", "xhigh"]) == "xhigh"
    check snapToEfforts("high", ["high", "xhigh"]) == "high"
    check snapToEfforts("none", ["high", "xhigh"]) == ""
    check snapToEfforts("low", ["low", "high", "max"]) == "low"
    check snapToEfforts("medium", ["low", "high"]) == "high"

  test "catalog caps snap, toggle, and hide unsupported":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", $(%*{
      "openrouter": {
        "models": {
          "flash": {
            "reasoning": true,
            "reasoning_options": [{"type": "effort", "values": ["high", "xhigh"]}],
            "limit": {"context": 1000}
          },
          "toggle-only": {
            "reasoning": true,
            "reasoning_options": [{"type": "toggle"}],
            "limit": {"context": 1000}
          },
          "dumb": {"limit": {"context": 1000}}
        }
      }
    }))
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    var config = loadConfig()
    config.provider = "openrouter"
    config.model = "flash"
    config.thinking = "medium"
    check providerOptions(config)["reasoning"]["effort"].getStr == "high"
    check thinkingStatus(config) == "high"
    check thinkingChoices("openrouter", "flash") == @["none", "high", "xhigh"]
    config.thinking = "none"
    check "reasoning" notin providerOptions(config)
    check thinkingStatus(config) == "off"
    config.model = "toggle-only"
    config.thinking = "medium"
    check providerOptions(config)["reasoning"]["enabled"].getBool
    check thinkingStatus(config) == "on"
    check thinkingChoices("openrouter", "toggle-only") == @["none", "high"]
    config.thinking = "none"
    check "reasoning" notin providerOptions(config)
    config.model = "dumb"
    config.thinking = "high"
    check providerOptions(config).len == 0
    check thinkingStatus(config) == ""
    check thinkingChoices("openrouter", "dumb").len == 0
    config.thinking = "high"
    var agent = Agent(config: config)
    check "think:" notin agent.statusFooter

suite "markdown rendering":
  test "plain mode strips punctuation":
    let rendered = renderMarkdown("## Heading\n\n**bold** and *italic* and `code`", false)
    check "Heading" in rendered
    check "bold" in rendered
    check "italic" in rendered
    check "code" in rendered
    check "\x1b" notin rendered

  test "colored mode adds ANSI codes":
    let rendered = renderMarkdown("**bold**", true)
    check "\x1b[1m" in rendered
    check "bold" in rendered

  test "bold italic combined":
    let plain = renderMarkdown("***both***", false)
    check "both" in plain
    check "*" notin plain
    let colored = renderMarkdown("***both***", true)
    check "\x1b[1;3m" in colored
    check "both" in colored

  test "fenced code blocks preserve content":
    let source = "```nim\nlet x = 42\n```"
    let plain = renderMarkdown(source, false)
    check "let x = 42" in plain
    let colored = renderMarkdown(source, true)
    check "let x = 42" in colored
    check "\x1b[2m" in colored

  test "links render as text with url":
    let plain = renderMarkdown("[docs](https://example.com)", false)
    check "docs" in plain
    check "https://example.com" in plain

  test "lists get bullet markers":
    let plain = renderMarkdown("- one\n- two", false)
    check "• one" in plain
    check "• two" in plain

  test "tables render with box characters":
    let source = "| Name | Value |\n|------|-------|\n| foo  | 1     |\n| bar  | 2     |"
    let plain = renderMarkdown(source, false)
    check "Name" in plain
    check "Value" in plain
    check "foo" in plain
    check "bar" in plain
    check "┌" in plain
    check "┬" in plain
    check "┼" in plain
    check "┴" in plain
    check "│" in plain

  test "colored tables have header emphasis":
    let source = "| H1 | H2 |\n|----|----|\n| a  | b  |"
    let colored = renderMarkdown(source, true)
    check "\x1b[1;34m" in colored

suite "streaming markdown":
  test "markdown rerenders as streamed syntax completes":
    check renderMarkdown("**bold", false) == "**bold"
    check renderMarkdown("**bold**", false) == "bold"
    check renderMarkdown("- one\n- two", false).splitLines == @["• one", "• two"]

suite "composer and cost":
  test "paste normalizes CR LF to LF":
    check normalizePasteText("a\r\nb\rc") == "a\nb\nc"
    check normalizePasteText("plain") == "plain"

  test "Ctrl/Cmd+V CSI sequences count as paste":
    check isModifiedPaste("27;5;118~")
    check isModifiedPaste("27;9;118~")
    check isModifiedPaste("27;6;86~")
    check isModifiedPaste("118;5u")
    check isModifiedPaste("118;9u")
    check not isModifiedPaste("27;2;13~")
    check not isModifiedPaste("27;5;99~")
    check not isModifiedPaste("200~")

  test "usage cost uses catalog prices":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    writeFile(cache, $(%*{
      "openrouter": {
        "models": {
          "priced/model": {
            "limit": {"context": 1000},
            "cost": {"input": 1.0, "output": 2.0, "cache_read": 0.1}
          }
        }
      }
    }))
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    let usage = Usage(inputTokens: 1_000_000, outputTokens: 1_000_000)
    check estimateUsageCost("openrouter", "priced/model", usage) == 3.0
    check formatUsageCost("openrouter", "priced/model", usage) == "$3.00"
    let cached = Usage(inputTokens: 1_000_000, outputTokens: 0,
      cacheReadTokens: 500_000, cacheReported: true)
    # uncached 500k * $1 + cache 500k * $0.1 = $0.55
    check abs(estimateUsageCost("openrouter", "priced/model", cached) - 0.55) < 0.0001
    check formatUsageCost("openrouter", "missing", usage).len == 0

  test "status footer shows total session cost":
    let root = freshDir()
    defer: removeDir(root)
    let cache = root / "models-dev.json"
    writeFile(cache, $(%*{
      "openrouter": {
        "models": {
          "priced/model": {
            "limit": {"context": 1000},
            "cost": {"input": 1.0, "output": 0.0}
          }
        }
      }
    }))
    setModelsDevCachePath(cache)
    defer: setModelsDevCachePath("")
    var session = initSession()
    for i in 0 ..< 2:
      session.addAssistantResponse(ProviderResponse(model: "priced/model",
        usage: Usage(inputTokens: 1_000_000, outputTokens: 0),
        content: @[text("hi")]), provider = "openrouter",
        requestedModel = "priced/model")
    var agent = Agent(config: AgentConfig(provider: "openrouter",
      model: "priced/model"), session: session)
    # $1 per response, so the footer must show $2.00 rather than the latest $1.00.
    check "$2.00" in agent.statusFooter
    var output = ""
    var ui = consoleSink()
    ui.emit = proc (level: MsgLevel, value: string) = output.add value
    check agent.processInput("/stats", ui)
    check "Latest cost: $1.00" in output
    check "Session cost: $2.00" in output

suite "editor and shell shortcuts":
  test "composer supports word deletion, yank, and undo":
    let input = newInput()
    input.setText("one two")
    check input.handle(UiEvent(kind: uiKey, key: keyCtrlW)).handled
    check input.text == "one "
    check input.yankText == "two"
    discard input.handle(UiEvent(kind: uiKey, key: keyCtrlY))
    check input.text == "one two"
    discard input.handle(UiEvent(kind: uiKey, key: keyCtrlZ))
    check input.text == "one "
    input.setText("one two")
    input.cursor = 0
    discard input.handle(UiEvent(kind: uiKey, key: keyAltD))
    check input.text == " two"
    check input.yankText == "one"
    discard input.handle(UiEvent(kind: uiKey, key: keyCtrlY))
    check input.text == "one two"

  test "alt-d decodes as a word deletion shortcut":
    var decoder: InputDecoder
    decoder.feed("\ed")
    let event = decoder.nextEvent(100)
    check event.key == keyAltD

  test "keybindings load and remap editor actions":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(path, $(%*{"keybindings": {
      "app.editor.external": "ctrl+q",
      "tui.editor.deleteWordBackward": ["ctrl+r"]
    }}))
    let config = loadConfig(root, path)
    let screen = newNimtermScreen("test", root, root / "sessions",
      ModelPicker(), keybindings = config.keybindings)
    check parseKeySpec("ctrl+q") == keyCtrlQ
    check screen.handle(UiEvent(kind: uiKey, key: keyCtrlQ)).action.kind ==
      "editor"
    check not screen.handle(UiEvent(kind: uiKey, key: keyCtrlG)).handled
    screen.composer.setText("one two")
    discard screen.handle(UiEvent(kind: uiKey, key: keyCtrlR))
    check screen.composer.text == "one "

  test "alt-j inserts a newline and can be remapped or disabled":
    let root = freshDir()
    defer: removeDir(root)
    let defaultScreen = newNimtermScreen("test", root, root / "sessions",
      ModelPicker())
    discard defaultScreen.handle(UiEvent(kind: uiKey, key: keyAltJ))
    check defaultScreen.composer.text == "\n"
    let path = root / "config.json"
    writeFile(path, $(%*{"keybindings": {
      "tui.input.newLine": ["ctrl+o"]
    }}))
    let custom = newNimtermScreen("test", root, root / "sessions",
      ModelPicker(), keybindings = loadConfig(root, path).keybindings)
    # Remapping newLine turns the default shift+enter and alt+j keys off.
    check not custom.handle(UiEvent(kind: uiKey, key: keyAltJ)).handled
    check not custom.handle(UiEvent(kind: uiKey, key: keyShiftEnter)).handled
    check custom.composer.text == ""

  test "external editor returns the edited composer text":
    let root = freshDir()
    defer: removeDir(root)
    let editor = root / "editor"
    writeFile(editor, "#!/bin/sh\nprintf 'edited prompt' > \"$1\"\n")
    inclFilePermissions(editor, {fpUserExec, fpGroupExec, fpOthersExec})
    let hadVisual = existsEnv("VISUAL")
    let oldVisual = getEnv("VISUAL")
    putEnv("VISUAL", editor)
    defer:
      if hadVisual: putEnv("VISUAL", oldVisual)
      else: delEnv("VISUAL")
    let result = editTextExternally("draft")
    check result.ok
    check result.text == "edited prompt"

  test "shell shortcuts distinguish visible and model-bound commands":
    let visible = parseShellShortcut("!printf visible")
    check visible.found
    check visible.sendToModel
    check visible.command == "printf visible"
    let hidden = parseShellShortcut("!!printf hidden")
    check hidden.found
    check not hidden.sendToModel
    check hidden.command == "printf hidden"
    let root = freshDir()
    defer: removeDir(root)
    let ran = runShellCommand(root, "printf shell-output")
    check ran.exitCode == 0
    check ran.output == "shell-output"

  test "TUI shell shortcuts route output according to their prefix":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(responses: @[
      ProviderResponse(content: @[text("ack")], finishReason: frEndTurn)])
    let screen = newNimtermScreen("test", root, config.sessionDir,
      ModelPicker())
    var app = termapp.newApp(nil, screen)
    let controller = newNimletController(screen, addr app, addr agent)
    controller.handleAction(app, UiAction(sourceId: "screen", kind: "submit",
      value: "!printf model-output"))
    for _ in 0 .. 50: discard app.step()
    check agent.session.events.len >= 1
    check "model-output" in agent.session.events[0].message.content[0].text
    controller.handleAction(app, UiAction(sourceId: "screen", kind: "submit",
      value: "!!printf hidden-output"))
    check screen.transcript.transcript.items[^1].text == "hidden-output"

suite "file mentions":
  test "mentionAt finds @path and ignores emails":
    check mentionAt("user@host", 5).active == false
    check mentionAt("see @src/foo.nim", "see @src/foo.nim".len).query == "src/foo.nim"
    check mentionAt("@", 1).active
    check mentionAt("@", 1).query.len == 0
    check mentionAt("look at @src", 12).query == "src"
    check mentionAt("nope", 2).active == false
    check findMentions("see @a and\n@b and @a") == @["a", "b"]

  test "applyMention splices the token":
    let ins = applyMention("fix @src", 8, "@src/agent.nim")
    check ins.text == "fix @src/agent.nim "
    check ins.cursor == ins.text.len

  test "suggestions and attach stay inside the workspace":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / "src")
    writeFile(root / "src" / "agent.nim", "proc foo = discard\n")
    writeFile(root / "README.md", "hello\n")
    writeFile(root / "src" / "bin.dat", "a\0b")
    let hits = commandSuggestions("see @ag", root, cursor = 7)
    check "@src/agent.nim" in hits
    check commandSuggestionDescription("@src/agent.nim") == "file"
    let expanded = expandUserContent(root, "look at @src/agent.nim")[0].text
    check "look at @src/agent.nim" in expanded
    check "<file path=\"src/agent.nim\">" in expanded
    check "proc foo" in expanded
    check expandUserContent(root, "look at @missing.nim")[0].text ==
      "look at @missing.nim"
    check "<file" notin expandUserContent(root, "see @src/bin.dat")[0].text
    check expandUserContent(root, "user@host")[0].text == "user@host"

  test "folder mentions appear in suggestions and attach a listing":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / "examples")
    writeFile(root / "examples" / "a.nim", "echo 1\n")
    writeFile(root / "examples" / "b.nim", "echo 2\n")
    let hits = commandSuggestions("run @exam", root, cursor = 8)
    check "@examples/" in hits
    check commandSuggestionDescription("@examples/") == "folder"
    let ins = applyMention("run @exam", 8, "@examples/")
    check ins.text == "run @examples/"
    check commandSuggestions("run @examples/", root, cursor = ins.text.len) ==
      @["@examples/a.nim", "@examples/b.nim"]
    let expanded = expandUserContent(root, "run @examples")[0].text
    check "run @examples" in expanded
    check "<folder path=\"examples\">" in expanded
    check "examples/a.nim" in expanded
    check expandUserContent(root, "run @missing/")[0].text == "run @missing/"

  test "workspace file list sees files written after the first call":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "a.txt", "a")
    check "a.txt" in listWorkspaceFiles(root)
    writeFile(root / "b.txt", "b")
    check "b.txt" in listWorkspaceFiles(root)

suite "transcript tool summaries":
  test "hides read source while retaining search context":
    let read = transcriptToolOutput("read", %*{"path": "src/main.nim"},
      "path: src/main.nim\nversion: 10:20\nlines: 1-2 of 2\n\n1 | secret\n2 | source")
    check "path: src/main.nim" in read
    check "source lines hidden from transcript" in read
    check "secret" notin read

    let grep = transcriptToolOutput("grep", %*{
      "pattern": "proc\\s+main", "glob": "**/*.nim"},
      "src/main.nim:1:proc main\nsrc/other.nim:2:proc main")
    check "pattern: proc\\s+main" in grep
    check "glob: **/*.nim" in grep
    check "src/main.nim:1:proc main" in grep

suite "images":
  const png = "\x89PNG\r\n\x1a\n" & "fake-png"
  const jpeg = "\xFF\xD8\xFF\xE0" & "fake-jpeg"
  const gif = "GIF89a" & "fake"
  const webp = "RIFF\x00\x00\x00\x00WEBP" & "fake"

  test "sniffs common image magic and rejects everything else":
    check sniffImageMime(png) == "image/png"
    check sniffImageMime(jpeg) == "image/jpeg"
    check sniffImageMime(gif) == "image/gif"
    check sniffImageMime(webp) == "image/webp"
    check sniffImageMime("not an image").len == 0
    check sniffImageMime("a\0b").len == 0
    let payload = imagePayload(png)
    check payload.ok
    check payload.mime == "image/png"
    check payload.data.len > 0
    var huge = png
    huge.add 'x'.repeat(MaxImageBytes)
    let over = imagePayload(huge)
    check over.mime == "image/png"
    check not over.ok
    check "too large" in over.err

  test "@mention and read attach images as blocks, not text":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "shot.jpg", jpeg)
    writeFile(root / "notes.txt", "hello\n")
    check expandUserContent(root, "see @shot.jpg")[0].text == "see @shot.jpg"
    let blocks = expandUserContent(root, "see @shot.jpg and @notes.txt")
    check blocks.len == 2
    check blocks[0].kind == ckText
    check "see @shot.jpg" in blocks[0].text
    check "<file path=\"notes.txt\">" in blocks[0].text
    check "hello" in blocks[0].text
    check blocks[1].kind == ckImage
    check blocks[1].mimeType == "image/jpeg"
    check blocks[1].path == "shot.jpg"
    check blocks[1].data.len == 0
    let got = invoke(makeReadTool(initWorkspace(root)), %*{"path": "shot.jpg"})
    check not got.isError
    check "image/jpeg" in got.output
    check got.images.len == 1
    check got.images[0].mimeType == "image/jpeg"
    check got.images[0].path == "shot.jpg"
    check got.images[0].data.len == 0
    check got.output.count("\xFF") == 0

  test "session round-trips image blocks and tool images":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "img.jsonl"
    var sess = initSession(path, "img")
    sess.addUserMessage(@[text("look"), image("image/png", "QUJD")])
    sess.addToolResult(toolUse("1", "read", %*{"path": "shot.jpg"}),
      "path: shot.jpg\n", false, @[ImageContent(mimeType: "image/jpeg", data: "QUJD")])
    let loaded = initSession(path, "img")
    check loaded.events[0].message.content.len == 2
    check loaded.events[0].message.content[1].kind == ckImage
    check loaded.events[0].message.content[1].data == "QUJD"
    check loaded.events[1].toolImages.len == 1
    check loaded.events[1].toolImages[0].mimeType == "image/jpeg"
    let msgs = loaded.messagesForModel
    var found = false
    for m in msgs:
      for c in m.content:
        if c.kind == ckToolResult:
          found = true
          check c.images.len == 1
    check found

  test "session round-trips file, source, and hosted tool blocks":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "src.jsonl"
    var sess = initSession(path, "src")
    sess.addUserMessage(@[text("see"), file("application/pdf", "QUJD",
      filename = "spec.pdf")])
    sess.addAssistantResponse(ProviderResponse(content: @[
      toolUse("s1", "web_search", %*{"query": "nim"}, hosted = "web_search"),
      toolResult("s1", """[{"url":"https://nim-lang.org"}]""", hosted = "web_search"),
      text("Nim"),
      source("https://nim-lang.org", "Nim", raw = %*{"encrypted_index": "idx"})
    ]))
    let loaded = initSession(path, "src")
    let user = loaded.events[0].message.content
    check user[1].kind == ckFile
    check user[1].file.filename == "spec.pdf"
    check user[1].file.data == "QUJD"
    let asst = loaded.events[1].message.content
    check asst[0].hosted == "web_search"
    check asst[1].hosted == "web_search"
    check asst[3].kind == ckSource
    check asst[3].source.raw["encrypted_index"].getStr == "idx"

  test "dropImages and catalog: known text-only strips, unknown keeps":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "models-dev.json", $(%*{
      "openrouter": {"models": {
        "text-only": {
          "limit": {"context": 1000},
          "modalities": {"input": ["text"]}
        },
        "vision": {
          "limit": {"context": 1000},
          "modalities": {"input": ["text", "image"]}
        }
      }}
    }))
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    check not lookupAcceptsImages("openrouter", "text-only")
    check lookupAcceptsImages("openrouter", "vision")
    check lookupAcceptsImages("openrouter", "mystery-model")
    let kept = @[userMessage(@[text("hi"), image("image/png", "QUJD")])]
    let dropped = dropImages(kept)
    check dropped[0].content.len == 2
    check dropped[0].content[1].kind == ckText
    check imageOmitted in dropped[0].content[1].text
    var config = loadConfig(root)
    config.sessionDir = root / "sessions"
    config.provider = "openrouter"
    config.model = "text-only"
    var agent = initAgent(config)
    agent.session.addUserMessage(@[text("hi"), image("image/png", "QUJD")])
    let req = agent.buildRequest()
    check req.messages[0].content[1].kind == ckText
    check imageOmitted in req.messages[0].content[1].text
    config.model = "vision"
    agent = initAgent(config)
    agent.session.addUserMessage(@[text("hi"), image("image/png", "QUJD")])
    let vis = agent.buildRequest()
    check vis.messages[0].content[1].kind == ckImage

  test "providers encode Pi image blocks; compaction omits bytes":
    check anthropicImageBlock("image/png", "QUJD")["source"]["data"].getStr == "QUJD"
    check "data:image/png;base64,QUJD" in $openAiImagePart("image/png", "QUJD")
    let body = buildBody(ProviderRequest(
      model: "vision",
      messages: @[userMessage(@[text("see"), image("image/png", "QUJD")])],
      maxTokens: 10), stream = false)
    let content = body["messages"][0]["content"]
    check content.kind == JArray
    check content.len == 2
    check content[1]["type"].getStr == "image_url"
    check "cache_control" in content[1]
    let sysBody = buildBody(ProviderRequest(
      model: "vision",
      system: @["stable prefix", "skills"],
      messages: @[userMessage("hi")],
      tools: @[ToolDefinition(name: "read", description: "d",
        inputSchema: %*{"type": "object"})],
      maxTokens: 10), stream = false)
    check sysBody["messages"][0]["role"].getStr == "system"
    let sysParts = sysBody["messages"][0]["content"]
    check sysParts.kind == JArray
    check sysParts.len == 2
    check "cache_control" in sysParts[1]
    check "cache_control" in sysBody["tools"][0]
    let toolBody = buildBody(ProviderRequest(
      model: "vision",
      messages: @[
        Message(role: roleAssistant, content: @[
          toolUse("1", "read", %*{"path": "a.png"})]),
        Message(role: roleUser, content: @[
          toolResult("1", "path: a.png", false,
            @[ImageContent(mimeType: "image/png", data: "QUJD")])])
      ], maxTokens: 10), stream = false)
    var sawTool = false
    var sawImageUser = false
    for m in toolBody["messages"]:
      if m["role"].getStr == "tool":
        sawTool = true
        check m["content"].getStr == "path: a.png"
      elif m["role"].getStr == "user" and m["content"].kind == JArray:
        for part in m["content"]:
          if part["type"].getStr == "image_url":
            sawImageUser = true
    check sawTool
    check sawImageUser
    var sess = initSession()
    sess.addUserMessage(@[text("see"), image("image/png", "QUJD" & "x".repeat(200))])
    let dumped = serializeRange(sess, 0, sess.events.len)
    check "[image/png]" in dumped
    check "QUJDx" notin dumped
    check imageTokenFallback == estimateEventTokens(sess.events[0]) -
      estimateTokens("see")

  test "clipboard ingest writes clips and path paste becomes @mention":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "shot.png", png)
    writeFile(root / "notes.txt", "hello\n")
    let ws = initWorkspace(root)
    let saved = saveWorkspaceImage(ws, png)
    check saved.ok
    check saved.mention.startsWith("@.nimlet/clips/")
    check fileExists(root / saved.mention[1 .. ^1])
    let blocks = expandUserContent(root, "see " & saved.mention)
    check blocks.len == 2
    check blocks[1].kind == ckImage
    check ingestPastedPath(ws, root / "shot.png") == "@shot.png"
    check ingestPastedPath(ws, "\"" & root / "shot.png" & "\"") == "@shot.png"
    check ingestPastedPath(ws, "file://" & root / "shot.png") == "@shot.png"
    check ingestPastedPath(ws, root / "notes.txt").len == 0
    check ingestPastedPath(ws, "hello").len == 0
    check ingestPastedPath(ws, "shot.png\nand more").len == 0
    let outside = getTempDir() / ("nimlet-out-" & $getCurrentProcessId() & ".jpg")
    writeFile(outside, jpeg)
    defer: removeFile(outside)
    let copied = ingestPastedPath(ws, outside)
    check copied.startsWith("@.nimlet/clips/")
    check copied.endsWith(".jpg")

  test "pasted image paths insert workspace mentions":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "shot.png", png)
    let screen = newNimtermScreen("test", root, root / "sessions",
      ModelPicker())
    let response = screen.handle(UiEvent(kind: uiKey, key: keyChar,
      text: root / "shot.png"))
    check response.handled
    check screen.composer.text == "@shot.png"
    screen.composer.text = ""
    screen.composer.cursor = 0
    for ch in root / "shot.png":
      discard screen.handle(UiEvent(kind: uiKey, key: keyChar, text: $ch))
    check screen.composer.text == "@shot.png"

  test "PNG tile estimate and path-only session hydrate":
    proc be32(n: int): string =
      result = newString(4)
      result[0] = char((n shr 24) and 255)
      result[1] = char((n shr 16) and 255)
      result[2] = char((n shr 8) and 255)
      result[3] = char(n and 255)
    let header = "\x89PNG\r\n\x1a\n" & be32(13) & "IHDR" & be32(1568) & be32(1568)
    check imageDimensions(header) == (1568, 1568)
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "tile.png", header)
    check imageTokenEstimate(ImageContent(mimeType: "image/png",
      path: root / "tile.png")) == 1600
    check imageTokenEstimate(ImageContent(mimeType: "image/png",
      path: "tile.png"), root) == 1600
    let path = root / "img.jsonl"
    var sess = initSession(path, "img2")
    sess.workspace = root
    sess.addUserMessage(@[text("look"), image("image/png", "", "tile.png")])
    let raw = readFile(path)
    check "tile.png" in raw
    check "\"data\"" notin raw
    let loaded = initSession(path, "img2")
    check loaded.events[0].message.content[1].path == "tile.png"
    check loaded.events[0].message.content[1].data.len == 0
    writeFile(root / "models-dev.json", $(%*{
      "openrouter": {"models": {
        "vision": {
          "limit": {"context": 1000},
          "modalities": {"input": ["text", "image"]}
        }
      }}
    }))
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    var config = loadConfig(root)
    config.sessionDir = root / "sessions"
    config.provider = "openrouter"
    config.model = "vision"
    config.workspace = root
    var agent = initAgent(config)
    agent.session.addUserMessage(@[text("look"), image("image/png", "", "tile.png")])
    let req = agent.buildRequest()
    check req.messages[0].content[1].kind == ckImage
    check req.messages[0].content[1].data.len > 0
    check req.messages[0].content[1].path == "tile.png"

suite "external tools":
  proc findExt(tools: seq[ExtensionTool], name: string): ExtensionTool =
    for t in tools:
      if t.name == name:
        return t
    raise newException(ValueError, "extension not found: " & name)

  test "valid manifest registers; broken tool.json warns and is skipped":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "echo_ok", "cat >/dev/null\necho '{\"ok\":true}'")
    createDir(root / ".nimlet" / "tools" / "broken")
    writeFile(root / ".nimlet" / "tools" / "broken" / "tool.json", "{not json")
    var reg: ToolRegistry
    let warnings = reg.registerExtensions(root)
    var hasBroken = false
    for w in warnings:
      if "broken" in w:
        hasBroken = true
    check hasBroken
    var names: seq[string] = @[]
    for d in reg.definitions:
      names.add d.name
    check "echo_ok" in names
    check "broken" notin names

  test "only explicitly read-only external tools enter plan mode":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "safe", "cat >/dev/null\necho '{\"safe\":true}'",
      capabilities = @["read"])
    writeExt(root, ".nimlet", "unsafe", "cat >/dev/null\necho '{\"safe\":false}'")
    var plan: ToolRegistry
    var act: ToolRegistry
    discard act.registerExtensions(root, plan = addr plan)
    var planNames: seq[string]
    for definition in plan.definitions:
      planNames.add definition.name
    check "safe" in planNames
    check "unsafe" notin planNames

  test ".nimlet tools override .agent tools with the same name":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".agent", "shared", "cat >/dev/null\necho '{\"from\":\".agent\"}'")
    writeExt(root, ".nimlet", "shared", "cat >/dev/null\necho '{\"from\":\".nimlet\"}'")
    let discovered = discoverExtensions(root)
    let shared = findExt(discovered.tools, "shared")
    check ".nimlet" in shared.dir
    let result = waitFor runExtension(shared, %*{}, root)
    check not result.isError
    check "\".nimlet\"" in result.output

  test "builtin name is skipped with a warning":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "bash", "echo '{\"nope\":true}'")
    var reg: ToolRegistry
    let warnings = reg.registerExtensions(root)
    var collision = false
    for w in warnings:
      if "bash" in w and "built-in" in w:
        collision = true
    check collision
    for d in reg.definitions:
      check d.name != "bash"

  test "script extension succeeds":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "greet",
      "cat >/dev/null\necho '{\"hello\":\"world\"}'")
    let ext = findExt(discoverExtensions(root).tools, "greet")
    let result = waitFor runExtension(ext, %*{"x": 1}, root)
    check not result.isError
    check "\"hello\"" in result.output
    check "\"world\"" in result.output

  test "binary extension succeeds":
    let root = freshDir()
    defer: removeDir(root)
    let dir = root / ".nimlet" / "tools" / "echo_json"
    createDir(dir)
    let command = when defined(windows):
      @[if findExe("pwsh").len > 0: findExe("pwsh")
        else: findExe("powershell"), "-NoLogo", "-NoProfile", "-Command",
        "[Console]::WriteLine('{\"bin\":true}')"]
    else:
      @["/bin/echo", "{\"bin\":true}"]
    writeFile(dir / "tool.json", $(%*{
      "name": "echo_json",
      "description": "Echo a JSON object",
      "command": command,
      "input_schema": {"type": "object", "properties": {}}
    }))
    let ext = findExt(discoverExtensions(root).tools, "echo_json")
    let result = waitFor runExtension(ext, %*{}, root)
    check not result.isError
    check "\"bin\"" in result.output

  test "nonzero exit is an error":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "fail",
      "echo '{\"error\":\"nope\"}'\nexit 1")
    let ext = findExt(discoverExtensions(root).tools, "fail")
    let result = waitFor runExtension(ext, %*{}, root)
    check result.isError
    check "\"error\"" in result.output

  test "timeout_seconds expires a sleeping tool":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "slow", "sleep 5\necho '{}'", timeout = 1)
    let ext = findExt(discoverExtensions(root).tools, "slow")
    let result = waitFor runExtension(ext, %*{}, root)
    check result.isError
    check "TIMEOUT" in result.output

  test "external tools yield and accept asynchronous cancellation":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "slow", "sleep 5\necho '{}'", timeout = 10)
    let ext = findExt(discoverExtensions(root).tools, "slow")
    var cancelled = false
    proc cancelSoon() {.async.} =
      await sleepAsync(50)
      cancelled = true
    asyncCheck cancelSoon()
    let result = waitFor runExtension(ext, %*{}, root,
      shouldCancel = proc (): bool = cancelled)
    check result.isError
    check "INTERRUPTED" in result.output

  test "non-JSON stdout is an error and includes raw text":
    let root = freshDir()
    defer: removeDir(root)
    writeExt(root, ".nimlet", "plain", "cat >/dev/null\necho not-json-at-all")
    let ext = findExt(discoverExtensions(root).tools, "plain")
    let result = waitFor runExtension(ext, %*{}, root)
    check result.isError
    check "not valid JSON" in result.output
    check "not-json-at-all" in result.output

suite "persistent extensions":
  test "registers and invokes a slash command over JSONL":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "hello")
    let dir = root / ".nimlet" / "extensions" / "hello"
    writeFile(dir / "extension.json", $(%*{
      "name": "hello", "command": ["./extension.sh"]}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[{"name":"hello","description":"Say hello"}]}'
while read line; do
  case "$line" in
    *\"type\":\"shutdown\"*) exit 0 ;;
    *) echo '{"type":"response","id":"1","message":"Hello from extension"}' ;;
  esac
done
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    defer: agent.stopExtensions()
    check "/hello" in commandSuggestions("/he", root)
    var messages: seq[string]
    var ui = consoleSink()
    ui.emit = proc (level: MsgLevel, text: string) = messages.add text
    check agent.processInput("/hello world", ui)
    check messages == @["Hello from extension"]

  test "registers tools and accepts unlimited response time":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "echo")
    let dir = root / ".nimlet" / "extensions" / "echo"
    writeFile(dir / "extension.json", $(%*{"name": "echo",
      "command": ["./extension.sh"], "response_timeout_seconds": nil}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[],"tools":[{"name":"ext_echo","description":"Echo through the extension","input_schema":{"type":"object"},"capabilities":["read"]}]}'
read request
echo '{"type":"response","id":"1","content":"extension tool result","is_error":false}'
read shutdown
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    defer: agent.stopExtensions()
    agent.mode = modePlan
    var visibleInPlan = false
    for definition in agent.buildRequest().tools:
      if definition.name == "ext_echo": visibleInPlan = true
    check visibleInPlan
    agent.mode = modeAct
    let output = waitFor agent.tools.execute("ext_echo", %*{})
    check not output.isError
    check output.output == "extension tool result"

  test "subscribed lifecycle events mutate tools and replace compaction":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "lifecycle")
    let dir = root / ".nimlet" / "extensions" / "lifecycle"
    writeFile(dir / "extension.json", $(%*{
      "name": "lifecycle", "command": ["./extension.sh"]}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[],"events":["tool_call","session_before_compact"]}'
read tool_event
echo '{"type":"response","id":"1","arguments":{"command":"changed"}}'
read compact_event
echo '{"type":"response","id":"2","compaction":{"summary":"extension summary","first_kept_index":1,"details":{"model":"cheap"}},"status":{"key":"state","text":"extension ready"},"widget":{"key":"work","lines":["subagent complete"]},"notification":{"level":"info","message":"custom compaction done"},"entry":{"count":1}}'
read shutdown
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    defer: agent.stopExtensions()
    let pre = waitFor agent.extensionRuntime.dispatch(hePreToolCall,
      preToolPayload("bash", %*{"command": "original"}))
    check pre.arguments["command"].getStr == "changed"
    agent.session.addUserMessage("old context")
    var notices: seq[string]
    var ui = consoleSink()
    ui.emit = proc (level: MsgLevel, text: string) = notices.add text
    let compacted = waitFor (addr agent).runCompaction(ui = ui)
    check compacted.didCompact
    check compacted.summary == "extension summary"
    check agent.session.latestCompaction.found
    check agent.session.events[^1].compactionDetails["model"].getStr == "cheap"
    check "extension ready" in agent.statusFooter
    check agent.extensionRuntime.widgetLines == @["subagent complete"]
    check notices == @["custom compaction done"]
    check agent.session.extensionEntries("lifecycle") == @[%*{"count": 1}]

  test "extension requests a user answer before completing":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "question")
    let dir = root / ".nimlet" / "extensions" / "question"
    writeFile(dir / "extension.json", $(%*{
      "name": "question", "command": ["./extension.sh"]}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[{"name":"choose","description":"Choose"}]}'
read command
echo '{"type":"ui_request","id":"q1","method":"question","prompt":"Pick one","options":["Red","Blue"]}'
read answer
echo '{"type":"response","id":"1","message":"choice received"}'
read shutdown
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    defer: agent.stopExtensions()
    var asked = false
    var messages: seq[string]
    var ui = consoleSink()
    ui.question = proc(prompt: string,
        options: seq[QuestionOption]): Future[QuestionAnswer] {.async.} =
      asked = prompt == "Pick one" and options.len == 2 and
        options[1].label == "Blue"
      return QuestionAnswer(text: "Blue")
    ui.emit = proc(level: MsgLevel, text: string) = messages.add text
    check agent.processInput("/choose", ui)
    check asked
    check messages == @["choice received"]

  test "routes concurrent responses by id":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "parallel")
    let dir = root / ".nimlet" / "extensions" / "parallel"
    writeFile(dir / "extension.json", $(%*{
      "name": "parallel", "command": ["./extension.sh"]}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[{"name":"parallel","description":"Parallel"}]}'
read first
read second
echo '{"type":"response","id":"2","message":"second"}'
echo '{"type":"response","id":"1","message":"first"}'
read shutdown
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    let runtime = startExtensions(root, "session")
    defer: runtime.stop()
    let first = runtime.invoke("parallel", "one")
    let second = runtime.invoke("parallel", "two")
    discard waitFor first
    discard waitFor second
    check first.read["message"].getStr == "first"
    check second.read["message"].getStr == "second"

  test "accepts unsolicited progress actions":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "extensions" / "progress")
    let dir = root / ".nimlet" / "extensions" / "progress"
    writeFile(dir / "extension.json", $(%*{
      "name": "progress", "command": ["./extension.sh"]}))
    writeFile(dir / "extension.sh", """#!/bin/sh
read init
echo '{"type":"register","commands":[]}'
echo '{"type":"update","status":{"key":"job","text":"working"},"notification":{"level":"info","message":"started"}}'
read shutdown
""")
    setFilePermissions(dir / "extension.sh", {fpUserRead, fpUserWrite,
      fpUserExec})
    let runtime = startExtensions(root, "session")
    defer: runtime.stop()
    waitFor sleepAsync(25)
    runtime.pump()
    check runtime.statusTexts == @["working"]
    check runtime.takeNotices[0].message == "started"

when false: # Removed hook.json regression suite; persistent extensions supersede it.
  test "plan mode suppresses command hooks while act mode restores them":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "mode-check", "session_start",
      "echo ran > hook-marker.txt\necho '{}'")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    var agent = initAgent(config)
    agent.mode = modePlan
    waitFor (addr agent).fireSessionHooks(heSessionStart)
    check not fileExists(root / "hook-marker.txt")
    agent.mode = modeAct
    waitFor (addr agent).fireSessionHooks(heSessionStart)
    check fileExists(root / "hook-marker.txt")

  proc findHook(hooks: seq[Hook], name: string): Hook =
    for h in hooks:
      if h.name == name:
        return h
    raise newException(ValueError, "hook not found: " & name)

  proc quietUi(): TurnSink =
    TurnSink(
      emit: proc(level: MsgLevel, text: string) = discard,
      render: proc() = discard,
      onChange: proc() = discard,
      commitGenerate: proc(response: ProviderResponse, final: bool) = discard,
      toolStart: proc(call: ContentBlock) = discard,
      toolResult: proc(output: string, isError: bool) = discard,
      poll: proc() = discard,
      wasInterrupted: proc(): bool = false,
      noteInterrupted: proc() = discard,
      generate: proc(provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] =
        provider.generateAsync(request)
    )

  test "invalid hook.json warns and is skipped":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "ok", "session_start", "echo '{}'")
    createDir(root / ".nimlet" / "hooks" / "broken")
    writeFile(root / ".nimlet" / "hooks" / "broken" / "hook.json", "{nope")
    let discovered = discoverHooks(root)
    var hasBroken = false
    for w in discovered.warnings:
      if "broken" in w:
        hasBroken = true
    check hasBroken
    var names: seq[string] = @[]
    for h in discovered.hooks:
      names.add h.name
    check "ok" in names
    check "broken" notin names

  test ".nimlet hooks override .agent hooks with the same name":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".agent", "shared", "session_start",
      "echo '{\"from\":\".agent\"}'")
    writeHook(root, ".nimlet", "shared", "session_start",
      "echo '{\"from\":\".nimlet\"}'")
    let shared = findHook(discoverHooks(root).hooks, "shared")
    check ".nimlet" in shared.dir

  test "pre_tool_call allow false skips the tool":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "block", "pre_tool_call",
      "cat >/dev/null\necho '{\"allow\":false,\"reason\":\"nope\"}'")
    writeFile(root / "marker.txt", "keep")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    config.compactionEnabled = false
    config.contextWindow = 1_000_000
    let hooks = discoverHooks(root).hooks
    var ran = false
    var reg: ToolRegistry
    reg.register(
      ToolDefinition(name: "touch", description: "t",
        inputSchema: %*{"type": "object"}),
      proc(input: JsonNode): Future[ToolResult] {.async.} =
        ran = true
        writeFile(root / "ran.txt", "yes")
        return ToolResult(output: "ran", isError: false))
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[
          toolUse("1", "touch", %*{})]),
        ProviderResponse(content: @[text("done")])
      ])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), tools: reg, hooks: hooks)
    agent.session.workspace = root
    agent.session.addUserMessage("go")
    agent.runTurn(quietUi())
    check not ran
    check not fileExists(root / "ran.txt")
    check agent.session.events.len >= 2
    var sawDeny = false
    for e in agent.session.events:
      if e.kind == sekToolResult and e.toolError and "nope" in e.toolOutput:
        sawDeny = true
    check sawDeny

  test "optional turn approval blocks a tool before execution":
    var config = loadConfig()
    config.compactionEnabled = false
    config.contextWindow = 1_000_000
    var ran = false
    var reg: ToolRegistry
    reg.register(ToolDefinition(name: "touch"),
      proc(input: JsonNode): Future[ToolResult] {.async.} =
        ran = true
        return ToolResult(output: "ran"))
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[toolUse("1", "touch", %*{})]),
        ProviderResponse(content: @[text("done")])])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), tools: reg)
    agent.session.addUserMessage("go")
    var approvals = 0
    var ui = quietUi()
    ui.approval = proc(call: ContentBlock,
                       reason: string): Future[PermissionDecision] {.async.} =
      inc approvals
      return pdDeny
    agent.runTurn(ui)
    check approvals == 1
    check not ran
    check provider.callCount == 2

  test "broken pre hook fails open and the tool still runs":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "broken", "pre_tool_call",
      "cat >/dev/null\necho not-json")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    config.compactionEnabled = false
    config.contextWindow = 1_000_000
    let hooks = discoverHooks(root).hooks
    var ran = false
    var reg: ToolRegistry
    reg.register(
      ToolDefinition(name: "touch", description: "t",
        inputSchema: %*{"type": "object"}),
      proc(input: JsonNode): Future[ToolResult] {.async.} =
        ran = true
        return ToolResult(output: "ran", isError: false))
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[toolUse("1", "touch", %*{})]),
        ProviderResponse(content: @[text("done")])
      ])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), tools: reg, hooks: hooks)
    agent.session.workspace = root
    agent.session.addUserMessage("go")
    var warns: seq[string] = @[]
    var ui = quietUi()
    ui.emit = proc(level: MsgLevel, text: string) =
      if level == mlWarn: warns.add text
    agent.runTurn(ui)
    check ran
    check warns.len >= 1
    check "broken" in warns[0]

  test "any matching pre hook deny blocks":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "allow-a", "pre_tool_call",
      "cat >/dev/null\necho '{\"allow\":true}'")
    writeHook(root, ".nimlet", "deny-b", "pre_tool_call",
      "cat >/dev/null\necho '{\"allow\":false,\"reason\":\"second\"}'")
    let outcome = waitFor runHooks(discoverHooks(root).hooks, hePreToolCall,
      preToolPayload("bash", %*{"command": "ls"}), root, "bash")
    check not outcome.allowed
    check "second" in outcome.reason

  test "tools filter skips non-matching tools":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "bash-only", "pre_tool_call",
      "cat >/dev/null\necho '{\"allow\":false,\"reason\":\"bash-blocked\"}'",
      tools = @["bash"])
    let hooks = discoverHooks(root).hooks
    let forRead = waitFor runHooks(hooks, hePreToolCall,
      preToolPayload("read", %*{"path": "x"}), root, "read")
    check forRead.allowed
    let forBash = waitFor runHooks(hooks, hePreToolCall,
      preToolPayload("bash", %*{"command": "x"}), root, "bash")
    check not forBash.allowed
    check "bash-blocked" in forBash.reason

  test "post_tool_call receives output and is_error":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "capture", "post_tool_call",
      "cat > post-input.json\necho '{}'")
    let hooks = discoverHooks(root).hooks
    let outcome = waitFor runHooks(hooks, hePostToolCall,
      postToolPayload("bash", %*{"command": "echo hi"}, "exit_code: 0", false),
      root, "bash")
    check outcome.allowed
    check fileExists(root / "post-input.json")
    let doc = parseJson(readFile(root / "post-input.json"))
    check doc["tool"].getStr == "bash"
    check doc["output"].getStr == "exit_code: 0"
    check doc["is_error"].getBool == false

  test "/new fires session_end then session_start":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "log-end", "session_end",
      "echo end >> hook-log.txt\necho '{}'")
    writeHook(root, ".nimlet", "log-start", "session_start",
      "echo start >> hook-log.txt\necho '{}'")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    var agent = initAgent(config)
    check agent.hooks.len >= 2
    if fileExists(root / "hook-log.txt"):
      removeFile(root / "hook-log.txt")
    check agent.processInput("/new", quietUi())
    check fileExists(root / "hook-log.txt")
    let log = readFile(root / "hook-log.txt")
    check log == "end\nstart\n"

  test "/new rescans tools and hooks from disk":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    var agent = initAgent(config)
    var names: seq[string] = @[]
    for d in agent.tools.definitions:
      names.add d.name
    check "late_tool" notin names
    check agent.hooks.len == 0
    writeExt(root, ".nimlet", "late_tool",
      "cat >/dev/null\necho '{\"ok\":true}'")
    writeHook(root, ".nimlet", "late_hook", "session_start",
      "echo late >> late-log.txt\necho '{}'")
    check agent.processInput("/new", quietUi())
    names = @[]
    for d in agent.tools.definitions:
      names.add d.name
    check "late_tool" in names
    var foundHook = false
    for h in agent.hooks:
      if h.name == "late_hook":
        foundHook = true
    check foundHook
    check fileExists(root / "late-log.txt")
    check "late" in readFile(root / "late-log.txt")

  test "/reload rescans tools and hooks without a new session":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    var agent = initAgent(config)
    let sessionId = agent.session.id
    var names: seq[string] = @[]
    for d in agent.tools.definitions:
      names.add d.name
    check "late_tool" notin names
    check agent.hooks.len == 0
    writeExt(root, ".nimlet", "late_tool",
      "cat >/dev/null\necho '{\"ok\":true}'")
    writeHook(root, ".nimlet", "late_hook", "session_start",
      "echo late >> late-log.txt\necho '{}'")
    check agent.processInput("/reload", quietUi())
    check agent.session.id == sessionId
    names = @[]
    for d in agent.tools.definitions:
      names.add d.name
    check "late_tool" in names
    var foundHook = false
    for h in agent.hooks:
      if h.name == "late_hook":
        foundHook = true
    check foundHook
    check not fileExists(root / "late-log.txt")

  test "pre_tool_call can rewrite arguments":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "rewrite", "pre_tool_call",
      """cat >/dev/null
echo '{"arguments":{"command":"echo rewritten"}}'
""")
    let outcome = waitFor runHooks(discoverHooks(root).hooks, hePreToolCall,
      preToolPayload("bash", %*{"command": "echo original"}), root, "bash")
    check outcome.allowed
    check not outcome.arguments.isNil
    check outcome.arguments["command"].getStr == "echo rewritten"

  test "post_tool_call can rewrite output and is_error":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "redact", "post_tool_call",
      """cat >/dev/null
echo '{"output":"[REDACTED]","is_error":false}'
""")
    let outcome = waitFor runHooks(discoverHooks(root).hooks, hePostToolCall,
      postToolPayload("read", %*{"path": ".env"}, "SECRET=1", false),
      root, "read")
    check outcome.hasOutput
    check outcome.output == "[REDACTED]"
    check outcome.hasIsError
    check not outcome.isError

  test "pre_compact can cancel or inject instruction":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "guide", "pre_compact",
      """cat >/dev/null
echo '{"instruction":"keep the migration work"}'
""")
    let guided = waitFor runHooks(discoverHooks(root).hooks, hePreCompact,
      preCompactPayload("s1", root, "", 1000), root)
    check guided.allowed
    check guided.instruction == "keep the migration work"
    writeHook(root, ".nimlet", "block-compact", "pre_compact",
      """cat >/dev/null
echo '{"allow":false,"reason":"not now"}'
""")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    var agent = initAgent(config)
    let blocked = waitFor (addr agent).runCompaction("user note", ui = quietUi())
    check not blocked.didCompact
    check "not now" in blocked.message

  test "turn_start and turn_end fire around a turn":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "log-turn-start", "turn_start",
      "echo start >> turn-log.txt\necho '{}'")
    writeHook(root, ".nimlet", "log-turn-end", "turn_end",
      "echo end >> turn-log.txt\necho '{}'")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    config.compactionEnabled = false
    config.contextWindow = 1_000_000
    let hooks = discoverHooks(root).hooks
    let provider = TestProvider(
      name: "test",
      responses: @[ProviderResponse(content: @[text("hi")])])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), hooks: hooks)
    agent.session.workspace = root
    agent.session.addUserMessage("go")
    agent.runTurn(quietUi())
    check readFile(root / "turn-log.txt") == "start\nend\n"

  test "rewritten arguments reach the tool":
    let root = freshDir()
    defer: removeDir(root)
    writeHook(root, ".nimlet", "force-cmd", "pre_tool_call",
      """cat >/dev/null
echo '{"arguments":{"command":"echo from-hook"}}'
""")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.workspace = root
    config.compactionEnabled = false
    config.contextWindow = 1_000_000
    var seen = ""
    var reg: ToolRegistry
    reg.register(
      ToolDefinition(name: "bash", description: "b",
        inputSchema: %*{"type": "object"}),
      proc(input: JsonNode): Future[ToolResult] {.async.} =
        seen = input["command"].getStr
        return ToolResult(output: "ok", isError: false))
    let provider = TestProvider(
      name: "test",
      responses: @[
        ProviderResponse(content: @[
          toolUse("1", "bash", %*{"command": "echo original"})]),
        ProviderResponse(content: @[text("done")])
      ])
    var agent = Agent(config: config, provider: provider,
      session: initSession(), tools: reg, hooks: discoverHooks(root).hooks)
    agent.session.workspace = root
    agent.session.addUserMessage("go")
    agent.runTurn(quietUi())
    check seen == "echo from-hook"

suite "cli prompt args":
  test "json mode emits versioned lifecycle, message, and tool events":
    let root = freshDir()
    defer: removeDir(root)
    writeFile(root / "input.txt", "contents")
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(name: "test", responses: @[
      ProviderResponse(model: "test/model", content: @[
        toolUse("call-1", "read", %*{"path": "input.txt"})],
        finishReason: frToolUse),
      ProviderResponse(model: "test/model", content: @[text("done")],
        finishReason: frEndTurn)])
    var output: seq[JsonNode]
    check agent.runJson("inspect", proc (event: JsonNode) = output.add event)
    check output.mapIt(it["type"].getStr) == @[
      "session_start", "message", "run_start", "step_start", "tool_call",
      "tool_result", "step_end", "step_start", "message", "step_end",
      "run_end", "session_end"]
    for event in output:
      check event["version"].getInt == jsonEventVersion
    check output[1]["role"].getStr == "user"
    check output[1]["content"].getStr == "inspect"
    check output[4]["tool_id"].getStr == "call-1"
    check "contents" in output[5]["output"].getStr
    check output[8]["role"].getStr == "assistant"
    check output[8]["content"].getStr == "done"
    check output[^1]["success"].getBool
    let queued = queueEventJson("session", "enqueue", "next", 1)
    check queued == %*{"version": 1, "type": "queue",
      "session_id": "session", "action": "enqueue", "depth": 1,
      "content": "next"}

  test "print mode emits only the final response":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = root / "sessions"
    config.compactionEnabled = false
    var agent = initAgent(config)
    agent.provider = TestProvider(name: "test", responses: @[
      ProviderResponse(model: "test/model", content: @[text("plain answer")],
        usage: Usage(inputTokens: 3, outputTokens: 2), finishReason: frEndTurn)])
    var output: seq[string]
    var diagnostics: seq[string]
    let captureOutput = proc (text: string) = output.add text
    let captureDiagnostic = proc (text: string) = diagnostics.add text
    check agent.runPrint("question", captureOutput, captureDiagnostic)
    check output == @["plain answer"]
    check diagnostics.len == 0

  test "print mode is explicit or selected by piped stdin":
    let long = parseCliArgs(["--print", "summarize"])
    check long.print
    check long.prompt == "summarize"
    let short = parseCliArgs(["-p", "review"])
    check short.print
    check short.printMode(true)
    check parseCliArgs(["review"]).printMode(false)
    check not parseCliArgs(["review"]).printMode(true)
    let json = parseCliArgs(["--mode", "json", "inspect"])
    check json.mode == "json"
    check json.prompt == "inspect"
    check json.printMode(true)
    let rpc = parseCliArgs(["--mode", "rpc"])
    check rpc.error.len == 0
    check rpc.mode == "rpc"
    check parseCliArgs(["--mode", "unknown"]).error.len > 0

  test "fullscreen mode is selectable at startup":
    check parseCliArgs([]).fullscreen
    check parseCliArgs(["--fullscreen"]).fullscreen
    check not parseCliArgs(["--no-fullscreen"]).fullscreen
    check not parseCliArgs(["--regular"]).fullscreen

  test "provider invocation flags are ephemeral and parse tool allowlists":
    let cli = parseCliArgs(["--provider", "anthropic", "--model", "claude-test",
      "--thinking", "high", "--api-key", "secret", "--tools", "read, bash,read",
      "prompt"])
    check cli.error.len == 0
    check cli.provider == "anthropic"
    check cli.model == "claude-test"
    check cli.thinking == "high"
    check cli.apiKey == "secret"
    check cli.toolsSpecified
    check cli.tools == @["read", "bash"]
    check cli.prompt == "prompt"
    let none = parseCliArgs(["--tools", "none"])
    check none.error.len == 0
    check none.toolsSpecified
    check none.tools.len == 0

  test "no-session is exclusive with resume flags":
    check parseCliArgs(["--no-session", "hello"]).error.len == 0
    check parseCliArgs(["--no-session", "--resume"]).error.len > 0
    check parseCliArgs(["--no-session", "--session", "abc"]).error.len > 0

  test "tool allowlists apply to act and plan requests without session files":
    let root = freshDir()
    defer: removeDir(root)
    var config = loadConfig(root, root / "config.json")
    config.sessionDir = ""
    config.compactionEnabled = false
    var agent = initAgent(config, toolAllowlist = @["read"], toolsSpecified = true)
    agent.applyApiKey("ephemeral-key")
    check OpenRouterProvider(agent.provider).apiKey == "ephemeral-key"
    check agent.session.path.len == 0
    var names: seq[string]
    for tool in agent.buildRequest().tools: names.add tool.name
    check names == @["read"]
    agent.mode = modePlan
    names.setLen(0)
    for tool in agent.buildRequest().tools: names.add tool.name
    check names == @["read"]
    agent.session.addUserMessage("in memory")
    check not fileExists(root / "config.json")
    check agent.session.events.len == 1

  test "piped input is merged before the CLI instruction":
    check mergePipedPrompt("", "  source text\n") == "source text"
    check mergePipedPrompt("summarize", "source text\n") ==
      "source text\n\nsummarize"
    check mergePipedPrompt("summarize", " \n") == "summarize"

  test "prompt words are one-shot by default":
    let cli = parseCliArgs(["fix", "the", "parser"])
    check cli.error.len == 0
    check cli.prompt == "fix the parser"
    check not cli.interactive
    check not cli.resumeLatest

  test "yolo is a startup-only process flag":
    let cli = parseCliArgs(["--yolo", "run", "tests"])
    check cli.yolo
    check cli.prompt == "run tests"

  test "--interactive keeps the REPL after a prompt":
    let cli = parseCliArgs(["-i", "do", "x"])
    check cli.interactive
    check cli.prompt == "do x"
    let again = parseCliArgs(["--interactive", "--", "-weird", "flag"])
    check again.interactive
    check again.prompt == "-weird flag"

  test "session and resume combine with a prompt":
    let cli = parseCliArgs(["--resume", "--session", "abc", "continue"])
    check cli.resumeLatest
    check cli.sessionId == "abc"
    check cli.prompt == "continue"

  test "unknown flag errors before the prompt":
    let cli = parseCliArgs(["--nope", "hello"])
    check cli.error.len > 0
    check "Unknown option" in cli.error

suite "themes":
  test "dark 256 matches historical SGR":
    check Dark256.accent == "\e[36m"
    check Dark256.panelBg == "\e[48;5;236m"
    check Dark256.selectedBg == "\e[48;5;81m"
    check Dark256.selectedFg == "\e[30m"
    check Dark256.boldAccent == "\e[1;36m"
    check Dark256.heading == "\e[1;34m"
    check Dark256.dim == "\e[2m"
    check Dark256.text == "\e[37m"
    let compiled = compileNamedTheme("dark", cd256)
    check compiled.ok
    check compiled.theme.accent == Dark256.accent
    check compiled.theme.panelBg == Dark256.panelBg

  test "truecolor hex compiles to 38;2":
    let t = compileTheme(DarkSpec, cdTrue)
    check "38;2;" in t.accent
    check "48;2;" in t.panelBg
    check t.dim == "\e[2m"
    check t.reset == "\e[0m"

  test "depth none strips color":
    let t = compileTheme(DarkSpec, cdNone)
    check t.accent.len == 0
    check t.panelBg.len == 0
    check not t.colorsOn

  test "16-color drops panels":
    let t = compileTheme(DarkSpec, cd16)
    check t.accent.len > 0
    check t.panelBg.len == 0
    check t.selectedBg.len == 0

  test "json theme loads required tokens":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet" / "themes")
    writeFile(root / ".nimlet" / "themes" / "seafoam.json", """
{
  "name": "seafoam",
  "colors": {
    "accent": "#7fdbca",
    "success": "#9ece6a",
    "error": "#f7768e",
    "warning": "#e0af68",
    "code": "#d7af5f",
    "muted": 242,
    "dim": 240,
    "text": "",
    "heading": "#c0caf5",
    "model": "#bb9af7",
    "panelBg": "#1a1b26",
    "selectedBg": "#7fdbca",
    "selectedFg": "#1a1b26"
  }
}
""")
    let loaded = findUserTheme("seafoam", root, ".nimlet", nimletConfigDir())
    check loaded.ok
    check loaded.spec.name == "seafoam"
    let compiled = compileNamedTheme("seafoam", cdTrue, root, ".nimlet",
      nimletConfigDir())
    check compiled.ok
    check compiled.theme.name == "seafoam"
    check "38;2;" in compiled.theme.accent
    check "seafoam" in listThemeNames(root, ".nimlet", nimletConfigDir())

  test "json rejects missing token and unknown name":
    let bad = parseThemeJson(parseJson("""{"name":"x","colors":{"accent":"#fff"}}"""))
    check not bad.ok
    check "missing" in bad.err
    let root = freshDir()
    defer: removeDir(root)
    let unknown = compileNamedTheme("nope", cd256, root, ".nimlet",
      nimletConfigDir())
    check not unknown.ok

  test "/theme parse and suggestions":
    check parseSlash("/theme").kind == slTheme
    check parseSlash("/theme").arg.len == 0
    check parseSlash("/theme dark").kind == slTheme
    check parseSlash("/theme dark").arg == "dark"
    check parseSlash("/theme dark extra").kind == slError
    check "/theme dark" in commandSuggestions("/theme ")
    check "/theme light" in commandSuggestions("/theme li")

  test "config theme field loads and persists":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet")
    writeFile(root / ".nimlet" / "config.json", """{"theme":"light","default_provider":"openrouter"}""")
    let cfg = loadConfig(root)
    check cfg.theme == "light"
    var patched = cfg
    patched.theme = "dark"
    persistModel(patched)
    let again = loadConfig(root)
    check again.theme == "dark"

suite "provider config options":
  test "project overlay, provider switching, request forwarding and persistence":
    let root = freshDir()
    defer: removeDir(root)
    createDir(root / ".nimlet")
    let global = root / "global.json"
    let project = root / ".nimlet" / "config.json"
    writeFile(global, """{"default_provider":"openrouter","providers":{
      "openrouter":{"options":{"provider":{"sort":"latency","allow_fallbacks":true}}},
      "openai":{"options":{"store":false,"parallel_tool_calls":false}}}}""")
    writeFile(project, """{"providers":{"openrouter":{"options":{
      "provider":{"allow_fallbacks":false}}}}}""")
    var cfg = loadConfig(root, globalPath = global)
    cfg.thinking = ""
    let expected = %*{"provider": {"sort": "latency", "allow_fallbacks": false}}
    check providerOptions(cfg) == expected
    let options = providerOptions(cfg)
    options["provider"]["sort"] = %"price"
    check providerOptions(cfg) == expected
    cfg.sessionDir = root / "sessions"
    let agent = initAgent(cfg)
    check agent.buildRequest.options == expected
    cfg.switchProvider("openai")
    check providerOptions(cfg) == %*{"store": false, "parallel_tool_calls": false}
    cfg.switchProvider("hyper")
    check providerOptions(cfg) == newJObject()
    cfg.switchProvider("openrouter")
    cfg.thinking = "high"
    cfg.persistModel()
    check parseJson(readFile(project))["providers"]["openrouter"]["options"] ==
      %*{"provider": {"allow_fallbacks": false}}

  test "explicit thinking replaces configured reasoning, including none":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    writeFile(root / "models-dev.json", "{}")
    setModelsDevCachePath(root / "models-dev.json")
    defer: setModelsDevCachePath("")
    writeFile(path, """{"default_provider":"openai","providers":{"openai":{"options":{
      "reasoning":{"effort":"low"},"reasoning_effort":"low","store":false}}}}""")
    var cfg = loadConfig(root, path)
    cfg.thinking = ""
    check providerOptions(cfg)["reasoning"]["effort"].getStr == "low"
    cfg.thinking = "high"
    check providerOptions(cfg) == %*{"reasoning": {"effort": "high"}, "store": false}
    cfg.thinking = "none"
    check providerOptions(cfg) == %*{"store": false}
    writeFile(path, """{"default_provider":"anthropic","default_model":"claude-sonnet-4-6",
      "providers":{"anthropic":{"options":{"thinking":{"type":"enabled","budget_tokens":2048},
      "output_config":{"effort":"low","other":"kept"},"metadata":{"user_id":"test"}}}}}""")
    cfg = loadConfig(root, path)
    cfg.thinking = "high"
    let options = providerOptions(cfg)
    check options["thinking"]["type"].getStr == "adaptive"
    check "budget_tokens" notin options["thinking"]
    check options["output_config"] == %*{"effort": "high", "other": "kept"}
    cfg.thinking = "none"
    check providerOptions(cfg)["thinking"] == %*{"type": "disabled"}
    check providerOptions(cfg)["output_config"] == %*{"other": "kept"}
    check providerOptions(cfg)["metadata"] == %*{"user_id": "test"}

  test "null options are empty and malformed active options fail":
    let root = freshDir()
    defer: removeDir(root)
    let path = root / "config.json"
    for value in ["null", "[]", "false", "42", "\"bad\""]:
      writeFile(path, "{\"default_provider\":\"openai\",\"providers\":{\"openai\":{\"options\":" & value & "}}}")
      var cfg = loadConfig(root, path)
      cfg.thinking = ""
      if value == "null": check providerOptions(cfg) == newJObject()
      else:
        expect ProviderError: discard providerOptions(cfg)
