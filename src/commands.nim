## Slash-command vocabulary and parsing.
##
## CommandSpecs is the name/usage table. parseSlash is the only interpreter:
## live validation (commandError) and execution (agent) both read SlashCommand.

import std/[algorithm, os, strutils]
import config
import session
import skills
import prompts
import models_dev
import workspace
import images
import nimgent
import themes

type
  SlashKind* = enum
    slNone            ## ordinary text, or an in-progress composer prefix
    slError
    slSkill
    slPrompt
    slExtension
    slHelp
    slVersion
    slPlan
    slAct
    slYolo
    slStats
    slDoctor
    slLogin
    slLogout
    slAuth
    slModel
    slModelsRefresh
    slThinking
    slWeb
    slProvider
    slSession
    slNew
    slCompact
    slTrust
    slPermissions
    slResume
    slFork
    slCopy
    slExport
    slReload
    slName
    slTheme
    slSettings
    slQuit

  SlashCommand* = object
    kind*: SlashKind
    arg*: string          ## thinking level, resume id, compact instruction, skill rest
    error*: string
    skillName*: string
    promptName*: string
    extensionName*: string

  CommandSpec* = object
    kind*: SlashKind
    name*: string
    usage*: string
    description*: string

  ModelPicker* = object
    currentModel*: string
    defaultModel*: string
    currentProvider*: string
    availableModels*: seq[string]

const CommandSpecs* = [
  CommandSpec(kind: slPlan, name: "/plan", usage: "/plan",
    description: "investigate and plan with read-only tools"),
  CommandSpec(kind: slAct, name: "/act", usage: "/act",
    description: "enable implementation tools"),
  CommandSpec(kind: slYolo, name: "/yolo", usage: "/yolo [on|off]",
    description: "auto-approve tools for this process"),
  CommandSpec(kind: slStats, name: "/stats", usage: "/stats",
    description: "show model, context, token usage, and cost"),
  CommandSpec(kind: slDoctor, name: "/doctor", usage: "/doctor [test]",
    description: "show configuration and key status; optionally test the connection"),
  CommandSpec(kind: slLogin, name: "/login", usage: "/login [flow]",
    description: "sign in to Codex with ChatGPT"),
  CommandSpec(kind: slLogout, name: "/logout", usage: "/logout",
    description: "sign out of Codex"),
  CommandSpec(kind: slAuth, name: "/auth", usage: "/auth",
    description: "show Codex authentication status"),
  CommandSpec(kind: slHelp, name: "/help", usage: "/help",
    description: "show this help"),
  CommandSpec(kind: slVersion, name: "/version", usage: "/version",
    description: "show the running nimlet version"),
  CommandSpec(kind: slModel, name: "/model", usage: "/model [name]",
    description: "show or set the model"),
  CommandSpec(kind: slModelsRefresh, name: "/models", usage: "/models refresh",
    description: "refresh cached model metadata"),
  CommandSpec(kind: slThinking, name: "/thinking", usage: "/thinking <level>",
    description: "show or set reasoning"),
  CommandSpec(kind: slWeb, name: "/web", usage: "/web [on|off]",
    description: "show or set hosted web search"),
  CommandSpec(kind: slProvider, name: "/provider", usage: "/provider [name]",
    description: "show or set the provider"),
  CommandSpec(kind: slSession, name: "/session",
    usage: "/session [rename|delete|restore] ...",
    description: "show or manage sessions"),
  CommandSpec(kind: slNew, name: "/new", usage: "/new",
    description: "start a new persistent session"),
  CommandSpec(kind: slCompact, name: "/compact", usage: "/compact [instructions]",
    description: "summarize older context"),
  CommandSpec(kind: slTrust, name: "/trust", usage: "/trust [on|off]",
    description: "show or set project-local resource trust"),
  CommandSpec(kind: slPermissions, name: "/permissions", usage: "/permissions [clear]",
    description: "show or clear remembered tool grants"),
  CommandSpec(kind: slResume, name: "/resume", usage: "/resume [query|ID]",
    description: "list this project's sessions, or resume one"),
  CommandSpec(kind: slFork, name: "/fork", usage: "/fork [message]",
    description: "fork from a user message and continue in a new session"),
  CommandSpec(kind: slCopy, name: "/copy", usage: "/copy",
    description: "copy the latest assistant response"),
  CommandSpec(kind: slExport, name: "/export", usage: "/export [file]",
    description: "export the session as standalone HTML"),
  CommandSpec(kind: slReload, name: "/reload", usage: "/reload",
    description: "rescan tools, hooks, skills, and prompts"),
  CommandSpec(kind: slName, name: "/name", usage: "/name [title]",
    description: "show or set the session name"),
  CommandSpec(kind: slTheme, name: "/theme", usage: "/theme [name]",
    description: "show or set the UI theme"),
  CommandSpec(kind: slSettings, name: "/settings", usage: "/settings",
    description: "configure message delivery and other settings"),
  CommandSpec(kind: slQuit, name: "/quit", usage: "/quit",
    description: "exit"),
  CommandSpec(kind: slQuit, name: "/exit", usage: "/exit",
    description: "exit")
]

