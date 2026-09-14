# Nimlet TODO

## Remove active I/O polling

Replace fixed-interval readiness checks with OS events or completion futures.
Timers remain appropriate for real deadlines and active rendering throttles.

Current polling paths:

- `src/rpc.nim`: checks stdin, then sleeps 10ms; this can wake roughly 100 times
  per second while RPC mode is idle.
- `src/childproc.nim`: checks `peekExitCode()` every 10ms and rereads output
  files while shell tools run.
- `src/extension_runtime.nim`: checks the response channel every 25ms despite
  already having a blocking reader thread.
- `src/tools/search_tool.nim`: polls the worker response every 2ms.
- `src/agent.nim`: checks Codex login completion every 50ms.

Implementation order:

1. Make RPC input block on stdin and the cancellation pipe.
2. Complete extension request futures from reader/update events.
3. Use pipe readiness plus an OS child watcher for shell output and exit.
4. Replace search and login polling with futures or event notifications.

Reuse the existing `kqueue` support, cancellation pipes, blocking extension
reader, and update signals instead of adding a scheduler.

Acceptance criteria:

- Idle RPC mode has no recurring wakeups.
- A quiet child process does not cause recurring wakeups.
- Output and extension responses wake the agent immediately.
- Cancellation remains responsive and timeout deadlines remain enforced.
- Add an idle RPC smoke check alongside the existing idle smoke test.
