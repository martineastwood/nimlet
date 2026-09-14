## Nimlet terminal screen: widgets, input behavior, layout, and rendering.

import std/[json, os, strutils, tables, times]
import nimgent
import nimterm/[ansi, canvas, events, geometry, keys, style, theme, widget, widgets]
import ../commands
import ../config
import ../editor
import ../images
import ../keybindings
import ../session
import ../workspace
import diff
import tool_summary

type
  NimtermScreen* = ref object of Widget
    header*: Card
    menu*: Menu
    transcript*: TranscriptWidget
    composer*: InputWidget
    searchInput*: InputWidget
    searching*: bool
    searchBefore*: string
    questionWidget*: QuestionWidget
    workspace*: string
    sessionDir*: string
    modelPicker*: ModelPicker
    forkChoices*: seq[ForkChoice]
    history*: seq[string]
    historyIndex*: int
    busy*: bool
    spinnerStartedAt*: float
    activity*: string
    notice*: string
    noticeUntil*: float
    footer*: string
    footerRight*: string
    extensionWidgetLines*: seq[string]
    keybindings*: JsonNode
    headerSessionId: string
    headerSessionLine: int
    headerSessionColumn: int
    headerSelectionStart: int
    headerSelectionEnd: int
    headerSelectionStyle: Style
    themeName: string
    appliedThemeRevision: int
    stylesReady: bool
const spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
method focusable*(screen: NimtermScreen): bool = true

method children*(screen: NimtermScreen): seq[Widget] =
  result = @[Widget(screen.header), Widget(screen.transcript)]
  if not screen.questionWidget.isNil: result.add screen.questionWidget
  else:
    if screen.menu.items.len > 0: result.add screen.menu
    result.add screen.composer

proc statusLine*(screen: NimtermScreen, status: string): string =
  status

proc activityLine*(screen: NimtermScreen): string =
  if not screen.busy and screen.activity.len == 0: return ""
  let frame = int(max(0.0, epochTime() - screen.spinnerStartedAt) * 12.0) mod
    spinnerFrames.len
  let activity = if screen.activity.len > 0: screen.activity else: "Ready"
  if screen.busy:
    currentTheme.paint(currentTheme.accent, spinnerFrames[frame]) & " " & activity
  else:
    activity

proc statusWidth*(screen: NimtermScreen, width = 0): int =
  let terminalWidth = if width > 0: width else: screen.area.w
  if terminalWidth == 0: return int.high
  let rightWidth = ansiVisibleWidth(screen.footerRight)
  max(0, terminalWidth - (if rightWidth > 0: rightWidth + 3 else: 0))

proc workingFooter*(screen: NimtermScreen, status: string): string =
  screen.statusLine(status)

proc loadHistory(screen: NimtermScreen) =
  let path = nimletConfigDir() / "history"
  if not fileExists(path): return
  for line in lines(path):
    try:
      let value = parseJson(line).getStr
      if value.len > 0 and not value.strip.startsWith("/"):
        screen.history.add value
    except CatchableError:
      discard

proc rememberInput(screen: NimtermScreen) =
  if screen.composer.text.strip.len == 0 or
      screen.composer.text.strip.startsWith("/"): return
  if screen.history.len == 0 or screen.history[^1] != screen.composer.text:
    screen.history.add screen.composer.text
  screen.historyIndex = -1
  let path = nimletConfigDir() / "history"
  createDir(path.parentDir)
  var body = ""
  let start = max(0, screen.history.len - 500)
  for i in start ..< screen.history.len:
    body.add $(%screen.history[i]) & "\n"
  writeFile(path, body)