type ExtensionCommandInfo* = object
  name*: string
  description*: string

var extensionCommands: seq[ExtensionCommandInfo]

proc setExtensionCommands*(commands: seq[ExtensionCommandInfo]) =
  extensionCommands = commands

proc helpText*(): string =
  ## Emit the full command/shortcut reference as markdown. The console and TUI
  ## render routes both run this through the markdown renderer, so colors are
  ## applied when the terminal supports them and stripped otherwise.
  result = "# nimlet commands\n\n"
  const groups = [
    "Getting started", "Model", "Session", "Trust", "UI", "Maintenance",
  ]
  const groupKinds: array[6, seq[SlashKind]] = [
    @[slPlan, slAct, slHelp, slLogin, slLogout, slAuth],
    @[slModel, slModelsRefresh, slThinking, slProvider, slWeb],
    @[slSession, slStats, slNew, slResume, slFork, slCopy, slExport, slName, slCompact],
    @[slYolo, slTrust, slPermissions],
    @[slTheme, slSettings],
    @[slDoctor, slReload, slVersion, slQuit],
  ]
  for i in 0 ..< groups.len:
    result.add "## " & groups[i] & "\n\n"
    result.add "| Command | Description |\n"
    for kind in groupKinds[i]:
      for spec in CommandSpecs:
        if spec.kind == kind:
          # `|` inside a usage splits a table cell; display as a middle dot.
          result.add "| **" & spec.usage.replace("|", "·") &
            "** | " & spec.description & " |\n"
    result.add "\n"

  result.add "## Shortcuts (interactive UI)\n\n"
  const keys = [
    ("Shift+Tab", "switch plan / act mode (after the current turn if busy)"),
    ("Enter", "submit, or queue a steering message while a turn runs"),
    ("Alt+Enter", "queue a follow-up message while a turn runs"),
    ("Shift+Enter / Alt+J", "newline in the composer"),
    ("Ctrl-G", "open the composer in $VISUAL or $EDITOR"),
    ("Ctrl-Z", "undo the last composer edit"),
    ("Ctrl-W / Alt-D", "delete the previous / next word"),
    ("Ctrl-Y", "yank the last deleted text"),
    ("!command / !!command", "run a shell command; ! sends output to the model"),
    ("Esc / Ctrl-C", "interrupt; restore queued messages to the composer"),
    ("Alt+Up", "restore queued messages to the composer"),
    ("Ctrl-V", "paste text or an image file path"),
    ("Tab / Up / Down", "accept / move through suggestions"),
    ("Ctrl-R / Ctrl-D in /resume", "rename / move the selected session to trash"),
    ("Left/Right, or Ctrl-B", "move the cursor by character"),
    ("Ctrl-F", "search the transcript"),
    ("Alt-B / Alt-F", "move the cursor by word"),
    ("Home/End, Ctrl-A/E", "jump to start / end of the line"),
    ("Up/Down, Ctrl-P/N", "history (and composer line up/down)"),
    ("Ctrl-O", "show or hide tool output and thinking details"),
    ("Ctrl-Shift-C", "copy selected transcript text"),
    ("PgUp / PgDn / mouse wheel", "scroll the transcript"),
  ]
  for (keyTxt, desc) in keys:
    result.add "- **" & keyTxt & "** — " & desc & "\n"

