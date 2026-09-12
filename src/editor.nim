## External editor integration for the interactive composer.

import std/[os, osproc, strutils, times]
import nimterm/term

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
      let process = startProcess("/bin/sh", args = @[
        "-c", editor & " " & quoteShell(path)],
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
