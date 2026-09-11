## bash tool — run a shell command in the workspace.

import std/[asyncdispatch, json, os, osproc, posix, strformat, times]
import tool, nimgent, ../childproc

const
  DefaultTimeout = 120
  MaxOutputBytes = 100_000

proc makeBashTool*(workDir: string,
                   maxOutputBytes = MaxOutputBytes): (ToolDefinition, ToolProc) =
  let outputLimit = max(2, maxOutputBytes)
  let def = ToolDefinition(
    name: "bash",
    description: "Run a shell command. Returns stdout, stderr, exit code, and duration.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "command": {"type": "string", "description": "Shell command to execute."},
        "timeout_seconds": {"type": "integer", "description": "Timeout in seconds (default 120)."}
      },
      "required": ["command"]
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    let command = input["command"].getStr
    let timeout = if "timeout_seconds" in input:
      max(1, input["timeout_seconds"].getInt)
    else:
      DefaultTimeout

    let start = epochTime()
    let stamp = $getCurrentProcessId() & "-" & $int(start * 1_000_000)
    let stdoutPath = getTempDir() / ("nimlet-" & stamp & ".out")
    let stderrPath = getTempDir() / ("nimlet-" & stamp & ".err")
    let redirections = " >" & quoteShell(stdoutPath) &
      " 2>" & quoteShell(stderrPath)
    let shell = getEnv("SHELL", "/bin/sh")
    # set +m: keep `&` children in this process group (zsh job control
    # otherwise orphans them from killpg).
    let shellArgs = @["-c", "set +m; (" & command & ")" & redirections]
    var spawnCmd = shell
    var spawnArgs = shellArgs
    var spawnOpts = {poUsePath}
    when defined(linux):
      # Nim's fork path ignores poDaemon (SETPGROUP), and parent setpgid
      # after exec fails with EACCES. setsid makes the tracked pid a
      # session leader before the shell runs so kill(-pid) reaches
      # grandchildren.
      spawnCmd = "setsid"
      spawnArgs = @[shell] & shellArgs
    else:
      spawnOpts.incl poDaemon
    let p = startProcess(
      command = spawnCmd,
      args = spawnArgs,
      options = spawnOpts,
      workingDir = workDir
    )
    when not defined(linux):
      let pid = Pid(p.processID)
      discard setpgid(pid, pid)

    let (endKind, exitCode) = await waitForChildAsync(p, timeout)
    let elapsed = epochTime() - start
    p.close()

    var stdout = if fileExists(stdoutPath): readFile(stdoutPath) else: ""
    var stderr = if fileExists(stderrPath): readFile(stderrPath) else: ""
    if fileExists(stdoutPath): removeFile(stdoutPath)
    if fileExists(stderrPath): removeFile(stderrPath)

    var output = ""
    if stdout.len > 0:
      output.add "stdout:\n" & stdout
    if stderr.len > 0:
      if output.len > 0: output.add "\n"
      output.add "stderr:\n" & stderr

    let ms = int(elapsed * 1000)

    if endKind == weTimeout:
      return ToolResult(
        output: fmt"TIMEOUT after {timeout}s ({ms}ms)" & "\n\n" & output,
        isError: true)
    if endKind == weCancelled:
      return ToolResult(
        output: fmt"INTERRUPTED ({ms}ms)" & "\n\n" & output,
        isError: true)

    output = truncateOutput(output, outputLimit)

    var buf = fmt"exit_code: {exitCode}" & "\n"
    buf.add fmt"duration_ms: {ms}" & "\n\n"
    buf.add output

    return ToolResult(output: buf, isError: exitCode != 0)

  (def, run)