proc specNamed(token: string): tuple[found: bool, spec: CommandSpec] =
  for spec in CommandSpecs:
    if spec.name == token:
      return (true, spec)

proc usageOf(kind: SlashKind): string =
  for spec in CommandSpecs:
    if spec.kind == kind:
      return spec.usage

proc isBuiltinSlash(token: string): bool =
  specNamed(token).found

proc commandParts(input: string): seq[string] =
  input.strip.splitWhitespace

proc namedSkill(workspace, token: string): string =
  ## Skills are namespaced because bare slash names belong to prompt templates.
  const prefix = "/skill:"
  if not token.startsWith(prefix) or token.len == prefix.len:
    return ""
  let name = token[prefix.len .. ^1]
  if " " in name or '/' in name:
    return ""
  for skill in discoverSkills(workspace):
    if skill.name.toLowerAscii == name.toLowerAscii:
      return skill.name

proc namedPrompt(workspace, token: string): string =
  if not token.startsWith("/") or token.len < 2 or isBuiltinSlash(token): return ""
  let name = token[1 .. ^1]
  if " " in name or '/' in name: return ""
  let loaded = loadPrompt(workspace, name)
  if loaded.ok: loaded.prompt.name else: ""

proc restAfterCommand(input, command: string): string =
  let stripped = input.strip
  if stripped.len <= command.len: ""
  else: stripped[command.len .. ^1].strip

proc parseSlash*(input: string, workspace = getCurrentDir()): SlashCommand =
  ## Classify `input`. Trailing space on arg-taking commands is in-progress
  ## (slNone, no error) so the composer does not flash usage while typing.
  let parts = commandParts(input)
  if parts.len == 0 or not parts[0].startsWith("/"):
    return
  let command = parts[0]
  let trailingSpace = input.len > 0 and input[^1] in {' ', '\t'}
  let arg = restAfterCommand(input, command)
  let matched = specNamed(command)
  if parts.len == 1 and trailingSpace and matched.found and
     matched.spec.kind in {slModelsRefresh, slThinking, slWeb, slResume, slModel,
                           slProvider, slName, slTheme, slFork, slSession, slLogin,
                           slExport}:
    return

  proc fail(msg: string): SlashCommand =
    SlashCommand(kind: slError, error: msg)

  if not matched.found:
    for extension in extensionCommands:
      if command.toLowerAscii == "/" & extension.name.toLowerAscii:
        return SlashCommand(kind: slExtension, extensionName: extension.name,
          arg: arg)
    let prompt = namedPrompt(workspace, command)
    if prompt.len > 0:
      return SlashCommand(kind: slPrompt, promptName: prompt, arg: arg)
    let skill = namedSkill(workspace, command)
    if skill.len > 0:
      return SlashCommand(kind: slSkill, skillName: skill, arg: arg)
    return fail("Unknown command '" & command & "'; try /help")

  result.kind = matched.spec.kind
  result.arg = arg
  case matched.spec.kind
  of slDoctor:
    if parts.len > 2 or (parts.len == 2 and parts[1] != "test"):
      return fail("Usage: /doctor [test]")
  of slHelp, slVersion, slPlan, slAct, slStats, slNew, slCopy, slSettings,
     slLogout, slAuth, slQuit, slReload:
    if parts.len > 1:
      return fail(command & " takes no arguments")
  of slLogin:
    if parts.len > 2 or
        (parts.len == 2 and parts[1].toLowerAscii notin ["device", "browser"]):
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      result.arg = parts[1].toLowerAscii
  of slSession:
    if parts.len == 1:
      discard
    elif parts[1].toLowerAscii == "rename":
      if parts.len < 4 or not validSessionId(parts[2]):
        return fail("Usage: /session rename ID TITLE")
      result.arg = "rename " & parts[2] & " " & parts[3 .. ^1].join(" ")
    elif parts[1].toLowerAscii in ["delete", "restore"]:
      if parts.len != 3 or not validSessionId(parts[2]):
        return fail("Usage: /session " & parts[1].toLowerAscii & " ID")
      result.arg = parts[1].toLowerAscii & " " & parts[2]
    else:
      return fail("Usage: " & matched.spec.usage)
  of slProvider:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      let name = parts[1].toLowerAscii
      if name notin WiredProviders:
        return fail("Unknown provider '" & parts[1] & "' (use " &
          WiredProviders.join("|") & ")")
      result.arg = name
  of slModel:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      if parts[1] == "refresh":
        return fail("Unknown /model option 'refresh'; did you mean " &
          usageOf(slModelsRefresh) & "?")
      result.arg = parts[1]
  of slModelsRefresh:
    if parts.len != 2 or parts[1] != "refresh":
      return fail("Usage: " & matched.spec.usage)
  of slThinking:
    if parts.len > 2:
      return fail("Usage: /thinking [" & ThinkingLevels.join("|") & "]")
    if parts.len == 2:
      try:
        result.arg = normalizeThinking(parts[1])
      except ValueError:
        return fail("Invalid thinking level '" & parts[1] &
          "' (use " & ThinkingLevels.join("|") & ")")
  of slWeb:
    if parts.len > 2:
      return fail("Usage: /web [on|off]")
    if parts.len == 2:
      case parts[1].toLowerAscii
      of "on", "off":
        result.arg = parts[1].toLowerAscii
      else:
        return fail("Invalid /web value '" & parts[1] & "' (use on|off)")
  of slCompact:
    discard
  of slYolo:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2 and parts[1].toLowerAscii notin ["on", "off"]:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2: result.arg = parts[1].toLowerAscii
  of slPermissions:
    if parts.len > 2 or (parts.len == 2 and parts[1].toLowerAscii != "clear"):
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2: result.arg = "clear"
  of slTrust:
    if parts.len > 2 or (parts.len == 2 and
        parts[1].toLowerAscii notin ["on", "off"]):
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2: result.arg = parts[1].toLowerAscii
  of slResume:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      result.arg = parts[1]
  of slFork:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      try:
        if parseInt(parts[1]) < 1:
          return fail("Usage: " & matched.spec.usage)
      except ValueError:
        return fail("Usage: " & matched.spec.usage)
      result.arg = parts[1]
  of slName:
    result.arg = arg
  of slExport:
    result.arg = arg
  of slTheme:
    if parts.len > 2:
      return fail("Usage: " & matched.spec.usage)
    if parts.len == 2:
      result.arg = parts[1].toLowerAscii
  of slNone, slError, slSkill, slPrompt, slExtension:
    return fail("Unknown command '" & command & "'; try /help")

