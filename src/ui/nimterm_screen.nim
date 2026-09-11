## Nimlet terminal screen: widgets, input behavior, layout, and rendering.

import std/[json, os, strutils, times]
import nimgent
import nimterm/[ansi, canvas, events, geometry, keys, style, theme, widget, widgets]
import ../commands
import ../config
import ../images
import ../session
import ../workspace
import diff

type
  NimtermScreen* = ref object of Widget
    header*: Card
    menu*: Menu
    transcript*: TranscriptWidget
    composer*: InputWidget
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
    extensionWidgetLines*: seq[string]
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
const statusActivityWidth = 12
method focusable*(screen: NimtermScreen): bool = true

method children*(screen: NimtermScreen): seq[Widget] =
  result = @[Widget(screen.header), Widget(screen.transcript)]
  if not screen.questionWidget.isNil: result.add screen.questionWidget
  else:
    if screen.menu.items.len > 0: result.add screen.menu
    result.add screen.composer

proc statusLine*(screen: NimtermScreen, status: string): string =
  let frame = int(max(0.0, epochTime() - screen.spinnerStartedAt) * 12.0) mod
    spinnerFrames.len
  let activity = if screen.activity.len > 0: screen.activity else: "Ready"
  let prefix = if screen.busy:
    currentTheme.paint(currentTheme.accent, spinnerFrames[frame]) & " " & activity
  else:
    activity
  prefix & " ".repeat(max(0, statusActivityWidth - ansiVisibleWidth(prefix))) &
    " · " & status

proc statusWidth*(screen: NimtermScreen): int =
  if screen.area.w == 0: int.high
  else: max(0, screen.area.w - statusActivityWidth - 3)

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
                       modelPicker: ModelPicker, sessionId = ""): NimtermScreen =
  let t = currentTheme
  let panelStyle = t.themedStyle(t.text, t.panelBg)
  let selectedStyle = t.themedStyle(t.selectedFg, t.selectedBg, {attrBold})
  let cursorBarStyle = t.themedStyle(t.accent, t.panelBg, {attrBold})
  let descriptionStyle = t.themedStyle(t.muted, t.panelBg)
  result = NimtermScreen(
    header: newCard("nimlet coding agent", headerBody,
      t.themedStyle(t.muted), t.themedStyle(t.muted),
      t.themedStyle(t.text, "", {attrBold})),
    menu: newMenu(@[], panelStyle, selectedStyle, "Commands", true,
      t.themedStyle(t.accent), t.themedStyle(t.heading), descriptionStyle,
      selectedStyle),
    transcript: newTranscriptWidget(),
    composer: newInput(style = panelStyle, cursorStyle = selectedStyle,
      cursorBarStyle = cursorBarStyle),
    workspace: workspace,
    sessionDir: sessionDir,
    modelPicker: modelPicker, headerSessionId: sessionId,
    headerSessionLine: -1, headerSessionColumn: -1,
    headerSelectionStart: -1, headerSelectionEnd: -1,
    headerSelectionStyle: selectedStyle, themeName: t.name,
    appliedThemeRevision: -1)
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
  result.composer.paddingLeft = 2
  result.composer.paddingRight = 2
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
          screen.transcript.apply AgentUiEvent(kind: ueToolCalled, runId: runId,
            step: step, toolId: part.id, toolName: part.name, toolInput: part.input)
        else:
          discard
      screen.transcript.apply AgentUiEvent(kind: ueStepFinished, runId: runId,
        step: step)
      inc step
    of sekToolResult:
      screen.transcript.apply AgentUiEvent(kind: ueToolResult, runId: runId,
        step: step, toolId: event.toolId, toolOutput: event.toolOutput,
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
        screen.sessionDir, screen.forkChoices))
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
  screen.composer.style = screen.menu.style
  screen.composer.cursorStyle = screen.menu.selectedStyle
  screen.composer.cursorBarStyle = t.themedStyle(t.accent, t.panelBg, {attrBold})
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