proc newNimtermScreen*(headerBody, workspace, sessionDir: string,
                       modelPicker: ModelPicker, sessionId = "",
                       keybindings: JsonNode = nil): NimtermScreen =
  let t = currentTheme
  let panelStyle = t.themedStyle(t.text, t.panelBg)
  let composerStyle = t.themedStyle(t.text)
  let composerAccentStyle = t.themedStyle(t.accent, "", {attrBold})
  let selectedStyle = t.themedStyle(t.selectedFg, t.selectedBg, {attrBold})
  let descriptionStyle = t.themedStyle(t.muted, t.panelBg)
  result = NimtermScreen(
    header: newCard("nimlet coding agent", headerBody,
      t.themedStyle(t.muted), t.themedStyle(t.muted),
      t.themedStyle(t.text, "", {attrBold})),
    menu: newMenu(@[], panelStyle, selectedStyle, "Commands", true,
      t.themedStyle(t.accent), t.themedStyle(t.heading), descriptionStyle,
      selectedStyle),
    transcript: newTranscriptWidget(),
    composer: newInput(style = composerStyle,
      cursorStyle = composerAccentStyle, cursorBarStyle = composerAccentStyle),
    searchInput: newInput(prefix = "Search: ", style = composerStyle,
      cursorStyle = composerAccentStyle, cursorBarStyle = composerAccentStyle),
    workspace: workspace,
    sessionDir: sessionDir,
    keybindings: if keybindings.isNil: newJObject() else: keybindings,
    modelPicker: modelPicker, headerSessionId: sessionId,
    headerSessionLine: -1, headerSessionColumn: -1,
    headerSelectionStart: -1, headerSelectionEnd: -1,
    headerSelectionStyle: selectedStyle, themeName: t.name,
    appliedThemeRevision: -1)
  when compiles(result.composer.prefixStyle = composerAccentStyle):
    result.composer.prefixStyle = composerAccentStyle
  if sessionId.len > 0:
    let prefix = "Session: "
    let marker = prefix & sessionId
    let lines = headerBody.splitLines
    for i in 0 ..< lines.len:
      let line = lines[i]
      let start = line.find(marker)
      if start >= 0:
        result.headerSessionLine = i
        result.headerSessionColumn = ansiVisibleWidth(line[0 ..< start]) +
          prefix.len
        break
  result.transcript.toolDetails = proc (name: string, input: JsonNode,
                                        output: string): seq[string] =
    let hunk = formatToolHunk(name, input, true, parseHunkSpans(output))
    if hunk.len == 0: return
    result = @[input.getOrDefault("path").getStr]
    result.add hunk
  result.historyIndex = -1
  result.id = "screen"
  result.header.id = "header"
  result.menu.id = "menu"
  result.transcript.id = "transcript"
  result.composer.id = "composer"
  result.searchInput.id = "search"
  result.composer.paddingLeft = 2
  result.composer.paddingRight = 2
  result.searchInput.paddingLeft = 2
  result.searchInput.paddingRight = 2
  result.menu.style = panelStyle
  result.menu.selectedStyle = selectedStyle
  result.loadHistory()

proc updateHeaderSession*(screen: NimtermScreen, sessionId: string) =
  const prefix = "Session: "
  screen.headerSessionId = sessionId
  screen.headerSessionLine = -1
  screen.headerSessionColumn = -1
  screen.headerSelectionStart = -1
  screen.headerSelectionEnd = -1
  var lines = screen.header.body.splitLines
  for i in 0 ..< lines.len:
    let start = lines[i].find(prefix)
    if start < 0: continue
    let contentStart = start + prefix.len
    lines[i] = lines[i][0 ..< contentStart] & sessionId
    screen.header.body = lines.join("\n")
    screen.headerSessionLine = i
    screen.headerSessionColumn = ansiVisibleWidth(lines[i][0 ..< start]) +
      prefix.len
    return