proc resumeOpensPicker*(input: string): bool =
  ## Bare `/resume` should open the in-composer session menu, not dump a list.
  let cmd = parseSlash(input)
  cmd.kind == slResume and cmd.arg.len == 0

proc forkOpensPicker*(input: string): bool =
  ## Bare `/fork` should open the current session's user-message menu.
  let cmd = parseSlash(input)
  cmd.kind == slFork and cmd.arg.len == 0

proc commandError*(input: string, workspace = getCurrentDir()): string =
  parseSlash(input, workspace).error

proc expandSkill*(workspace: string, cmd: SlashCommand): string =
  ## Skill body for a parsed `/skill` command, or empty if it cannot be loaded.
  if cmd.kind != slSkill:
    return ""
  let loaded = loadSkill(workspace, cmd.skillName)
  if not loaded.ok:
    return ""
  result = "Follow the \"" & cmd.skillName & "\" skill.\n\n" & loaded.content
  if cmd.arg.len > 0:
    result.add "\n\n" & cmd.arg

proc expandPrompt*(workspace: string, cmd: SlashCommand): string =
  if cmd.kind == slPrompt:
    result = prompts.expandPrompt(workspace, cmd.promptName, cmd.arg)

const
  modelSearchMin = 2
  modelSearchCap = 50
  mentionPathChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '/', '-', '+'}

