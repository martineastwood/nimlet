## Nimlet terminal controller: turns, actions, interactions, and recovery.

import std/[asyncdispatch, posix, times]
import nimgent
import nimterm/[app, events, keys, transcript, widget, widgets]
import nimterm/term
import ../agent
import ../events
import ../session
import ../permissions
import nimterm_adapter
import nimterm_screen
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
    queuedInput: string
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

proc drainCancelPipe(controller: NimletController) =
  if controller.cancelRead < 0: return
  var bytes: array[64, char]
  while posix.read(controller.cancelRead, bytes.addr, bytes.len) > 0:
    discard

proc signalCancel(controller: NimletController) =
  if controller.cancelWrite < 0: return
  var byte = '\1'
  discard posix.write(controller.cancelWrite, byte.addr, 1)

proc requestInterrupt(controller: NimletController) =
  controller.interruptRequested = true
  controller.signalCancel()
  controller.screen.activity = "Stopping…"
  controller.screen.footer = controller.screen.workingFooter("Stopping…")

proc previewSink(controller: NimletController): TurnSink =
  let screen = controller.screen
  let app = controller.app
  let agent = controller.agent
  var runId = ""
  var step = -1
  var pendingDelta: NimletEvent
  var hasPendingDelta = false
  var lastDeltaFlush = 0.0
  proc refresh(force = true) =
    let status = if screen.activity.len > 0:
      screen.activity & "  " & agent[].statusFooter
    else:
      agent[].statusFooter
    screen.footer = if screen.busy: screen.workingFooter(status) else: status
    app[].invalidate()
    app[].flush(force)
  proc flushPendingDelta() =
    if not hasPendingDelta: return
    screen.transcript.apply(pendingDelta.toAgentUiEvent)
    hasPendingDelta = false
    lastDeltaFlush = epochTime()
  proc send(event: NimletEvent) =
    let uiEvent = event.toAgentUiEvent
    if uiEvent.kind == ueRunStarted: runId = uiEvent.runId
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
        flushPendingDelta()
        refresh(false)
      return
    flushPendingDelta()
    screen.transcript.apply(uiEvent)
    refresh()
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
    commitGenerate: proc (response: ProviderResponse, isFinal: bool) =
      discard response
      discard isFinal
      refresh(),
    agentEvent: send,
    question: proc (prompt: string,
                    options: seq[QuestionOption]): Future[QuestionAnswer] {.async.} =
      screen.questionWidget = newQuestion(prompt, options,
        style = screen.menu.style, selectedStyle = screen.menu.selectedStyle,
        descriptionStyle = screen.menu.descriptionStyle,
        hintStyle = screen.menu.descriptionStyle)
      screen.questionWidget.id = "question"
      controller.questionFuture = newFuture[QuestionAnswer]("nimletQuestion")
      app[].invalidate()
      app[].flush(true)
      result = await controller.questionFuture
      screen.questionWidget = nil
      app[].invalidate()
      app[].flush(true),
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
    showSession: proc (session: Session) =
      screen.transcript.setTranscript(newTranscript())
      screen.replaySession(session)
      refresh(),
    generate: proc (provider: Provider,
                    request: ProviderRequest): Future[ProviderResponse] {.async.} =
      screen.activity = "Waiting for model…"
      refresh()
      return await streamTextAsync(provider, request, proc (event: StreamEvent): bool =
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
          controller.interruptRequested)
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
  screen.footer = controller.agent[].statusFooter
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
  screen.footer = screen.workingFooter(controller.agent[].statusFooter)
  screen.transcript.appendUser(text)
  controller.turns.active = processInputAsync(controller.agent, text,
    controller.ui)

proc finishTurn(controller: NimletController, keepRunning, succeeded: bool) =
  if not keepRunning:
    controller.quitRequested = true
    controller.app[].running = false
  if controller.modeSwitchPending:
    controller.modeSwitchPending = false
    controller.agent[].mode = if controller.agent[].mode == modeAct:
      modePlan else: modeAct
  let next = controller.queuedInput
  controller.queuedInput = ""
  if next.len > 0 and keepRunning and succeeded and
      not controller.interruptRequested:
    controller.startSubmission(next)
    return
  controller.interruptRequested = false
  controller.resetInteraction()

proc handleEvent*(controller: NimletController,
                  event: UiEvent): EventResponse =
  if event.kind == uiError:
    if not event.cancelled:
      controller.screen.transcript.apply AgentUiEvent(kind: ueError,
        runId: controller.agent[].session.id & ":turn:error", error: event.error)
    controller.resetInteraction()
    return eventHandled
  if controller.screen.busy and event.kind == uiKey and event.key == keyCtrlC:
    controller.requestInterrupt()
    if not controller.questionFuture.isNil and
        not controller.questionFuture.finished:
      controller.questionFuture.complete QuestionAnswer(selected: -1,
        cancelled: true)
    if not controller.approvalFuture.isNil and
        not controller.approvalFuture.finished:
      controller.approvalFuture.complete(pdDeny)
    return eventHandled
  eventIgnored

proc handleAction*(controller: NimletController, running: var App,
                   action: UiAction) =
  let screen = controller.screen
  case action.sourceId
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
  of "screen":
    case action.kind
    of "quit": running.running = false
    of "toggle-mode":
      controller.agent[].mode = if controller.agent[].mode == modeAct:
        modePlan else: modeAct
      screen.footer = controller.agent[].statusFooter
    of "queue": controller.queuedInput = action.value
    of "queue-mode-toggle":
      controller.modeSwitchPending = not controller.modeSwitchPending
    of "interrupt": controller.requestInterrupt()
    of "submit": controller.startSubmission(action.value)
    else: discard
  else: discard
  running.invalidate()

proc newNimletController*(screen: NimtermScreen, app: ptr App,
                           agent: ptr Agent): NimletController =
  result = NimletController(screen: screen, app: app, agent: agent,
    turns: newNimletTurnSource(), cancelRead: -1, cancelWrite: -1)
  var fds: array[2, cint]
  if posix.pipe(fds) == 0:
    result.cancelRead = fds[0]
    result.cancelWrite = fds[1]
    discard fcntl(result.cancelRead, F_SETFL, O_NONBLOCK)
    discard fcntl(result.cancelWrite, F_SETFL, O_NONBLOCK)
  let controller = result
  screen.footer = agent[].statusFooter
  result.ui = previewSink(result)
  result.turns.onFinish = proc (keepRunning, succeeded: bool) =
    controller.finishTurn(keepRunning, succeeded)
  app[].addSource(result.turns)
  app[].onEvent = proc (_: var App, event: UiEvent): EventResponse =
    controller.handleEvent(event)
  app[].onAction = proc (running: var App, action: UiAction) =
    controller.handleAction(running, action)

proc close*(controller: NimletController) =
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
