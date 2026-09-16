---
title: Context and compaction
description: Keeping long sessions alive without losing recent verbatim history.
---

Every model can only see so much text at once. That limit is the context window,
and a long working session will eventually fill it: your messages, the assistant's
replies, every tool call and its output, attachments, plus the parts of the
request you never see, like the system instructions and the tool schemas.

When that happens, nimlet does not stop and it does not throw history away.
It *compacts*: the older part of the conversation is summarized, the recent part
stays exactly as it was, and the session carries on.

## What counts toward the window

Everything in the request:

- your messages, including pasted text, images, and `@file` mentions
- assistant replies and their thinking
- every tool call and the output it produced
- the system instructions and tool schemas that come with each request

You can watch it fill up in the footer, where `ctx 42%` appears next to the model
name. It turns amber at 70% and red at 90%. `/stats` prints the same thing with
real numbers:

```text
Context: 84120 / 200000 (42%)
```

That window comes from, in order:

1. `agent.context_window` in your config, if you set it
2. the model catalog (the metadata nimlet keeps in `~/.nimlet/models-dev.json`)
3. a per-family guess: 200k for Claude, GPT-4o, and the o-series; 1M for GPT-5,
   GPT-4.1, and Gemini; 128k for most everything else, including unknown models

Pinning it explicitly is useful with a local model, a proxy, or a freshly
released model the catalog does not know yet:

```json title=".nimlet/config.json"
{
  "agent": {
    "context_window": 131072
  }
}
```

## When compaction happens

Before every model call, nimlet estimates how big the request about to be sent
is. If that estimate is above `context_window - reserve_tokens`, it compacts
first. `reserve_tokens` defaults to 16,384, which keeps room for the answer and
for the estimate being a little off.

When it happens on its own, you see it in the transcript:

```text
Auto-compacted context
Compacted up to event #96; kept recent verbatim (183204 tokens before).
```

You can also compact on demand:

```text
/compact
/compact focus on the API changes and the failing tests
```

`/compact` works whether or not auto-compaction is enabled, and any text you add
is passed to the summarizer as an instruction. If there is nothing old enough to
summarize, nimlet says so and leaves the session alone:

```text
Nothing to compact (recent history fits in keep window).
```

## What is kept, and what becomes a summary

nimlet walks backwards from the end of the conversation, adding up estimated
tokens until it has roughly `keep_recent_tokens` worth of history (20,000 by
default). That is the part that stays verbatim. Then it moves the cut backwards
to the start of the user message that owns that region, so an assistant reply and
its tool results are never separated from the request that produced them.

```text
  turns 1-40                              turns 41-52
┌───────────────┐───────────────────────┌───────────────────┐
│   summarized  │                       │  kept verbatim    │
└───────────────┘───────────────────────└───────────────────┘
                                        ↑
                                       cut
```

Everything before the cut is folded into a summary. Everything from the cut
onwards is sent to the model word for word. If the whole conversation already
fits inside the keep window, there is nothing to compact.

## What the summary contains

The summary is written by the same model you are using, with its output capped at
4096 tokens, and it is asked for a structured markdown document:

```markdown
## Goal
## Current task
## Important decisions
## Files inspected
## Files modified
## Important symbols/locations
## Commands run and results
## Errors/failures
## Outstanding work
## User preferences/instructions
## Next likely steps
```

The instructions around it are firm: keep exact snippets only when they matter,
do not invent facts, and prefer concrete paths, commands, and outcomes. Thinking
blocks become `(thinking omitted)` in the material sent to the summarizer, and
very long tool outputs are truncated.

Each new compaction folds the previous summary into the new one, so the summary
always describes the whole session up to that point rather than just the newest
chunk.

## Compaction changes what is sent, not what is saved

The session file is append-only, and compaction appends a single line to it:

```json
{"type":"compaction","summary":"## Goal\n…","first_kept_index":96,"tokens_before":183204}
```

Every earlier event is still there. What changes is the model-facing message
list: it becomes a user message containing the summary, followed by the kept
events:

```text
The conversation history before this point was compacted into the following
summary:
<summary>
…the summary…
</summary>
```

The transcript on screen still shows the full conversation, and reopening a
compacted session shows a `Context compacted` marker where the summary took over.
Nothing is deleted, so the file remains a complete record of what happened.

## When the estimate is not enough

Token counts are estimated cheaply (roughly one token per four characters), so the
real number can differ. If a provider still rejects a request as too long, nimlet
compacts with an instruction that prioritizes recovering, rebuilds the request,
and retries once:

```text
Context overflow - compacting and retrying…
```

If it overflows again, you get the provider's error and can compact manually or
start a fresh session with `/new`.

## Turning it off, and tuning it

```json title=".nimlet/config.json"
{
  "agent": {
    "compaction_enabled": false,
    "reserve_tokens": 32768,
    "keep_recent_tokens": 40000
  }
}
```

- `compaction_enabled: false` stops the automatic compaction only. `/compact`
  still works when you ask for it.
- A larger `reserve_tokens` compacts earlier and leaves more room for a long
  answer.
- A larger `keep_recent_tokens` keeps more recent history verbatim and summarizes
  less of it, at the cost of a bigger summary prompt.

Because the estimates are approximate, treat these numbers as guidance rather
than exact thresholds.

## Extensions can shape compaction

Two events let an extension get involved. `session_before_compact` receives the
session id, workspace, any instruction, the estimated token count, and the full
list of events. It can add an instruction to the summarizer:

```json
{"instruction": "Summarize the database migration work in extra detail."}
```

or provide the whole summary itself:

```json
{"compaction": {"summary": "## Goal\n…", "first_kept_index": 96}}
```

Returning `{"allow": false, "reason": "…"}` skips the compaction and shows your
reason instead. After compaction, `session_compact` fires with `did_compact`,
`summary`, `first_kept_index`, `tokens_before`, and the status message.

## Where to go next

- [Sessions](/guides/sessions/) for the file that keeps the full history
- [Extensions and hooks](/guides/extensions-and-hooks/) for the compaction events
  in context
- [Models and providers](/guides/models-and-providers/) for the context window
  catalog