proc replaySession*(screen: NimtermScreen, session: Session) =
  if session.events.len == 0: return
  let runId = "replay:" & session.id
  var toolNames = initTable[string, string]()
  var toolInputs = initTable[string, JsonNode]()
  screen.transcript.apply AgentUiEvent(kind: ueRunStarted, runId: runId)
  var step = 0
  for event in session.events:
    case event.kind
    of sekUser:
      var text = ""
      for part in event.message.content:
        case part.kind
        of ckText:
          if text.len > 0: text.add "\n"
          text.add part.text
        of ckImage:
          if text.len > 0: text.add "\n"
          text.add "[image]"
        of ckFile:
          if text.len > 0: text.add "\n"
          text.add "[file]"
        else:
          discard
      if text.len > 0: screen.transcript.appendUser(text)
    of sekAssistant:
      screen.transcript.apply AgentUiEvent(kind: ueStepStarted, runId: runId,
        step: step, model: event.model)
      for part in event.message.content:
        case part.kind
        of ckText:
          screen.transcript.apply AgentUiEvent(kind: ueTextDelta, runId: runId,
            step: step, text: part.text, model: event.model)
        of ckThinking:
          screen.transcript.apply AgentUiEvent(kind: ueThinkingDelta, runId: runId,
            step: step, text: part.thinking)
        of ckToolUse:
          toolNames[part.id] = part.name
          toolInputs[part.id] = part.input
          screen.transcript.apply AgentUiEvent(kind: ueToolCalled, runId: runId,
            step: step, toolId: part.id, toolName: part.name, toolInput: part.input)
        else:
          discard
      screen.transcript.apply AgentUiEvent(kind: ueStepFinished, runId: runId,
        step: step)
      inc step
    of sekToolResult:
      let toolName = toolNames.getOrDefault(event.toolId)
      let toolInput = toolInputs.getOrDefault(event.toolId)
      screen.transcript.apply AgentUiEvent(kind: ueToolResult, runId: runId,
        step: step, toolId: event.toolId,
        toolOutput: transcriptToolOutput(toolName, toolInput,
          event.toolOutput, event.toolError),
        isError: event.toolError)
    of sekCompaction:
      screen.transcript.appendStatus("Context compacted")
    of sekExtension:
      discard
    of sekName:
      discard
    of sekSelection:
      discard
  screen.transcript.apply AgentUiEvent(kind: ueRunFinished, runId: runId,
    step: max(0, step - 1))

proc refreshMenu*(screen: NimtermScreen) =
  let input = screen.composer.text
  let hasSuggestions = input.strip.startsWith("/") or
    mentionAt(input, screen.composer.cursor).active
  let suggestions = if hasSuggestions:
    commandSuggestions(input, screen.workspace, screen.sessionDir,
      screen.modelPicker, screen.composer.cursor, screen.forkChoices)
  else:
    @[]
  screen.menu.items.setLen(0)
  for suggestion in suggestions:
    screen.menu.items.add MenuItem(label: suggestion,
      description: commandSuggestionDescription(suggestion, screen.workspace,
        screen.sessionDir, screen.forkChoices, screen.modelPicker))
  if screen.menu.items.len == 0:
    screen.menu.selected = -1
  else:
    screen.menu.selected = min(max(screen.menu.selected, 0), screen.menu.items.high)
  screen.menu.title = if screen.composer.text.strip.startsWith("/"): "Commands"
                      else: "Files"