method handle*(screen: NimtermScreen, event: UiEvent): EventResponse =
  if not screen.questionWidget.isNil:
    if event.kind == uiKey and event.key in {keyPageUp, keyPageDown}:
      return screen.transcript.handle(event)
    if event.kind == uiMouse and event.scrollDelta != 0:
      return screen.transcript.handle(event)
    if event.kind == uiMouse: return eventIgnored
    return screen.questionWidget.handle(event)
  if event.kind == uiMouse:
    return screen.handleHeaderMouse(event)
  if event.kind == uiKey and event.key in {keyChar, keyEnter, keyEscape} and
      screen.transcript.awaitingApproval:
    return screen.transcript.handle(event)
  if event.kind != uiKey:
    return eventIgnored
  if screen.busy:
    case event.key
    of keyEscape, keyCtrlC:
      return screen.actionHandled("interrupt")
    of keyAltUp:
      return screen.actionHandled("dequeue")
    of keyEnter:
      if screen.composer.text.strip.len > 0:
        if screen.composer.text.strip.startsWith("/"):
          screen.footer = screen.statusLine("slash commands cannot be queued")
        else:
          let queued = screen.composer.text
          screen.rememberInput()
          screen.composer.clear()
          screen.refreshMenu()
          return screen.actionHandled("queue-steer", queued)
      return eventHandled
    of keyAltEnter:
      if screen.composer.text.strip.len > 0:
        if screen.composer.text.strip.startsWith("/"):
          screen.footer = screen.statusLine("slash commands cannot be queued")
        else:
          let queued = screen.composer.text
          screen.rememberInput()
          screen.composer.clear()
          screen.refreshMenu()
          return screen.actionHandled("queue-followup", queued)
      return eventHandled
    of keyShiftTab:
      return screen.actionHandled("queue-mode-toggle")
    else:
      discard
  if event.key == keyAltUp:
    return screen.actionHandled("dequeue")
  case event.key
  of keyCopy:
    return screen.transcript.copySelection()
  of keyCtrlC:
    if screen.composer.text.len > 0:
      screen.composer.clear()
      screen.refreshMenu()
    else:
      return screen.actionHandled("quit")
  of keyEscape:
    screen.historyIndex = -1
    screen.composer.clear()
    screen.refreshMenu()
  of keyBackspace, keyDelete, keyChar, keyLeft, keyRight, keyHome, keyEnd,
     keyCtrlA, keyCtrlE, keyCtrlU, keyAltB, keyAltF, keyShiftEnter:
    screen.historyIndex = -1
    if event.key == keyChar and screen.pasteImagePath(event.text):
      discard
    else:
      discard screen.composer.handle(event)
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
  let textRows = screen.composer.visualLineCount(max(0, w -
    screen.composer.paddingLeft - screen.composer.paddingRight))
  let verticalPadding = if textRows == 1: 1 else: 0
  screen.composer.paddingTop = verticalPadding
  screen.composer.paddingBottom = verticalPadding
  let footerRow = h - 1
  let maxInputRows = max(1, footerRow - headerHeight)
  let inputRows = min(maxInputRows, textRows + verticalPadding * 2)
  let inputTop = max(0, footerRow - inputRows)
  let widgetRows = min(screen.extensionWidgetLines.len,
    max(0, inputTop - headerHeight))
  let widgetTop = inputTop - widgetRows
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
    screen.composer.render(canvas, rect(0, inputTop, w, inputRows))
  if not screen.questionWidget.isNil:
    screen.questionWidget.render(canvas, rect(0, questionTop, w, questionHeight))
  var footer = screen.footer
  if screen.notice.len > 0:
    if epochTime() < screen.noticeUntil:
      footer = footer & " · " &
        currentTheme.paint(currentTheme.accent, screen.notice)
    else:
      screen.notice = ""
  canvas.writeAnsiText(0, footerRow, footer, defaultStyle(), w)
