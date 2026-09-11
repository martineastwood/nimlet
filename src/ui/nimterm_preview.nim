## Assemble nimlets controller and screen on the POSIX backend.

import std/times
import nimterm/[app, backend, widgets]
import nimterm/platform_posix
import ../agent
import nimterm_controller
import nimterm_screen

export nimterm_controller, nimterm_screen

proc runNimtermTUI*(agent: var Agent, catalogNote = "", initialPrompt = "") =
  var body = "Workspace: " & agent.config.workspace &
    " · Session: " & agent.session.id
  if catalogNote.len > 0: body.add "\n" & catalogNote
  let screen = newNimtermScreen(body, agent.config.workspace,
    agent.config.sessionDir, modelPickerFrom(agent), agent.session.id)
  let backend = newPosixBackend()
  var app = newApp(backend, screen)
  ## Keep streamed output bounded to a smooth 60 FPS while keyboard events
  ## bypass this budget in App.step.
  app.minFrameIntervalMs = 16
  let controller = newNimletController(screen, addr app, addr agent)
  defer: controller.close()
  app.backend.init()
  defer: app.backend.shutdown()
  app.running = true
  if agent.session.events.len > 0:
    screen.footer = screen.statusLine("Loading session…")
  app.render()
  if agent.session.events.len > 0:
    screen.replaySession(agent.session)
    screen.footer = screen.statusLine(agent.statusFooter)
    app.invalidate()
    app.render()
  if initialPrompt.len > 0:
    screen.composer.setText(initialPrompt)
    controller.handleAction(app, screen.submit().action)
  var lastSpinnerFrame = -1
  while app.running:
    if not app.step(if screen.busy: 16 else: 100) and
        ((screen.busy and (int(max(0.0, epochTime() -
          screen.spinnerStartedAt) * 12.0) mod 10) != lastSpinnerFrame) or
         (screen.notice.len > 0 and epochTime() >= screen.noticeUntil)):
      if screen.busy:
        lastSpinnerFrame = int(max(0.0, epochTime() -
          screen.spinnerStartedAt) * 12.0) mod 10
        screen.footer = screen.statusLine(agent.statusFooter)
      app.invalidate()
    ## step() returns before flushing when the backend had no event. Flush here
    ## so dirty status/footer changes are not held until the next keypress.
    app.flush()
