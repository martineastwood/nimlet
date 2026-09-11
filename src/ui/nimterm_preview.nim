## Assemble nimlets controller and screen on the POSIX backend.

import nimterm/[app, backend, widgets]
import nimterm/platform_posix
import ../agent
import nimterm_controller
import nimterm_screen

export nimterm_controller, nimterm_screen

proc runNimtermTUI*(agent: var Agent, catalogNote = "", initialPrompt = "") =
  var body = "minimal coding agent\nWorkspace: " & agent.config.workspace &
    "\nSession: " & agent.session.id
  if catalogNote.len > 0: body.add "\n" & catalogNote
  let screen = newNimtermScreen(body, agent.config.workspace,
    agent.config.sessionDir, modelPickerFrom(agent))
  screen.replaySession(agent.session)
  let backend = newPosixBackend()
  var app = newApp(backend, screen)
  ## Keep streamed output bounded to a smooth 60 FPS while keyboard events
  ## bypass this budget in App.step.
  app.minFrameIntervalMs = 16
  let controller = newNimletController(screen, addr app, addr agent)
  app.backend.init()
  defer: app.backend.shutdown()
  app.running = true
  app.render()
  if initialPrompt.len > 0:
    screen.composer.setText(initialPrompt)
    controller.handleAction(app, screen.submit().action)
  while app.running:
    if not app.step(if screen.busy: 16 else: 100) and
        (screen.notice.len > 0 or screen.busy):
      app.invalidate()
    ## step() returns before flushing when the backend had no event. Flush here
    ## so dirty status/footer changes are not held until the next keypress.
    app.flush()
