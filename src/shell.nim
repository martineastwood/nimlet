## User-facing shell shortcuts for the interactive UI.

import std/[os, osproc, streams, strutils]

type ShellResult* = object
  output*: string
  exitCode*: int
  error*: string

proc parseShellShortcut*(input: string): tuple[found, sendToModel: bool,
                                                command: string] =
  let value = input.strip
  if value.startsWith("!!"):
    result.found = value.len > 2
    result.command = value[2 .. ^1].strip
  elif value.startsWith("!"):
    result.found = value.len > 1
    result.sendToModel = result.found
    result.command = value[1 .. ^1].strip

proc runShellCommand*(workspace, command: string): ShellResult =
  try:
    let shell = getEnv("SHELL", "/bin/sh")
    let process = startProcess(shell, workingDir = workspace,
      args = @["-lc", command], options = {poUsePath, poStdErrToStdOut})
    result.output = process.outputStream.readAll
    result.exitCode = process.waitForExit()
    process.close()
  except CatchableError as e:
    result.exitCode = -1
    result.error = e.msg