proc refreshMenuTheme(screen: NimtermScreen) =
  let t = currentTheme
  if screen.stylesReady and screen.appliedThemeRevision == themeRevision:
    return
  if screen.themeName != t.name or screen.appliedThemeRevision != themeRevision:
    screen.transcript.invalidateLines()
    screen.themeName = t.name
  screen.appliedThemeRevision = themeRevision
  screen.stylesReady = true
  screen.header.style = t.themedStyle(t.muted)
  screen.header.borderStyle = t.themedStyle(t.muted)
  screen.header.titleStyle = t.themedStyle(t.text, "", {attrBold})
  screen.menu.style = t.themedStyle(t.text, t.panelBg)
  screen.menu.selectedStyle = t.themedStyle(t.selectedFg, t.selectedBg, {attrBold})
  screen.menu.descriptionStyle = t.themedStyle(t.muted, t.panelBg)
  screen.menu.selectedDescriptionStyle = screen.menu.selectedStyle
  screen.menu.borderStyle = t.themedStyle(t.accent)
  screen.menu.titleStyle = t.themedStyle(t.heading)
  screen.composer.style = t.themedStyle(t.text)
  screen.searchInput.style = t.themedStyle(t.text)
  let composerAccentStyle = t.themedStyle(t.accent, "", {attrBold})
  when compiles(screen.composer.prefixStyle = composerAccentStyle):
    screen.composer.prefixStyle = composerAccentStyle
    screen.composer.cursorStyle = screen.composer.prefixStyle
    screen.composer.cursorBarStyle = screen.composer.prefixStyle
  else:
    screen.composer.cursorStyle = composerAccentStyle
    screen.composer.cursorBarStyle = composerAccentStyle
  screen.searchInput.cursorStyle = composerAccentStyle
  screen.searchInput.cursorBarStyle = composerAccentStyle
  when compiles(screen.searchInput.prefixStyle = composerAccentStyle):
    screen.searchInput.prefixStyle = composerAccentStyle
  screen.transcript.userStyle = t.themedStyle(t.muted)
  screen.transcript.assistantStyle = t.themedStyle(t.text)
  screen.transcript.thinkingStyle = t.themedStyle(t.muted, "",
    {attrDim, attrItalic})
  screen.transcript.toolStyle = t.themedStyle(t.text)
  screen.transcript.errorStyle = t.themedStyle(t.error, "", {attrBold})
  screen.transcript.userRailStyle = t.themedStyle(t.accent, t.panelBg, {attrBold})
  screen.transcript.assistantRailStyle = defaultStyle()
  screen.transcript.thinkingRailStyle = defaultStyle()
  screen.transcript.toolRailStyle = t.themedStyle(t.muted)
  screen.transcript.errorRailStyle = defaultStyle()
  screen.headerSelectionStyle = screen.menu.selectedStyle
  screen.transcript.selectionStyle = t.themedStyle(t.selectedFg, t.selectedBg,
    {attrBold})
  screen.transcript.searchStyle = t.themedStyle(t.selectedFg, t.selectedBg)

proc headerSessionText(screen: NimtermScreen): string =
  if screen.headerSelectionStart < 0 or screen.headerSelectionEnd < 0:
    return ""
  let first = min(screen.headerSelectionStart, screen.headerSelectionEnd)
  let last = max(screen.headerSelectionStart, screen.headerSelectionEnd)
  screen.headerSessionId[first .. last]

proc handleHeaderMouse(screen: NimtermScreen, event: UiEvent): EventResponse =
  if screen.headerSessionId.len == 0 or screen.headerSessionLine < 0:
    return eventIgnored
  let lineY = screen.header.area.y + 1 + screen.headerSessionLine
  let firstX = screen.header.area.x + 1 + screen.headerSessionColumn
  let column = clamp(event.x - firstX, 0, screen.headerSessionId.len - 1)
  case event.mouse
  of umPress:
    if event.y != lineY or event.x < firstX or
        event.x >= firstX + screen.headerSessionId.len:
      return eventIgnored
    screen.headerSelectionStart = column
    screen.headerSelectionEnd = column
    return captureHandled()
  of umDrag:
    if screen.headerSelectionStart < 0: return eventIgnored
    screen.headerSelectionEnd = column
    return eventHandled
  of umRelease:
    if screen.headerSelectionStart < 0: return eventIgnored
    screen.headerSelectionEnd = column
    let copied = screen.actionHandled("copy", screen.headerSessionText)
    result = releaseHandled()
    result.action = copied.action
    return result
  else:
    return eventIgnored

proc paintHeaderSelection(screen: NimtermScreen, canvas: var Canvas) =
  if screen.headerSelectionStart < 0 or screen.headerSelectionEnd < 0:
    return
  let first = min(screen.headerSelectionStart, screen.headerSelectionEnd)
  let last = max(screen.headerSelectionStart, screen.headerSelectionEnd)
  let x = screen.header.area.x + 1 + screen.headerSessionColumn
  let y = screen.header.area.y + 1 + screen.headerSessionLine
  for column in first .. last:
    var cell = canvas.getCell(x + column, y)
    cell.style = screen.headerSelectionStyle
    canvas.setCell(x + column, y, cell)

