## User-facing shell shortcuts for the interactive UI.

import std/[os, osproc, streams, strutils]

type
  ShellKind* = enum
    shellPosix
    shellBash
    shellPowerShell
    shellCmd

  ShellSpec* = object
    kind*: ShellKind
    executable*: string

proc shellName(path: string): string =
  let name = path.extractFilename.toLowerAscii
  if name.endsWith(".exe"): name[0 ..< name.len - 4] else: name

proc resolveShell(value: string): string =
  let candidate = value.strip
  if candidate.len == 0: return ""
  let found = findExe(candidate)
  if found.len > 0: return found
  ## SHELL in MSYS environments is often `/usr/bin/bash`, which is not a
  ## Win32 path. Its basename is still resolvable through the inherited PATH.
  when defined(windows):
    let base = candidate.extractFilename
    if base.len > 0:
      let byName = findExe(base)
      if byName.len > 0: return byName
      let byExe = findExe(base & ".exe")
      if byExe.len > 0: return byExe
  candidate

proc defaultShell*(): ShellSpec =
  let forced = getEnv("NIMLET_SHELL").strip
  let configured = if forced.len > 0: forced else: getEnv("SHELL").strip
  when defined(windows):
    let configuredPath = resolveShell(configured)
    if configuredPath.len > 0:
      let name = shellName(configuredPath)
      if name in ["bash", "sh", "zsh", "fish"]:
        return ShellSpec(kind: if name == "bash": shellBash else: shellPosix,
          executable: configuredPath)
      if name == "pwsh":
        return ShellSpec(kind: shellPowerShell, executable: configuredPath)
      if name == "powershell":
        raise newException(ValueError,
          "Windows PowerShell 5.1 is not supported; install PowerShell 7+ and use pwsh")
      if name == "cmd":
        return ShellSpec(kind: shellCmd, executable: configuredPath)
      ## An explicit NIMLET_SHELL may be a custom POSIX-compatible shell.
      if forced.len > 0:
        return ShellSpec(kind: shellPosix, executable: configuredPath)
    ## Git Bash sets MSYSTEM. Prefer it over the PowerShell environment that
    ## can be inherited when Git Bash was launched from PowerShell.
    if getEnv("MSYSTEM").len > 0:
      let bash = resolveShell("bash")
      if bash.len > 0:
        return ShellSpec(kind: shellBash, executable: bash)
    ## PSModulePath is present in PowerShell sessions; use pwsh there so `!`
    ## shortcuts and model shell tools use UTF-8 native stream redirection.
    ## Windows PowerShell 5.1 is deliberately not a fallback: its redirected
    ## native output is UTF-16 and corrupts tool results.
    if getEnv("PSModulePath").len > 0:
      let pwsh = resolveShell("pwsh")
      if pwsh.len > 0:
        return ShellSpec(kind: shellPowerShell, executable: pwsh)
    let cmd = getEnv("ComSpec", "cmd.exe")
    return ShellSpec(kind: shellCmd, executable: cmd)
  else:
    let shell = if configured.len > 0: configured else: "/bin/sh"
    return ShellSpec(kind: shellPosix, executable: shell)

proc shellQuote(spec: ShellSpec, value: string): string =
  case spec.kind
  of shellPowerShell:
    "'" & value.replace("'", "''") & "'"
  of shellCmd:
    quoteShellWindows(value)
  of shellPosix:
    when defined(windows):
      ## MSYS shells use POSIX parsing even when Nim received a Win32 path.
      ## Backslashes would otherwise be consumed as escapes by the shell.
      quoteShellPosix(value.replace("\\", "/"))
    else:
      quoteShellPosix(value)
  of shellBash:
    ## MSYS Bash accepts POSIX-style drive paths, while Nim's Windows
    ## process quoting otherwise leaves backslashes for Bash to consume as
    ## escape characters.
    when defined(windows):
      quoteShellPosix(value.replace("\\", "/"))
    else:
      quoteShellPosix(value)

proc quoteArgument*(spec: ShellSpec, value: string): string =
  shellQuote(spec, value)

proc commandInvocation*(spec: ShellSpec, executable: string,
                        args: openArray[string]): string =
  ## Build a shell command for a known executable and its literal arguments.
  ## PowerShell needs the call operator before a quoted executable path.
  if spec.kind == shellPowerShell:
    result.add "& "
  result.add shellQuote(spec, executable)
  for arg in args:
    result.add " " & shellQuote(spec, arg)

proc commandLine*(spec: ShellSpec, command: string): seq[string] =
  case spec.kind
  of shellPowerShell:
    @["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]
  of shellCmd:
    @["/d", "/s", "/c", command]
  of shellPosix:
    @["-lc", command]
  of shellBash:
    ## Avoid login-shell startup files: Git Bash profiles can add hundreds of
    ## milliseconds to every tool invocation and are not needed for commands.
    @["-c", command]

proc redirectedCommand*(spec: ShellSpec, command, stdoutPath,
                        stderrPath: string, stdinPath = ""): string =
  let stdoutRedirect = " >" & shellQuote(spec, stdoutPath)
  let stderrRedirect = " 2>" & shellQuote(spec, stderrPath)
  case spec.kind
  of shellBash:
    let stdinRedirect = if stdinPath.len > 0:
      " <" & shellQuote(spec, stdinPath)
    else:
      ""
    "set +m; (" & command & ")" & stdinRedirect & stdoutRedirect & stderrRedirect
  of shellPowerShell:
    ## Requires PowerShell 7+, whose native stream/redirection defaults are
    ## UTF-8. Windows PowerShell 5.1 writes redirected text as UTF-16.
    let body = if stdinPath.len > 0:
      "Get-Content -Raw -LiteralPath " & shellQuote(spec, stdinPath) &
        " | & { $input | " & command & " }"
    else:
      command
    "& { " & body & " }" & stdoutRedirect & stderrRedirect
  of shellCmd:
    let stdinRedirect = if stdinPath.len > 0:
      " <" & shellQuote(spec, stdinPath)
    else:
      ""
    command & stdinRedirect & stdoutRedirect & stderrRedirect
  of shellPosix:
    let stdinRedirect = if stdinPath.len > 0:
      " <" & shellQuote(spec, stdinPath)
    else:
      ""
    "(" & command & stdinRedirect & ")" & stdoutRedirect & stderrRedirect

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
    let shell = defaultShell()
    let process = startProcess(shell.executable, workingDir = workspace,
      args = shell.commandLine(command), options = {poUsePath, poStdErrToStdOut})
    result.output = process.outputStream.readAll
    result.exitCode = process.waitForExit()
    process.close()
  except CatchableError as e:
    result.exitCode = -1
    result.error = e.msg
