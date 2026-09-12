## External editor integration for the interactive composer.

import std/[os, osproc, strutils, times]
import nimterm/term
import shell

type ExternalEditResult* = object
  ok*: bool
  text*: string
  error*: string

proc editTextExternally*(text: string): ExternalEditResult =
  let editor = block:
    let visual = getEnv("VISUAL").strip
    if visual.len > 0: visual
    else:
      let fallback = getEnv("EDITOR").strip
      if fallback.len > 0: fallback else: "nano"
  let path = getTempDir() / ("nimlet-editor-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1_000_000) & ".md")
  try:
    writeFile(path, text)
    let wasActive = terminalActive()
    if wasActive: suspendTerminal()
    var exitCode = -1
    try:
      var shell = defaultShell()
      when defined(windows):
        ## VISUAL/EDITOR frequently points at a small POSIX script. Run a
        ## shebang shell script through Bash when it is available, even from
        ## a PowerShell-launched nimlet.
        try:
          let lines = readFile(editor).splitLines
          if lines.len > 0 and lines[0].strip.toLowerAscii.startsWith("#!") and
              ("/sh" in lines[0].toLowerAscii or
               "bash" in lines[0].toLowerAscii):
            let bash = findExe("bash")
            if bash.len > 0:
              shell = ShellSpec(kind: shellBash, executable: bash)
        except CatchableError:
          discard
      let editorCommand = if shell.kind == shellBash:
        editor.replace("\\", "/")
      else:
        editor
      let editorInvocation = if fileExists(editor):
        (if shell.kind == shellPowerShell: "& " else: "") &
          shell.quoteArgument(editorCommand)
      else:
        editorCommand
      let process = startProcess(shell.executable,
        args = shell.commandLine(editorInvocation & " " &
          shell.quoteArgument(path)),
        options = {poParentStreams, poUsePath})
      exitCode = process.waitForExit()
      process.close()
    finally:
      if wasActive: resumeTerminal()
    if exitCode != 0:
      result.error = editor & " exited with code " & $exitCode
      return
    result.text = readFile(path)
    result.ok = true
  except CatchableError as e:
    result.error = e.msg
  finally:
    if fileExists(path): removeFile(path)