proc submit*(screen: NimtermScreen): EventResponse =
  let text = screen.composer.text.strip
  if text.len == 0: return eventIgnored
  screen.rememberInput()
  screen.composer.clear()
  screen.refreshMenu()
  screen.actionHandled("submit", text)

proc commandPrefixSuggestion(choice: string): string =
  if not choice.startsWith("/"): return ""
  let space = choice.find(' ')
  if space < 0 or space + 1 >= choice.len: return ""
  let argument = choice[space + 1 .. ^1].strip
  if argument.len < 2: return ""
  if (argument[0] == '[' and argument[^1] == ']') or
      (argument[0] == '<' and argument[^1] == '>'):
    return choice[0 .. space]

proc acceptSuggestion(screen: NimtermScreen): bool =
  if screen.menu.items.len == 0: return false
  let idx = min(max(screen.menu.selected, 0), screen.menu.items.high)
  let choice = screen.menu.items[idx].label
  let prefix = commandPrefixSuggestion(choice)
  let mention = mentionAt(screen.composer.text, screen.composer.cursor)
  screen.historyIndex = -1
  if choice.startsWith("@") and mention.active:
    let inserted = applyMention(screen.composer.text, screen.composer.cursor, choice)
    screen.composer.setText(inserted.text)
    screen.composer.cursor = inserted.cursor
  elif prefix.len > 0:
    screen.composer.setText(prefix)
  elif choice.startsWith("/") and ' ' notin choice and
       parseSlash(choice, screen.workspace).kind == slSkill:
    ## Skills take a rest argument: complete with a trailing space so the user
    ## can keep typing instead of submitting straight to the model.
    screen.composer.setText(choice & " ")
  else:
    screen.composer.setText(choice)
    screen.refreshMenu()
    return true
  screen.refreshMenu()
  false

proc selectedResumeSession(screen: NimtermScreen): string =
  if not screen.composer.text.startsWith("/resume "):
    return ""
  if screen.menu.selected < 0 or screen.menu.selected >= screen.menu.items.len:
    return ""
  const prefix = "/resume "
  let label = screen.menu.items[screen.menu.selected].label
  if label.startsWith(prefix): result = label[prefix.len .. ^1].strip

proc handleResumePickerShortcut(screen: NimtermScreen, event: UiEvent): bool =
  let id = screen.selectedResumeSession()
  if id.len == 0: return false
  case event.key
  of keyCtrlR:
    screen.composer.setText("/session rename " & id & " ")
    screen.refreshMenu()
    true
  of keyCtrlD:
    screen.composer.setText("/session delete " & id)
    screen.notice = "Press Enter to confirm moving " & id & " to trash"
    screen.noticeUntil = epochTime() + 4.0
    screen.refreshMenu()
    true
  else:
    false

proc historyPrevious(screen: NimtermScreen) =
  if screen.history.len == 0: return
  if screen.historyIndex < 0:
    screen.historyIndex = screen.history.high
  elif screen.historyIndex > 0:
    dec screen.historyIndex
  screen.composer.setText(screen.history[screen.historyIndex])
  screen.refreshMenu()

proc historyNext(screen: NimtermScreen) =
  if screen.historyIndex < 0: return
  if screen.historyIndex < screen.history.high:
    inc screen.historyIndex
    screen.composer.setText(screen.history[screen.historyIndex])
  else:
    screen.historyIndex = -1
    screen.composer.clear()
  screen.composer.cursor = screen.composer.text.len
  screen.refreshMenu()

proc insertImageMention(screen: NimtermScreen, mention: string) =
  let cursor = screen.composer.cursor
  let before = cursor > 0 and screen.composer.text[cursor - 1] notin {' ', '\t', '\n'}
  let after = cursor < screen.composer.text.len and
    screen.composer.text[cursor] notin {' ', '\t', '\n'}
  screen.historyIndex = -1
  screen.composer.insert((if before: " " else: "") & mention &
    (if after: " " else: ""))
  screen.notice = "Image pasted"
  screen.noticeUntil = epochTime() + 3.0
  screen.refreshMenu()

