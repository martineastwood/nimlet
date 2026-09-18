## Nimlet terminal controller: turns, actions, interactions, and recovery.

import std/[asyncdispatch, strutils, times]
when not defined(windows):
  import posix
import nimgent
import nimterm/[app, backend, events, keys, transcript, widget, widgets]
import nimterm/term
import ../agent
import ../extension_runtime
import ../events
import ../session
import ../permissions
import ../editor
import nimterm_adapter
import nimterm_screen
import ../shell
import tool_summary
import turn

type
  NimletTurnSource* = ref object of EventSource
    active: Future[bool]
    onFinish: proc (keepRunning, succeeded: bool) {.closure.}
  NimletController* = ref object
    screen*: NimtermScreen
    app: ptr App
    agent: ptr Agent
    turns: NimletTurnSource
    ui: TurnSink
    steeringQueue: seq[string]
    followUpQueue: seq[string]
    interruptRequested: bool
    modeSwitchPending: bool
    quitRequested: bool
    questionFuture: Future[QuestionAnswer]
    approvalToolId: string
    approvalFuture: Future[PermissionDecision]
    cancelRead, cancelWrite: cint
proc pumpAsyncDispatcher*() =
  if hasPendingOperations(): asyncdispatch.poll(0)

method poll(source: NimletTurnSource): seq[UiEvent] =
  pumpAsyncDispatcher()
  if not source.active.isNil and source.active.finished:
    let active = source.active
    source.active = nil
    var keepRunning = true
    let succeeded = not active.failed
    if active.failed:
      let error = active.readError
      result.add UiEvent(kind: uiError, sourceId: source.id,
        error: error.msg, cancelled: error of CancelledError)
    else:
      keepRunning = active.read
    if not source.onFinish.isNil: source.onFinish(keepRunning, succeeded)

method needsPolling(source: NimletTurnSource): bool = not source.active.isNil

proc newNimletTurnSource*(active: Future[bool] = nil): NimletTurnSource =
  NimletTurnSource(id: "agent-turn", active: active)

proc refreshFooter*(controller: NimletController, width = 0) =
  controller.screen.extensionWidgetLines = controller.agent[].extensionRuntime.widgetLines
  for message in controller.steeringQueue:
    controller.screen.extensionWidgetLines.add "Steering: " & message
  for message in controller.followUpQueue:
    controller.screen.extensionWidgetLines.add "Follow-up: " & message
  if controller.steeringQueue.len + controller.followUpQueue.len > 0:
    controller.screen.extensionWidgetLines.add "↳ Alt+Up to edit queued messages"
  controller.screen.footerRight = controller.agent[].statusFooterRight()
  let statusWidth = controller.screen.statusWidth(width)
  var status = controller.agent[].statusFooter(statusWidth)
  let queued = controller.steeringQueue.len + controller.followUpQueue.len
  if queued > 0: status.add " · queue:" & $queued
  controller.screen.footer = status

proc processExtensionUpdates(controller: NimletController) =
  controller.agent[].extensionRuntime.pump()
  controller.agent.applyExtensionActions(controller.ui)
  controller.refreshFooter()

when defined(windows):
  proc drainCancelPipe(controller: NimletController) = discard controller
  proc signalCancel(controller: NimletController) = discard controller
else:
  proc drainCancelPipe(controller: NimletController) =
    if controller.cancelRead < 0: return
    var bytes: array[64, char]
    while posix.read(controller.cancelRead, bytes.addr, bytes.len) > 0:
      discard

  proc signalCancel(controller: NimletController) =
    if controller.cancelWrite < 0: return
    var byte = '\1'
    discard posix.write(controller.cancelWrite, byte.addr, 1)

proc takeQueue(queue: var seq[string], mode: string): seq[string] =
  if queue.len == 0: return
  if mode == "all":
    result = move(queue)
  else:
    result = @[queue[0]]
    queue.delete(0)

proc restoreQueuedMessages(controller: NimletController) =
  let queued = controller.steeringQueue & controller.followUpQueue
  controller.steeringQueue.setLen(0)
  controller.followUpQueue.setLen(0)
  if queued.len == 0:
    controller.refreshFooter()
    return
  let current = controller.screen.composer.text
  let restored = queued.join("\n\n")
  controller.screen.composer.setText(
    if current.strip.len == 0: restored else: restored & "\n\n" & current)
  controller.screen.historyIndex = -1
  controller.screen.refreshMenu()
  controller.refreshFooter()

