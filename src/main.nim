import std/[asyncdispatch, json, os, strutils, terminal]
import nimgent
import config, agent, session, models_dev, hooks, events
import ui/[console, nimterm_preview, turn]
import nimterm/theme

type
  CliArgs* = object
    help*: bool
    print*: bool
    mode*: string
    resumeLatest*: bool
    yolo*: bool
    sessionId*: string
    ## Stay in the REPL after a CLI prompt (default: one-shot when prompt set).
    interactive*: bool
    prompt*: string
    error*: string

proc usageLine(): string =
  "Usage: nimlet [options] [prompt…]"

proc parseCliArgs*(args: openArray[string]): CliArgs =
  ## Flags may precede the prompt. `--` ends flags. Unknown `-…` flags error
  ## unless they follow `--` or are already part of the prompt words.
  var i = 0
  var promptParts: seq[string]
  var sawPrompt = false
  var endFlags = false
  while i < args.len:
    let a = args[i]
    if endFlags or sawPrompt:
      promptParts.add a
      inc i
      continue
    case a
    of "--help", "-h":
      result.help = true
      return
    of "--print", "-p":
      result.print = true
    of "--mode":
      if i + 1 >= args.len:
        result.error = "Usage: nimlet --mode json"
        return
      result.mode = args[i + 1].toLowerAscii
      if result.mode != "json":
        result.error = "Unknown mode: " & args[i + 1] & " (use json)"
        return
      inc i
    of "--resume":
      result.resumeLatest = true
    of "--yolo":
      result.yolo = true
    of "--session":
      if i + 1 >= args.len:
        result.error = "Usage: nimlet --session ID"
        return
      result.sessionId = args[i + 1]
      inc i
    of "--interactive", "-i":
      result.interactive = true
    of "--":
      endFlags = true
    else:
      if a.startsWith("-"):
        result.error = "Unknown option: " & a & "\n" & usageLine()
        return
      sawPrompt = true
      promptParts.add a
    inc i
  result.prompt = promptParts.join(" ").strip

proc catalogStartupNote(quiet = false): string =
  if not modelsDevCacheStale(): return ""
  if not quiet:
    echo currentTheme.paint(currentTheme.dim, "Refreshing model catalog…")
  if refreshModelsDevCache():
    "Model catalog updated."
  else:
    "Could not refresh model catalog; using cache."

proc mergePipedPrompt*(prompt, piped: string): string =
  let input = piped.strip
  if input.len == 0: return prompt
  if prompt.len == 0: return input
  input & "\n\n" & prompt

proc printMode*(cli: CliArgs, stdinIsTty: bool): bool =
  cli.print or cli.mode == "json" or not stdinIsTty

proc printStartupBanner(agent: Agent, catalogNote: string) =
  let t = currentTheme
  echo t.paint("\e[1m", "nimlet coding agent")
  echo t.paint(t.dim, "Provider: " & agent.config.provider & "  Model: " & agent.config.model)
  echo t.paint(t.dim, "Workspace: " & agent.config.workspace)
  echo t.paint(t.dim, "Session: " & agent.session.id)
  if agent.yolo:
    echo t.paint(t.warning, "YOLO mode: all tools auto-approved for this process")
  if catalogNote.len > 0:
    echo t.paint(t.dim, catalogNote)
  for line in agent.discoveryWarningLines:
    echo t.paint(t.dim, line)

proc runOneShot(agent: var Agent, prompt: string, catalogNote = "") =
  ## Run a single turn from a CLI prompt, then exit.
  printStartupBanner(agent, catalogNote)
  let ui = consoleSink()
  defer: waitFor (addr agent).fireSessionHooks(heSessionEnd)
  discard agent.processInput(prompt, ui)

proc runPrint*(agent: var Agent, prompt: string,
               writeResponse: proc (text: string) {.closure.} = nil,
               writeDiagnostic: proc (text: string) {.closure.} = nil): bool =
  var failed = false
  var ui = consoleSink()
  ui.emit = proc (level: MsgLevel, text: string) =
    if level == mlError: failed = true
    if level in {mlWarn, mlError}:
      if writeDiagnostic.isNil: stderr.writeLine text
      else: writeDiagnostic(text)
  ui.commitGenerate = proc (response: ProviderResponse, final: bool) =
    if final and response.text.len > 0:
      if not writeResponse.isNil:
        writeResponse(response.text)
      else:
        stdout.write response.text
        if not response.text.endsWith("\n"): stdout.write "\n"
        stdout.flushFile()
  ui.toolStart = proc (call: ContentBlock) = discard
  ui.toolResult = proc (output: string, isError: bool) = discard
  defer: waitFor (addr agent).fireSessionHooks(heSessionEnd)
  discard agent.processInput(prompt, ui)
  not failed