proc pasteImagePath(screen: NimtermScreen, pasted: string): bool =
  let mention = ingestPastedPath(initWorkspace(screen.workspace), pasted)
  if mention.len == 0: return false
  screen.insertImageMention(mention)
  true

proc convertImagePathInput(screen: NimtermScreen): bool =
  let mention = ingestPastedPath(initWorkspace(screen.workspace),
    screen.composer.text)
  if mention.len == 0: return false
  screen.historyIndex = -1
  screen.composer.setText(mention)
  screen.notice = "Image pasted"
  screen.noticeUntil = epochTime() + 3.0
  screen.refreshMenu()
  true

proc bound(screen: NimtermScreen, action: string, key: Key): bool =
  bindingMatches(screen.keybindings, action, key)

proc editorKey(screen: NimtermScreen, key: Key): Key =
  keybindings.editorKey(screen.keybindings, key)

proc editExternal*(screen: NimtermScreen): ExternalEditResult =
  editTextExternally(screen.composer.text)

proc beginSearch*(screen: NimtermScreen) =
  screen.searchBefore = screen.transcript.searchQuery
  screen.searching = true
  screen.searchInput.setText(screen.searchBefore)

proc finishSearch(screen: NimtermScreen, accept: bool) =
  if not accept:
    discard screen.transcript.setSearch(screen.searchBefore)
  else:
    let query = screen.searchInput.text.strip
    let count = screen.transcript.setSearch(query)
    screen.notice = if query.len == 0: "Search cleared"
                    elif count == 0: "No transcript matches"
                    else: $count & " transcript match" &
                      (if count == 1: "" else: "es")
    screen.noticeUntil = epochTime() + 2.0
  screen.searching = false

proc handleSearch(screen: NimtermScreen, event: UiEvent): EventResponse =
  if event.kind != uiKey: return eventIgnored
  case event.key
  of keyEscape:
    screen.finishSearch(false)
  of keyEnter:
    screen.finishSearch(true)
  of keyCtrlN:
    discard screen.transcript.nextSearch()
  of keyCtrlP:
    discard screen.transcript.nextSearch(backwards = true)
  else:
    var inputEvent = event
    inputEvent.key = screen.editorKey(event.key)
    let response = screen.searchInput.handle(inputEvent)
    if response.handled:
      discard screen.transcript.setSearch(screen.searchInput.text)
  eventHandled