proc requestInterrupt(controller: NimletController) =
  controller.interruptRequested = true
  controller.signalCancel()
  controller.screen.activity = "Stopping…"
  controller.refreshFooter()

proc cancelInteraction(controller: NimletController) =
  controller.requestInterrupt()
  if not controller.questionFuture.isNil and
      not controller.questionFuture.finished:
    controller.questionFuture.complete QuestionAnswer(selected: -1,
      cancelled: true)
  if not controller.approvalFuture.isNil and
      not controller.approvalFuture.finished:
    controller.approvalFuture.complete(pdDeny)

proc startSubmission*(controller: NimletController, text: string)

proc previewSink(controller: NimletController): TurnSink =
  let screen = controller.screen
  let app = controller.app
  var runId = ""
  var step = -1
  var pendingDelta: NimletEvent
  var hasPendingDelta = false
  var lastDeltaFlush = 0.0
  var thinkingRefreshShown = false
  proc thinkingExpanded(event: NimletEvent): bool =
    let id = event.runId & ":" & $event.step & ":thinking"
    for item in screen.transcript.transcript.items:
      if item.id == id: return item.expanded
  proc refresh(force = true) =
    controller.refreshFooter()
    app[].invalidate()
    app[].flush(force)
  proc flushPendingDelta() =
    if not hasPendingDelta: return
    screen.transcript.apply(pendingDelta.toAgentUiEvent)
    hasPendingDelta = false
    lastDeltaFlush = epochTime()
  proc send(event: NimletEvent) =
    # Errors are rendered by TurnSink.emit so lifecycle errors remain available
    # to JSON/RPC consumers without duplicating them in the terminal transcript.
    if event.kind == neError: return
    var displayEvent = event
    if event.kind == neToolResult:
      displayEvent.toolOutput = transcriptToolOutput(event.toolName,
        event.toolInput, event.toolOutput, event.isError)
    let uiEvent = displayEvent.toAgentUiEvent
    if uiEvent.kind == ueRunStarted: runId = uiEvent.runId
    if uiEvent.kind in {ueRunStarted, ueStepStarted}:
      thinkingRefreshShown = false
    if uiEvent.kind == ueStepStarted: step = uiEvent.step
    if event.kind in {neTextDelta, neThinkingDelta}:
      if hasPendingDelta and (pendingDelta.kind != event.kind or
          pendingDelta.runId != event.runId or pendingDelta.step != event.step or
          pendingDelta.model != event.model):
        flushPendingDelta()
      if not hasPendingDelta:
        pendingDelta = event
        hasPendingDelta = true
      else:
        pendingDelta.text.add event.text
      if lastDeltaFlush == 0.0 or epochTime() - lastDeltaFlush >= 0.016:
        let deltaKind = pendingDelta.kind
        flushPendingDelta()
        if deltaKind != neThinkingDelta or thinkingExpanded(pendingDelta) or
            not thinkingRefreshShown:
          refresh(false)
          if deltaKind == neThinkingDelta:
            thinkingRefreshShown = true
      return
    flushPendingDelta()
    screen.transcript.apply(uiEvent)
    refresh()
  proc generateImpl(provider: Provider, request: ProviderRequest,
                    trace: TraceSink): Future[ProviderResponse] {.async.} =
    screen.activity = "Waiting for model…"
    refresh()
    var liveRequest = request
    liveRequest.wakeFd = controller.cancelRead
    return await streamTextAsync(provider, liveRequest,
      proc (event: StreamEvent): bool =
      case event.kind
      of seTextDelta:
        screen.activity = "Responding…"
        send NimletEvent(kind: neTextDelta, runId: runId,
          step: step, text: event.text)
        not controller.quitRequested and not controller.interruptRequested
      of seThinkingDelta:
        screen.activity = "Thinking…"
        send NimletEvent(kind: neThinkingDelta, runId: runId,
          step: step, text: event.text)
        not controller.quitRequested and not controller.interruptRequested
      of seToolCallDelta:
        true
      of seFinished:
        refresh()
        true
      else:
        refresh(false)
        true,
      abort = proc (): bool = controller.quitRequested or
        controller.interruptRequested,
      callbacks = RunCallbacks(trace: trace))
  result = TurnSink(
    emit: proc (level: MsgLevel, text: string) =
      if level == mlError:
        screen.transcript.apply AgentUiEvent(kind: ueError, runId: runId,
          error: text)
      else:
        screen.transcript.appendStatus(text)
      refresh(),
    render: proc () = refresh(),
    onChange: proc () = refresh(),
    commitGenerate: proc (_: ProviderResponse, _: bool) = refresh(),
    userMessage: proc (text: string) =
      screen.transcript.appendUser(text)
      refresh(),
    agentEvent: send,
    question: proc (prompt: string,
                    options: seq[QuestionOption]): Future[QuestionAnswer] {.async.} =
      screen.questionWidget = newQuestion(prompt, options,
        style = screen.menu.style, selectedStyle = screen.menu.selectedStyle,
        descriptionStyle = screen.menu.descriptionStyle,
        hintStyle = screen.menu.descriptionStyle, allowFreeText = false)
      screen.questionWidget.id = "question"
      controller.questionFuture = newFuture[QuestionAnswer]("nimletQuestion")
      app[].invalidate()
      app[].flush(true)
      result = await controller.questionFuture
      screen.questionWidget = nil
      app[].invalidate()
      app[].flush(true),
    promptText: proc (prompt: string,
                      secret: bool): Future[QuestionAnswer] {.async.} =
      screen.questionWidget = newQuestion(prompt, @[],
        style = screen.menu.style, selectedStyle = screen.menu.selectedStyle,
        descriptionStyle = screen.menu.descriptionStyle,
        hintStyle = screen.menu.descriptionStyle, allowFreeText = true,
        freeTextLabel = if secret: "Secret" else: "Answer", secret = secret)
      screen.questionWidget.id = "question"
      controller.questionFuture = newFuture[QuestionAnswer]("nimletInput")
      app[].invalidate()
      app[].flush(true)
      result = await controller.questionFuture
      screen.questionWidget = nil
      app[].invalidate()
      app[].flush(true),
    editText: proc (title, text: string): Future[ExternalEditResult] {.async.} =
      discard title
      result = editTextExternally(text)
      if not app[].backend.isNil: app[].backend.resetPresentation()
      controller.refreshFooter()
      app[].invalidate()
      app[].flush(true),
    enqueueMessage: proc (content, deliverAs: string) =
      case deliverAs
      of "steer": controller.steeringQueue.add content
      of "follow_up": controller.followUpQueue.add content
      else:
        if screen.busy: controller.followUpQueue.add content
        else: controller.startSubmission(content)
      controller.refreshFooter(),
    toolStart: proc (call: ContentBlock) =
      screen.activity = "Running " & call.name & "…"
      refresh(),
    approval: proc (call: ContentBlock,
                    reason: string): Future[PermissionDecision] {.async.} =
      screen.activity = "Approval needed"
      refresh()
      send NimletEvent(kind: neApprovalRequired,
        runId: runId, step: step, toolId: call.id, toolName: call.name,
        toolInput: call.input, text: reason, canRemember: canRemember(call))
      controller.approvalToolId = call.id
      controller.approvalFuture = newFuture[PermissionDecision]("nimletApproval")
      let decision = await controller.approvalFuture
      controller.approvalToolId = ""
      screen.activity = "Starting " & call.name & "…"
      refresh()
      return decision,
    toolResult: proc (output: string, isError: bool) =
      screen.activity = "Waiting for model…"
      refresh(),
    poll: proc () = discard,
    wasInterrupted: proc (): bool = controller.quitRequested or
      controller.interruptRequested,
    noteInterrupted: proc () = discard,
    takeSteering: proc (): seq[string] =
      result = controller.steeringQueue.takeQueue(controller.agent[].config.steeringMode)
      controller.refreshFooter(),
    takeFollowUp: proc (): seq[string] =
      result = controller.followUpQueue.takeQueue(controller.agent[].config.followUpMode)
      controller.refreshFooter(),
    showSession: proc (session: Session) =
      screen.updateHeaderSession(session.id)
      screen.forkChoices = session.forkChoices
      screen.transcript.setTranscript(newTranscript())
      screen.replaySession(session)
      refresh(),
    setEditorText: proc (text: string) =
      screen.historyIndex = -1
      screen.composer.setText(text)
      screen.refreshMenu()
      refresh(),
    copyText: proc (text: string) = copyToClipboard(text),
    generate: proc (provider: Provider,
                    request: ProviderRequest): Future[ProviderResponse] =
      generateImpl(provider, request, nil),
    generateTraced: proc (provider: Provider, request: ProviderRequest,
                          trace: TraceSink): Future[ProviderResponse] =
      generateImpl(provider, request, trace)
  )