proc mentionAt*(input: string, cursor: int):
    tuple[active: bool, at, tokEnd: int, query: string] =
  ## `@path` token containing `cursor`. Inactive for `user@host`.
  let c = clamp(cursor, 0, input.len)
  var i = c
  while i > 0 and input[i - 1] in mentionPathChars:
    dec i
  var at = -1
  if i > 0 and input[i - 1] == '@':
    at = i - 1
  elif i < input.len and input[i] == '@':
    at = i
  else:
    return
  if at > 0 and input[at - 1] notin {' ', '\t', '\n'}:
    return
  var j = at + 1
  while j < input.len and input[j] in mentionPathChars:
    inc j
  if c < at or c > j:
    return
  (true, at, j, input[at + 1 ..< min(c, j)])

proc applyMention*(input: string, cursor: int, selected: string):
    tuple[text: string, cursor: int] =
  let m = mentionAt(input, cursor)
  # A folder mention keeps no trailing space so completion can continue inside.
  let sep = if selected.endsWith("/"): "" else: " "
  if not m.active:
    result.text = input & selected
    result.cursor = result.text.len
    return
  result.text = input[0 ..< m.at] & selected & sep & input[m.tokEnd .. ^1]
  result.cursor = m.at + selected.len + sep.len

iterator mentionTokens*(text: string): tuple[at, tokEnd: int] =
  ## `@path` tokens, same rules as mentionAt (not `user@host`).
  var i = 0
  while i < text.len:
    if text[i] == '@' and (i == 0 or text[i - 1] in {' ', '\t', '\n'}):
      var j = i + 1
      while j < text.len and text[j] in mentionPathChars:
        inc j
      if j > i + 1:
        yield (i, j)
      i = j
    else:
      inc i

proc findMentions*(text: string): seq[string] =
  for at, tokEnd in mentionTokens(text):
    let path = text[at + 1 ..< tokEnd]
    if path notin result:
      result.add path

const mentionAttachBytes = 100_000

proc wrapTextAttachment(ws: Workspace, resolved, raw: string): string =
  ## File body wrapped for the model, or empty if this is not attachable text.
  let probe = raw[0 ..< min(raw.len, 4096)]
  if '\0' in probe:
    return
  var body = raw
  if body.len > mentionAttachBytes:
    body = body[0 ..< mentionAttachBytes] & "\n…(truncated)\n"
  let path = ws.relative(resolved).canonRel
  result = "<file path=\"" & path & "\">\n" & body
  if not body.endsWith("\n"):
    result.add "\n"
  result.add "</file>\n"

proc expandUserContent*(workspace, text: string): seq[ContentBlock] =
  ## Typed text plus @file bodies and @folder listings; images become blocks.
  let paths = findMentions(text)
  if paths.len == 0:
    return @[text(text)]
  let ws = initWorkspace(workspace)
  var attached = ""
  var imgBlocks: seq[ContentBlock]
  for path in paths:
    var resolved: string
    try:
      resolved = ws.resolve(path)
    except WorkspaceError:
      continue
    if dirExists(resolved):
      let rel = ws.relative(resolved).canonRel
      attached.add "\n<folder path=\"" & rel & "\">\n" &
        mentionDirListing(workspace, resolved) & "</folder>\n"
      continue
    if not fileExists(resolved):
      continue
    let raw = readFile(resolved)
    let classified = classifyImage(raw)
    if classified.mime.len > 0:
      if classified.ok:
        imgBlocks.add image(classified.mime, "", path)
      else:
        attached.add "\n[" & classified.err & ": " & path & "]\n"
      continue
    let blob = wrapTextAttachment(ws, resolved, raw)
    if blob.len > 0:
      attached.add "\n"
      attached.add blob
  if attached.len == 0:
    result.add text(text)
  else:
    result.add text(text & "\n" & attached)
  result.add imgBlocks

proc addUniqueId(ids: var seq[string], id: string) =
  if id.len == 0: return
  for x in ids:
    if x == id: return
  ids.add id

