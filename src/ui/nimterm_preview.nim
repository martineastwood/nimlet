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
  app.minFrameIntervalMs = 50
  let controller = newNimletController(screen, addr app, addr agent)
  app.backend.init()
  defer: app.backend.shutdown()
  app.running = true
  app.render()
  if initialPrompt.len > 0:
    screen.composer.setText(initialPrompt)
    controller.handleAction(app, screen.submit().action)
  while app.running:
    if not app.step(100) and screen.notice.len > 0:
      app.invalidate()
      app.flush(true)