proc resetInteraction(controller: NimletController) =
  let screen = controller.screen
  screen.busy = false
  screen.questionWidget = nil
  controller.questionFuture = nil
  controller.approvalToolId = ""
  controller.approvalFuture = nil
  screen.activity = ""
  screen.modelPicker = modelPickerFrom(controller.agent[])
  screen.forkChoices = controller.agent[].session.forkChoices
  controller.refreshFooter()
  controller.app[].focus(screen)
  controller.app[].invalidate()

proc supervise*(controller: NimletController, future: Future[bool]) =
  controller.screen.busy = true
  controller.turns.active = future

proc startSubmission*(controller: NimletController, text: string) =
  let screen = controller.screen
  controller.drainCancelPipe()
  screen.busy = true
  controller.interruptRequested = false
  screen.activity = "Thinking…"
  screen.spinnerStartedAt = epochTime()
  controller.refreshFooter()
  controller.turns.active = processInputAsync(controller.agent, text,
    controller.ui)

proc runShellShortcut(controller: NimletController, text: string): bool =
  let shortcut = parseShellShortcut(text)
  if not shortcut.found: return false
  let shell = runShellCommand(controller.agent[].config.workspace,
    shortcut.command)
  var output = shell.output
  if shell.error.len > 0:
    if output.len > 0: output.add "\n"
    output.add shell.error
  if shortcut.sendToModel:
    var prompt = "$ " & shortcut.command & "\n"
    if output.len > 0: prompt.add "\n" & output
    prompt.add "\n\n(exit " & $shell.exitCode & ")"
    controller.startSubmission(prompt)
  else:
    controller.screen.transcript.appendStatus("$ " & shortcut.command)
    controller.screen.transcript.appendStatus(
      if output.len == 0: "(no output)"
      else: output.strip(leading = false, chars = {'\n', '\r'}))
    controller.refreshFooter()
  true