method handle*(screen: NimtermScreen, event: UiEvent): EventResponse =
  if not screen.questionWidget.isNil:
    if event.kind == uiKey and event.key in {keyPageUp, keyPageDown}:
      return screen.transcript.handle(event)
    if event.kind == uiMouse and event.scrollDelta != 0:
      return screen.transcript.handle(event)
    if event.kind == uiMouse: return eventIgnored
    return screen.questionWidget.handle(event)
  if screen.searching:
    return screen.handleSearch(event)
  if event.kind == uiMouse:
    return screen.handleHeaderMouse(event)
  if event.kind == uiKey and event.key in {keyChar, keyEnter, keyEscape} and
      screen.transcript.awaitingApproval:
    return screen.transcript.handle(event)
  if event.kind != uiKey:
    return eventIgnored
  if screen.bound("app.editor.external", event.key):
    return screen.actionHandled("editor")
  if screen.busy:
    if screen.bound("app.interrupt", event.key) or
        screen.bound("app.clear", event.key):
      return screen.actionHandled("interrupt")
    if screen.bound("app.message.dequeue", event.key):
      return screen.actionHandled("dequeue")
    if screen.bound("tui.input.submit", event.key):
      if screen.composer.text.strip.len > 0:
        let queued = screen.composer.text
        if queued.strip.startsWith("/") or queued.strip.startsWith("!"):
          screen.footer = screen.statusLine(
            if queued.strip.startsWith("!"):
              "shell shortcuts cannot be queued"
            else: "slash commands cannot be queued")
        else:
          screen.rememberInput()
          screen.composer.clear()
          screen.refreshMenu()
          return screen.actionHandled("queue-steer", queued)
      return eventHandled
    if screen.bound("app.message.followUp", event.key):
      if screen.composer.text.strip.len > 0:
        let queued = screen.composer.text
        if queued.strip.startsWith("/") or queued.strip.startsWith("!"):
          screen.footer = screen.statusLine(
            if queued.strip.startsWith("!"):
              "shell shortcuts cannot be queued"
            else: "slash commands cannot be queued")
        else:
          screen.rememberInput()
          screen.composer.clear()
          screen.refreshMenu()
          return screen.actionHandled("queue-followup", queued)
      return eventHandled
    if screen.bound("app.thinking.cycle", event.key):
      return screen.actionHandled("queue-mode-toggle")
  if screen.bound("app.message.dequeue", event.key):
    return screen.actionHandled("dequeue")
  let inputKey = screen.editorKey(event.key)
  if screen.bound("app.clear", event.key):
    if screen.composer.text.len > 0:
      screen.composer.clear()
      screen.refreshMenu()
    else:
      return screen.actionHandled("quit")
    return eventHandled
  if screen.bound("app.interrupt", event.key):
    screen.historyIndex = -1
    screen.composer.clear()
    screen.refreshMenu()
    return eventHandled
  if screen.bound("app.thinking.cycle", event.key):
    return screen.actionHandled("toggle-mode")
  if event.key in {keyCtrlR, keyCtrlD} and
      screen.handleResumePickerShortcut(event):
    return eventHandled
  case inputKey
  of keyCopy:
    return screen.transcript.copySelection()
  of keyEscape:
    screen.historyIndex = -1
    screen.composer.clear()
    screen.refreshMenu()
  of keyBackspace, keyDelete, keyChar, keyLeft, keyRight, keyHome, keyEnd,
     keyCtrlA, keyCtrlE, keyCtrlK, keyCtrlU, keyCtrlW, keyCtrlY, keyCtrlZ,
     keyAltB, keyAltD, keyAltF, keyShiftEnter:
    screen.historyIndex = -1
    if event.key == keyChar and screen.pasteImagePath(event.text):
      discard
    else:
      var inputEvent = event
      inputEvent.key = inputKey
      discard screen.composer.handle(inputEvent)
      if event.key == keyChar:
        discard screen.convertImagePathInput()
    screen.refreshMenu()
  of keyTab:
    if screen.menu.items.len == 0:
      return eventIgnored
    discard screen.acceptSuggestion()
  of keyUp, keyDown:
    if screen.historyIndex >= 0 or screen.composer.text.len == 0:
      if event.key == keyUp:
        screen.historyPrevious()
      else:
        screen.historyNext()
    elif screen.menu.items.len > 0:
      discard screen.menu.handle(event)
    else:
      discard screen.composer.handle(event)
  of keyCtrlP:
    screen.historyPrevious()
  of keyCtrlN:
    screen.historyNext()
  of keyShiftTab:
    return screen.actionHandled("toggle-mode")
  of keyPageUp, keyPageDown:
    if screen.menu.items.len > 0:
      discard screen.menu.handle(event)
    else:
      discard screen.transcript.handle(event)
  of keyCtrlB, keyCtrlF, keyCtrlO:
    discard screen.transcript.handle(event)
  of keyEnter, keyAltEnter:
    if forkOpensPicker(screen.composer.text):
      screen.composer.setText("/fork ")
      screen.refreshMenu()
    elif resumeOpensPicker(screen.composer.text):
      screen.composer.setText("/resume ")
      screen.refreshMenu()
    elif screen.menu.items.len > 0:
      if screen.acceptSuggestion(): return screen.submit()
    else:
      return screen.submit()
  else:
    return eventIgnored
  eventHandled

