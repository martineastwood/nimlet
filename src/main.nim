import std/[asyncdispatch, os, strutils, terminal]
import config, agent, session, models_dev, hooks
import ui/[console, nimterm_preview, turn]
import nimterm/theme

type
  CliArgs* = object
    help*: bool
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

proc catalogStartupNote(): string =
  if not modelsDevCacheStale(): return ""
  echo currentTheme.paint(currentTheme.dim, "Refreshing model catalog…")
  if refreshModelsDevCache():
    "Model catalog updated."
  else:
    "Could not refresh model catalog; using cache."

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
    echo "  --session ID     resume a session at startup"
    echo "  --resume         resume the latest session, if any"
    echo "  --yolo           auto-approve tools for this process"
    echo "  --interactive,-i keep the REPL after a CLI prompt"
    echo "  prompt…          run this as the first user message (one-shot unless -i)"
    return
  if cli.error.len > 0:
    stderr.writeLine cli.error
    quit(2)

  var sessionId = cli.sessionId
  let config = loadConfig(getCurrentDir())
  discard applyTheme(config.theme, detectDepth(), config.workspace,
    ".nimlet", nimletConfigDir())
  if cli.resumeLatest and sessionId.len == 0:
    let sessions = listSessions(config.sessionDir, config.workspace, limit = 1)
    if sessions.len > 0:
      sessionId = sessions[0].id
  let catalogNote = catalogStartupNote()
  var agent: Agent
  try:
    agent = initAgent(config, sessionId)
  except CatchableError as e:
    stderr.writeLine "STARTUP_FAILED"
    stderr.writeLine e.msg
    quit(1)

  agent.yolo = cli.yolo

  waitFor (addr agent).fireSessionHooks(heSessionStart)

  if cli.prompt.len > 0 and not cli.interactive:
    runOneShot(agent, cli.prompt, catalogNote)
    return

  if stdout.isatty:
    runNimtermTUI(agent, catalogNote, cli.prompt)
  else:
    runConsole(agent, catalogNote, cli.prompt)

when isMainModule:
  runMain()