proc finishTurn(controller: NimletController, keepRunning, succeeded: bool) =
  if not keepRunning:
    controller.quitRequested = true
    controller.app[].running = false
  if controller.modeSwitchPending:
    controller.modeSwitchPending = false
    controller.agent[].mode = if controller.agent[].mode == modeAct:
      modePlan else: modeAct
  if keepRunning and (controller.interruptRequested or not succeeded):
    controller.restoreQueuedMessages()
  controller.interruptRequested = false
  controller.resetInteraction()

proc signalExtensionUpdate(context: pointer) {.nimcall, gcsafe, raises: [].} =
  try: cast[ptr App](context)[].post UiEvent(kind: uiTimer, timerId: "extensions")
  except Exception: discard

proc handleEvent*(controller: NimletController,
                  event: UiEvent): EventResponse =
  if event.kind == uiKey and event.key == keyCtrlF and
      controller.screen.questionWidget.isNil and
      not controller.screen.searching:
    controller.screen.beginSearch()
    controller.app[].focus(controller.screen)
    return eventHandled
  if event.kind == uiTimer and event.timerId == "extensions":
    controller.processExtensionUpdates()
    return eventHandled
  if event.kind == uiError:
    if not event.cancelled:
      controller.screen.transcript.apply AgentUiEvent(kind: ueError,
        runId: controller.agent[].session.id & ":turn:error", error: event.error)
    controller.resetInteraction()
    return eventHandled
  if event.kind == uiResize:
    controller.refreshFooter(max(0, event.width))
  if controller.screen.busy and event.kind == uiKey and event.key == keyCtrlC:
    controller.cancelInteraction()
    return eventHandled
  eventIgnored