proc suggestModels(query: string, picker: ModelPicker): seq[string] =
  var recents: seq[string]
  recents.addUniqueId(picker.currentModel)
  recents.addUniqueId(picker.defaultModel)
  let q = query.toLowerAscii
  if picker.currentProvider.toLowerAscii == "codex" and
      picker.availableModels.len > 0:
    for id in recents:
      if q.len == 0 or q in id.toLowerAscii:
        result.add "/model " & id
    for id in picker.availableModels:
      if id in recents or (q.len > 0 and q notin id.toLowerAscii): continue
      if result.len >= modelSearchCap: break
      result.add "/model " & id
    result.sort()
    return
  if q.len < modelSearchMin:
    for id in recents:
      if q.len == 0 or q in id.toLowerAscii:
        result.add "/model " & id
    if q.len == 0:
      for row in searchCatalogModels(@[picker.currentProvider], "",
          modelSearchCap - result.len, skip = recents):
        result.add "/model " & row.id
    result.sort()
    return
  var skip: seq[string]
  for id in recents:
    if q in id.toLowerAscii:
      result.add "/model " & id
      skip.add id
  let remaining = modelSearchCap - result.len
  if remaining <= 0: return
  for row in searchCatalogModels(@[picker.currentProvider], query, remaining,
      skip = skip):
    result.add "/model " & row.id
  result.sort()

proc commandSuggestions*(input: string, workspace = getCurrentDir(),
                         sessionDir = "", picker = ModelPicker(),
                         cursor = -1,
                         forkChoices: seq[ForkChoice] = @[]): seq[string] =
  let cur = if cursor < 0: input.len else: cursor
  let stripped = input.strip
  if stripped.startsWith("/"):
    let parts = commandParts(input)
    if parts.len == 0:
      return
    let command = parts[0]
    let trailingSpace = input.len > 0 and input[^1] in {' ', '\t'}
    let incomplete = parts.len == 1 or trailingSpace
    let matched = specNamed(command)
    if matched.found:
      case matched.spec.kind
      of slModelsRefresh:
        if incomplete: return @[matched.spec.usage]
      of slThinking:
        if incomplete:
          for level in thinkingChoices(picker.currentProvider, picker.currentModel):
            result.add matched.spec.name & " " & level
          return
      of slWeb:
        if incomplete:
          return @["/web on", "/web off"]
      of slLogin:
        let prefix = if parts.len >= 2: parts[1].toLowerAscii else: ""
        for flow in ["browser", "device"]:
          if prefix.len == 0 or flow.startsWith(prefix):
            result.add matched.spec.name & " " & flow
        if result.len > 0:
          return
        if incomplete:
          return @[matched.spec.usage]
      of slResume:
        let query = restAfterCommand(input, matched.spec.name)
        if sessionDir.len > 0 and (parts.len <= 1 or incomplete or query.len > 0):
          var sessions: seq[SessionInfo]
          if query.len == 0:
            let allSessions = listSessionsCached(sessionDir, workspace, limit = 0)
            for i in 0 ..< min(sessionListLimit, allSessions.len):
              sessions.add allSessions[i]
          else:
            sessions = searchSessions(sessionDir, workspace, query)
          for info in sessions:
            result.add "/resume " & info.id
          if result.len > 0:
            return
        if incomplete: return @[matched.spec.usage]
      of slSession:
        let tokens = restAfterCommand(input, matched.spec.name).splitWhitespace
        if tokens.len == 0:
          return @["/session", "/session rename [ID] TITLE",
            "/session delete [ID]", "/session restore [ID]"]
        if tokens.len == 1:
          for action in ["rename", "delete", "restore"]:
            if action.startsWith(tokens[0].toLowerAscii):
              result.add "/session " & action
          if result.len > 0: return
        if tokens.len == 2 and tokens[0].toLowerAscii in ["rename", "delete"]:
          for info in listSessionsCached(sessionDir, workspace, limit = 0):
            if info.sessionMatches(tokens[1]):
              result.add "/session " & tokens[0].toLowerAscii & " " & info.id
          if result.len > 0: return
        if tokens.len == 2 and tokens[0].toLowerAscii == "restore":
          for id in listTrashedSessionIds(sessionDir):
            if id.toLowerAscii.contains(tokens[1].toLowerAscii):
              result.add "/session restore " & id
          if result.len > 0: return
        if incomplete: return @[matched.spec.usage]
      of slFork:
        let prefix = if parts.len >= 2: parts[1] else: ""
        if forkChoices.len > 0 and
            (parts.len <= 1 or incomplete or prefix.len > 0):
          for i, choice in forkChoices:
            let ordinal = $(i + 1)
            if prefix.len == 0 or ordinal.startsWith(prefix):
              result.add "/fork " & ordinal
          if result.len > 0:
            return
        if incomplete: return @[matched.spec.usage]
      of slModel:
        if parts.len > 1 and "refresh".startsWith(parts[1].toLowerAscii):
          return @[usageOf(slModelsRefresh)]
        let query = if parts.len >= 2: parts[1] else: ""
        return suggestModels(query, picker)
      of slTheme:
        let prefix = if parts.len >= 2: parts[1].toLowerAscii else: ""
        for name in listThemeNames(workspace, ".nimlet", nimletConfigDir()):
          if prefix.len == 0 or name.toLowerAscii.startsWith(prefix):
            result.add matched.spec.name & " " & name
        if result.len > 0:
          return
        if incomplete: return @[matched.spec.usage]
      of slProvider:
        let prefix = if parts.len >= 2: parts[1].toLowerAscii else: ""
        for name in WiredProviders:
          if prefix.len == 0 or name.startsWith(prefix):
            result.add matched.spec.name & " " & name
        if result.len > 0:
          return
        if incomplete: return @[matched.spec.usage]
      else: discard
    if parts.len > 1:
      return
    for spec in CommandSpecs:
      if spec.name.startsWith(command):
        result.add spec.usage
    for skill in discoverSkills(workspace):
      if skill.name.len == 0 or " " in skill.name: continue
      let slash = "/skill:" & skill.name
      if slash.startsWith(command) and slash notin result:
        result.add slash
    for prompt in discoverPrompts(workspace):
      let slash = "/" & prompt.name
      if not isBuiltinSlash(slash) and slash.startsWith(command) and slash notin result:
        result.add slash
    for extension in extensionCommands:
      let slash = "/" & extension.name
      if not isBuiltinSlash(slash) and slash.startsWith(command) and slash notin result:
        result.add slash
    return
  let m = mentionAt(input, cur)
  if m.active:
    return suggestMentionFiles(workspace, m.query)