method paint*(screen: NimtermScreen, canvas: var Canvas) =
  let h = screen.area.h
  let w = screen.area.w
  if h <= 0 or w <= 0: return
  let headerHeight = screen.header.measure(Constraints(
    minSize: size(w, 0), maxSize: size(w, h))).h
  screen.refreshMenuTheme()
  screen.header.render(canvas, rect(0, 0, w, headerHeight))
  screen.paintHeaderSelection(canvas)
  let activeInput = if screen.searching: screen.searchInput else: screen.composer
  let textRows = activeInput.visualLineCount(max(0, w -
    activeInput.paddingLeft - activeInput.paddingRight))
  let verticalPadding = if textRows == 1: 1 else: 0
  activeInput.paddingTop = verticalPadding
  activeInput.paddingBottom = verticalPadding
  let footerRow = h - 1
  let activityRows = if screen.questionWidget.isNil: 1 else: 0
  const inputRuleRows = 1
  let maxInputRows = max(1, footerRow - headerHeight - activityRows - inputRuleRows)
  let inputRows = min(maxInputRows, textRows + verticalPadding * 2)
  let inputTop = max(headerHeight + activityRows,
    footerRow - inputRuleRows - inputRows)
  let widgetRows = min(screen.extensionWidgetLines.len,
    max(0, inputTop - activityRows - headerHeight))
  let widgetTop = inputTop - activityRows - widgetRows
  let activityTop = inputTop - activityRows
  let transcriptTop = min(headerHeight + 1, inputTop)
  var contentBottom = widgetTop
  var questionTop = inputTop
  var questionHeight = 0
  if not screen.questionWidget.isNil:
    let questionSize = screen.questionWidget.measure(Constraints(
      minSize: size(w, 0),
      maxSize: size(w, max(0, footerRow - headerHeight))))
    questionHeight = questionSize.h
    questionTop = max(headerHeight, footerRow - questionHeight)
    contentBottom = questionTop
  let transcriptHeight = max(0, contentBottom - transcriptTop - 1)
  if transcriptHeight > 0:
    screen.transcript.render(canvas, rect(0, transcriptTop, w, transcriptHeight))
  if screen.questionWidget.isNil:
    const maxMenuContentRows = 7
    let menuContentRows = min(maxMenuContentRows, screen.menu.items.len)
    let menuRows = if menuContentRows > 0: menuContentRows + 2 else: 0
    if menuRows > 0:
      let menuTop = max(headerHeight, widgetTop - menuRows)
      let menuHeight = widgetTop - menuTop
      screen.menu.render(canvas, rect(0, menuTop, w, menuHeight))
    for i in 0 ..< widgetRows:
      canvas.writeAnsiText(0, widgetTop + i,
        currentTheme.paint(currentTheme.muted,
          screen.extensionWidgetLines[screen.extensionWidgetLines.len - widgetRows + i]),
        defaultStyle(), w)
    if activityRows > 0:
      canvas.writeAnsiText(0, activityTop, screen.activityLine(), defaultStyle(), w)
    let ruleStyle = currentTheme.themedStyle(currentTheme.muted, "", {attrDim})
    canvas.writeText(0, inputTop, "─".repeat(w), ruleStyle, w)
    activeInput.render(canvas, rect(0, inputTop + inputRuleRows, w, inputRows))
  if not screen.questionWidget.isNil:
    screen.questionWidget.render(canvas, rect(0, questionTop, w, questionHeight))
  var footer = if screen.searching:
    "Search · Enter accept · Esc cancel · Ctrl-N/P next/previous"
  else:
    screen.footer
  if screen.notice.len > 0:
    if epochTime() < screen.noticeUntil:
      footer = footer & " · " &
        currentTheme.paint(currentTheme.accent, screen.notice)
    else:
      screen.notice = ""
  let rightWidth = ansiVisibleWidth(screen.footerRight)
  let leftWidth = max(0, w - (if rightWidth > 0: rightWidth + 3 else: 0))
  canvas.writeAnsiText(0, footerRow, footer, defaultStyle(), leftWidth)
  if rightWidth > 0:
    let rightX = max(0, w - rightWidth)
    canvas.writeAnsiText(rightX, footerRow, screen.footerRight, defaultStyle(),
      w - rightX)