proc handleAction*(controller: NimletController, running: var App,
                   action: UiAction) =
  let screen = controller.screen
  case action.sourceId
  of "composer":
    if action.kind == "submit": controller.handleAction(running, screen.submit().action)
  of "transcript":
    if action.kind == "copy":
      copyToClipboard(action.value)
      screen.notice = "Copied to clipboard"
      screen.noticeUntil = epochTime() + 2.0
    elif action.kind == "approval" and
        action.targetId == controller.approvalToolId and
        not controller.approvalFuture.isNil and
        not controller.approvalFuture.finished:
      controller.approvalFuture.complete(case action.value
        of "once": pdAllowOnce
        of "session": pdAllowSession
        of "project": pdAllowProject
        else: pdDeny)
  of "question":
    if action.kind == "answer" and not controller.questionFuture.isNil and
        not controller.questionFuture.finished:
      controller.questionFuture.complete QuestionAnswer(selected: action.index,
        text: action.value, cancelled: action.cancelled)
  of "menu":
    if action.kind == "select":
      ## Mouse selection should commit the same suggestion that Enter commits.
      let response = screen.handle(UiEvent(kind: uiKey, key: keyEnter))
      if response.action.kind.len > 0:
        controller.handleAction(running, response.action)
  of "screen":
    case action.kind
    of "editor":
      let edited = screen.editExternal()
      if edited.ok:
        screen.historyIndex = -1
        screen.composer.setText(edited.text)
        screen.refreshMenu()
        screen.notice = "External editor applied"
        screen.noticeUntil = epochTime() + 2.0
      elif edited.error.len > 0:
        screen.footer = "editor: " & edited.error
      if not running.backend.isNil: running.backend.resetPresentation()
      running.invalidate()
    of "copy":
      copyToClipboard(action.value)
      screen.notice = "Copied session ID"
      screen.noticeUntil = epochTime() + 2.0
    of "quit": running.running = false
    of "toggle-mode":
      controller.agent[].mode = if controller.agent[].mode == modeAct:
        modePlan else: modeAct
      controller.refreshFooter()
    of "queue-steer":
      controller.steeringQueue.add action.value
      controller.refreshFooter()
    of "queue-followup":
      controller.followUpQueue.add action.value
      controller.refreshFooter()
    of "dequeue": controller.restoreQueuedMessages()
    of "queue-mode-toggle":
      controller.modeSwitchPending = not controller.modeSwitchPending
    of "interrupt": controller.cancelInteraction()
    of "submit":
      if not controller.runShellShortcut(action.value):
        controller.startSubmission(action.value)
    else: discard
  else: discard
  running.invalidate()

proc newNimletController*(screen: NimtermScreen, app: ptr App,
                           agent: ptr Agent): NimletController =
  let appPtr {.cursor.} = app
  result = NimletController(screen: screen, app: appPtr, agent: agent,
    turns: newNimletTurnSource(), cancelRead: -1, cancelWrite: -1,
    steeringQueue: @[], followUpQueue: @[])
  when not defined(windows):
    var fds: array[2, cint]
    if posix.pipe(fds) == 0:
      result.cancelRead = fds[0]
      result.cancelWrite = fds[1]
      discard fcntl(result.cancelRead, F_SETFL, O_NONBLOCK)
      discard fcntl(result.cancelWrite, F_SETFL, O_NONBLOCK)
  let controller = result
  screen.forkChoices = agent[].session.forkChoices
  result.refreshFooter()
  result.ui = previewSink(result)
  agent[].extensionRuntime.setOnUpdate(signalExtensionUpdate, appPtr)
  result.turns.onFinish = proc (keepRunning, succeeded: bool) =
    controller.finishTurn(keepRunning, succeeded)
  appPtr[].addSource(result.turns)
  appPtr[].onEvent = proc (_: var App, event: UiEvent): EventResponse =
    controller.handleEvent(event)
  appPtr[].onAction = proc (running: var App, action: UiAction) =
    controller.handleAction(running, action)

proc close*(controller: NimletController) =
  controller.agent[].extensionRuntime.setOnUpdate(nil)
  controller.ui = TurnSink()
  controller.turns.onFinish = nil
  controller.app[].onEvent = nil
  controller.app[].onAction = nil
  when not defined(windows):
    if controller.cancelRead >= 0:
      discard posix.close(controller.cancelRead)
      controller.cancelRead = -1
    if controller.cancelWrite >= 0:
      discard posix.close(controller.cancelWrite)
      controller.cancelWrite = -1

proc busy*(controller: NimletController): bool = controller.screen.busy

proc errorCount*(controller: NimletController): int =
  for item in controller.screen.transcript.transcript.items:
    if item.kind == tikError: inc result

proc awaitingQuestion*(controller: NimletController): bool =
  not controller.questionFuture.isNil and not controller.questionFuture.finished

proc awaitingApproval*(controller: NimletController): bool =
  not controller.approvalFuture.isNil and not controller.approvalFuture.finished