proc commandSuggestionDescription*(suggestion: string,
                                   workspace = getCurrentDir(),
                                   sessionDir = "",
                                   forkChoices: seq[ForkChoice] = @[],
                                   picker = ModelPicker()): string =
  const resumePrefix = "/resume "
  const modelPrefix = "/model "
  const forkPrefix = "/fork "
  if sessionDir.len > 0 and suggestion.startsWith(resumePrefix):
    let id = suggestion[resumePrefix.len .. ^1].strip
    for info in listSessionsCached(sessionDir, workspace, limit = 0):
      if info.id == id: return sessionLabel(info)
  if suggestion.startsWith(forkPrefix):
    let token = suggestion[forkPrefix.len .. ^1].strip
    try:
      let ordinal = parseInt(token)
      if ordinal >= 1 and ordinal <= forkChoices.len:
        return forkChoices[ordinal - 1].preview
    except ValueError:
      discard
  if suggestion.startsWith(modelPrefix):
    let id = suggestion[modelPrefix.len .. ^1]
    if id.len > 0 and id[0] != '[':
      let (found, row) = findCatalogModel(id, WiredProviders,
        picker.currentProvider)
      if found:
        result = row.provider
        if row.context > 0:
          result.add "  " & formatContextK(row.context)
        return
      return "set the model"
  if suggestion.startsWith("@") and suggestion.len > 1:
    return if suggestion.endsWith("/"): "folder" else: "file"
  for spec in CommandSpecs:
    if suggestion == spec.usage or
       suggestion.startsWith(spec.name & " "):
      return spec.description
  if suggestion.startsWith("/") and suggestion.len > 1:
    let name = suggestion[1 .. ^1]
    for prompt in discoverPrompts(workspace):
      if prompt.name.toLowerAscii == name.toLowerAscii: return prompt.description
    for extension in extensionCommands:
      if extension.name.toLowerAscii == name.toLowerAscii:
        return extension.description
    if not name.startsWith("skill:"): return
    let skillName = name[6 .. ^1]
    for skill in discoverSkills(workspace):
      if skill.name.toLowerAscii == skillName.toLowerAscii:
        return skill.description
