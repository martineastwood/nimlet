## Presentation sink for agent turns.
## Agent talks only to TurnSink; adapters own presentation details.

import nimgent
import nimterm/widgets/question
import nimterm/theme
import ../events
import ../session
import console
import ../permissions
import std/asyncdispatch

type
  MsgLevel* = enum
    mlPlain, mlWarn, mlOk, mlDim, mlError

  TurnSink* = object
    emit*: proc (level: MsgLevel, text: string) {.closure.}
    render*: proc () {.closure.}
    onChange*: proc () {.closure.}
    ## Clear any in-flight stream overlay; show assistant text when `final`
    ## (end of turn).
    commitGenerate*: proc (response: ProviderResponse, final: bool) {.closure.}
    agentEvent*: proc (event: NimletEvent) {.closure.}
    question*: proc (prompt: string,
                     options: seq[QuestionOption]): Future[QuestionAnswer] {.closure.}
    toolStart*: proc (call: ContentBlock) {.closure.}
    approval*: proc (call: ContentBlock,
                     reason: string): Future[PermissionDecision] {.closure.}
    toolResult*: proc (output: string, isError: bool) {.closure.}
    poll*: proc () {.closure.}
    wasInterrupted*: proc (): bool {.closure.}
    noteInterrupted*: proc () {.closure.}
    showSession*: proc (session: Session) {.closure.}
    setEditorText*: proc (text: string) {.closure.}
    copyText*: proc (text: string) {.closure.}
    generate*: proc (provider: Provider,
                     request: ProviderRequest): Future[ProviderResponse] {.closure.}

proc noop() = discard

proc consoleSink*(): TurnSink =
  var lastCall: ContentBlock
  proc emit(level: MsgLevel, text: string) =
    let t = currentTheme
    case level
    of mlPlain: echo text
    of mlWarn: echo t.paint(t.warning, text)
    of mlOk: echo t.paint(t.success, text)
    of mlDim: echo t.paint(t.dim, text)
    of mlError:
      echo t.paint(t.error, "PROVIDER_FAILED")
      echo t.paint(t.error, text)
  proc show(session: Session) =
    if session.events.len == 0:
      echo "Started a new session: " & session.id
    else:
      echo "Resumed session: " & session.id
      echo "Events: " & $session.events.len
  TurnSink(
    emit: emit,
    render: noop,
    onChange: noop,
    commitGenerate: proc (response: ProviderResponse, final: bool) =
      if final: printResponse(response),
    toolStart: proc (call: ContentBlock) =
      lastCall = call
      printToolStart(call),
    toolResult: proc (output: string, isError: bool) =
      printToolResult(output, isError, lastCall),
    poll: noop,
    wasInterrupted: proc (): bool = false,
    noteInterrupted: noop,
    showSession: show,
    generate: proc (provider: Provider,
                    request: ProviderRequest): Future[ProviderResponse] =
      generateTextAsync(provider, request)
  )
