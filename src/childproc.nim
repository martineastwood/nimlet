## Shared wait/kill for spawned children (bash tool and extensions).

import std/[asyncdispatch, os, osproc, posix, times]
when defined(macosx) or defined(freebsd) or defined(netbsd) or
     defined(openbsd) or defined(dragonfly):
  import posix/kqueue
import tools/tool

const
  TailKeep* = 20_000
  TermGiveUpMs = 200

proc requestStop(p: Process, hard: bool) =
  let pid = Pid(p.processID)
  let sig = if hard: SIGKILL else: SIGTERM
  # Decide at kill time: Linux setsid() can complete after startProcess
  # returns, and kill(-pid) of our own group would take nimlet with it.
  if getpgid(pid) == pid:
    discard posix.kill(-pid, sig)
  else:
    discard posix.kill(pid, sig)

proc waitProcess(p: Process, timeoutMs: int): bool =
  ## Block until the child exits or timeoutMs elapses.
  ## True if something happened before the timeout. Nim's timed waitForExit
  ## SIGKILLs on expiry, so we wait ourselves and decide SIGTERM/cancel.
  if timeoutMs < 0:
    return false
  when defined(macosx) or defined(freebsd) or defined(netbsd) or
       defined(openbsd) or defined(dragonfly):
    let kqFD = kqueue()
    if kqFD == -1:
      return p.peekExitCode() != -1
    defer: discard posix.close(kqFD)
    var changes: array[1, KEvent]
    let n = 1
    changes[0] = KEvent(ident: p.processID.uint, filter: cshort(EVFILT_PROC),
      flags: EV_ADD.cushort, fflags: NOTE_EXIT)
    var tmspec: Timespec
    tmspec.tv_sec = posix.Time(timeoutMs div 1000)
    tmspec.tv_nsec = (timeoutMs mod 1000) * 1_000_000
    var ev: KEvent
    while true:
      let count = kevent(kqFD, addr changes[0], n.cint, addr ev, 1, addr tmspec)
      if count < 0:
        if osLastError().cint == EINTR:
          continue
        return p.peekExitCode() != -1
      return count > 0
  else:
    var fds: array[2, TPollfd]
    var n = 0
    fds[n] = TPollfd(fd: p.outputHandle.cint, events: POLLIN or POLLHUP)
    inc n
    let errFd = p.errorHandle.cint
    if errFd != p.outputHandle.cint:
      fds[n] = TPollfd(fd: errFd, events: POLLIN or POLLHUP)
      inc n
    while true:
      let ready = poll(addr fds[0], Tnfds(n), timeoutMs.cint)
      if ready < 0:
        if osLastError().cint == EINTR:
          continue
        return p.peekExitCode() != -1
      if ready == 0:
        return false
      # Drain child pipes so a leftover POLLIN cannot busy-loop.
      var buf: array[256, char]
      for i in 0 ..< n:
        if (fds[i].revents and (POLLIN or POLLHUP)) != 0:
          while posix.read(fds[i].fd, addr buf[0], buf.len) > 0:
            discard
      return true

proc stopChild(p: Process) =
  requestStop(p, hard = false)
  let giveUp = epochTime() + TermGiveUpMs / 1000
  while p.peekExitCode == -1:
    let left = int((giveUp - epochTime()) * 1000)
    if left <= 0:
      break
    discard waitProcess(p, left)
  if p.peekExitCode == -1:
    requestStop(p, hard = true)
    discard p.waitForExit(1000)

type
  WaitEnd* = enum
    weExited, weTimeout, weCancelled

proc waitForChildAsync*(p: Process, timeout: int,
                        shouldCancel: CancelCheck = nil):
                      Future[tuple[endKind: WaitEnd, exitCode: int]] {.async.} =
  let deadline = epochTime() + timeout.float
  while true:
    let code = p.peekExitCode()
    if code != -1:
      return (weExited, code)
    if (not shouldCancel.isNil and shouldCancel()) or cancelRequested():
      stopChild(p)
      return (weCancelled, -1)
    let remaining = deadline - epochTime()
    if remaining <= 0:
      stopChild(p)
      return (weTimeout, -1)
    await sleepAsync(min(10, max(1, int(remaining * 1000))))

proc truncateOutput*(output: string, limit: int): string =
  let outputLimit = max(2, limit)
  if output.len <= outputLimit:
    return output
  let keep = min(TailKeep, outputLimit div 2)
  let head = output[0 ..< (outputLimit - keep)]
  let tail = output[^keep .. ^1]
  head & "\n\n[... truncated " & $(output.len - outputLimit) & " bytes ...]\n\n" & tail