proc runJson*(agent: var Agent, prompt: string,
              writeEvent: proc (event: JsonNode) {.closure.} = nil): bool =
  var failed = false
  var sawErrorEvent = false
  var activeSessionId = agent.session.id
  proc send(event: JsonNode) =
    if not writeEvent.isNil:
      writeEvent(event)
    else:
      stdout.writeLine($event)
      stdout.flushFile()
  var turnId = ""
  send sessionEventJson("session_start", activeSessionId)
  var ui = consoleSink()
  ui.emit = proc (level: MsgLevel, text: string) =
    if level == mlError:
      failed = true
      if not sawErrorEvent: send diagnosticEventJson("error", text)
    elif level == mlWarn:
      send diagnosticEventJson("warning", text)
  ui.agentEvent = proc (event: NimletEvent) =
    if event.kind == neError: sawErrorEvent = true
    if event.sessionId.len > 0: activeSessionId = event.sessionId
    if event.turnId.len > 0: turnId = event.turnId
    if event.kind == neRunStarted:
      send messageEventJson(event.sessionId, event.turnId, "user", event.prompt)
    send event.nimletEventJson
  ui.commitGenerate = proc (response: ProviderResponse, final: bool) =
    if final or response.text.len > 0:
      send messageEventJson(activeSessionId, turnId, "assistant", response.text,
        response.model, final)
  ui.toolStart = proc (call: ContentBlock) = discard
  ui.toolResult = proc (output: string, isError: bool) = discard
  discard agent.processInput(prompt, ui)
  waitFor (addr agent).fireSessionHooks(heSessionEnd)
  send sessionEventJson("session_end", agent.session.id, not failed)
  not failed

proc runConsole(agent: var Agent, catalogNote = "", initialPrompt = "") =
  printStartupBanner(agent, catalogNote)
  echo currentTheme.paint(currentTheme.dim, "Type /help for commands and shortcuts.")

  let ui = consoleSink()
  defer: waitFor (addr agent).fireSessionHooks(heSessionEnd)
  if initialPrompt.len > 0:
    discard agent.processInput(initialPrompt, ui)
  while true:
    printPrompt()
    try:
      let input = stdin.readLine()
      if not agent.processInput(input, ui):
        break
    except IOError:
      break
    except CatchableError as e:
      stderr.writeLine "ERROR: " & e.msg

proc runMain*() =
  let cli = parseCliArgs(commandLineParams())
  if cli.help:
    discard applyTheme("dark", detectDepth(), getCurrentDir(), ".nimlet",
      nimletConfigDir())
    printHelp()
    echo "  --print,-p       print only the response and exit"
    echo "  --mode json      emit versioned JSONL events and exit"
    echo "  --session ID     resume a session at startup"
    echo "  --resume         resume the latest session, if any"
    echo "  --yolo           auto-approve tools for this process"
    echo "  --interactive,-i keep the REPL after a CLI prompt"
    echo "  prompt…          run this as the first user message (one-shot unless -i)"
    return
  if cli.error.len > 0:
    stderr.writeLine cli.error
    quit(2)

  let stdinIsTty = stdin.isatty
  let isPrintMode = cli.printMode(stdinIsTty)
  let prompt = if stdinIsTty: cli.prompt
               else: mergePipedPrompt(cli.prompt, stdin.readAll())
  if isPrintMode and prompt.len == 0:
    stderr.writeLine "Non-interactive mode requires a prompt or piped stdin."
    quit(2)

  var sessionId = cli.sessionId
  let config = loadConfig(getCurrentDir())
  discard applyTheme(config.theme, detectDepth(), config.workspace,
    ".nimlet", nimletConfigDir())
  if cli.resumeLatest and sessionId.len == 0:
    let sessions = listSessions(config.sessionDir, config.workspace, limit = 1)
    if sessions.len > 0:
      sessionId = sessions[0].id
  let catalogNote = catalogStartupNote(isPrintMode)
  var agent: Agent
  try:
    agent = initAgent(config, sessionId)
  except CatchableError as e:
    stderr.writeLine "STARTUP_FAILED"
    stderr.writeLine e.msg
    quit(1)

  agent.yolo = cli.yolo

  waitFor (addr agent).fireSessionHooks(heSessionStart)

  if cli.mode == "json":
    if not runJson(agent, prompt): quit(1)
    return

  if isPrintMode:
    if not runPrint(agent, prompt): quit(1)
    return

  if prompt.len > 0 and not cli.interactive:
    runOneShot(agent, prompt, catalogNote)
    return

  if stdout.isatty:
    runNimtermTUI(agent, catalogNote, prompt)
  else:
    runConsole(agent, catalogNote, prompt)

when isMainModule:
  runMain()
