---
title: Models and providers
description: Switching provider and model, thinking levels, and hosted web search.
---

nimlet talks to one provider at a time. A provider is where requests go and
which key signs them; a model is the id you ask for there. Everything else — your
config, your sessions, your instructions — stays the same when you switch.

## The wired providers

| Provider | Default model | Key variable | Endpoint |
| --- | --- | --- | --- |
| `anthropic` | `claude-sonnet-4-6` | `ANTHROPIC_API_KEY` | `https://api.anthropic.com/v1/messages` |
| `codex` | — | — | — |
| `google` | `gemini-3.5-flash-lite` | `AI_STUDIO_API_KEY` | `https://generativelanguage.googleapis.com/v1beta` |
| `hyper` | `deepseek-v4-flash` | `HYPER_API_KEY` | `https://hyper.charm.land/v1/chat/completions` |
| `mistral` | — | — | — |
| `openai` | `gpt-5` | `OPENAI_API_KEY` | `https://api.openai.com/v1/responses` |
| `opencode` | `deepseek-v4.1-flash` | `OPENCODE_API_KEY` | `https://opencode.ai/zen/go/v1/chat/completions` |
| `opencodezen` | `deepseek-v4-flash` | `OPENCODE_API_KEY` | `https://opencode.ai/zen/v1/chat/completions` |
| `openrouter` | `deepseek/deepseek-v4-flash-0731` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1/chat/completions` |

`opencode` is the paid OpenCode Go subscription, `opencodezen` the pay-per-use
OpenCode Zen catalog. Both are signed with the same `OPENCODE_API_KEY` — the Go
subscription and Zen balance live on the same OpenCode account. Both gateways
serve a model on its own wire format; nimlet routes each model by its models.dev
catalog entry and falls back to Chat Completions, so model ids need no
per-format setup. That includes the gateway's Gemini models, which go to the
native Google endpoint under the same base and keep their own features, hosted
search among them.

Those are the defaults when your config says nothing: with the matching
environment variable set, `nimlet` starts against OpenRouter and
`deepseek/deepseek-v4-flash-0731`.

```text
/provider anthropic
```

switches provider, and picks that provider's last model — the one you used before,
remembered in `providers.anthropic.last_model`. Switching back and forth therefore
costs one command, not two. `/provider` alone prints the active name, and the
choice is saved as `default_provider` in your config.

`--provider NAME` does the same for one run, without saving.

## Choosing a model

```text
/model                          prints the current id
/model claude-opus-4-6          switches, and saves it
```

Typing `/model ` opens suggestions: your current and default model first, then
catalog matches for the active provider as you type, up to 50 entries, each
showing the provider and its context size. The filter starts at two characters,
so `/model claude` gives you the Claude models the catalog knows about.

A model id is whatever the provider calls it. On OpenRouter that is usually
`vendor/model`; on the first-party providers it is the bare id. nimlet does not
translate ids between providers, and it will not stop you from typing one that
does not exist — the first request is what tells you.

`--model ID` overrides for a single run. `--api-key KEY` and `--thinking LEVEL`
do the same for their settings.

Resuming a session restores the provider and model that session was using, so
picking up old work asks the same model again. That restore does not change your
saved defaults.

## The model catalog

nimlet keeps a copy of the public [models.dev](https://models.dev) catalog at
`~/.nimlet/models-dev.json` and reads it from disk. A missing or stale copy is
refreshed in the background at startup, so no lookup ever blocks on the network
and a failed fetch cannot stop you working.

The catalog is what tells nimlet:

- the **context window**, used for the `ctx 42%` footer gauge and for deciding
  when to compact
- which **thinking levels** the model actually supports
- whether the model **accepts images**
- **prices**, which is where the cost figures in `/stats` come from

```text
/models refresh
```

fetches the catalog (20 second timeout) and replaces the cache atomically. If the
fetch fails you get `Could not refresh model metadata; using existing cache.` and
the old file stays. The same fetch runs by itself at startup whenever the cache is
missing or older than a day; until it lands, lookups use the older copy or their
built-in fallbacks.

Lookups fail open. For a model the catalog does not have, nimlet falls back: the
context window comes from a per-family estimate (1M for Gemini, GPT-5, and
GPT-4.1; 200k for Claude and GPT-4o-class models; 128k otherwise), images are
assumed to be supported, the full thinking ladder is offered, and no prices are
shown.

## Thinking levels

The ladder is `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. What a
level does depends entirely on the model, so nimlet asks the catalog and adapts:

```text
/thinking                  prints the active level, e.g. "off" or "high"
/thinking high             sets it for later turns, and saves it
/thinking none             turns reasoning off
```

- The menu you see while typing `/thinking ` lists only the levels that model has.
- If you ask for a level the model does not offer, nimlet snaps to the nearest one
  it does; a tie goes to the higher effort, and `none` never snaps upward.
- On a model with no reasoning support at all, setting a level reports
  `(unsupported by model)` and nothing is sent.
- With no setting anywhere, the level is `(provider default)`: your `reasoning`
  blocks in provider options pass through untouched.

Two wires exist behind those levels, chosen by the model:

- **Effort-based (current models).** Anthropic's known families take
  `low`/`medium`/`high`/`max`, and the newest take `low`/`medium`/`high`/`xhigh`/
  `max`. `minimal` is folded into `low`, and `xhigh` falls back to `max` where it
  is not offered. These use adaptive thinking with a summarized display, so
  `agent.max_tokens` is the combined cap on thinking plus answer.
- **Legacy budgets (older models).** Reasoning is enabled with a token budget:
  1024 for `minimal` up to 32000 for `xhigh`/`max`. The budget is added once to
  your answer allowance, so a `high` setting with `max_tokens: 4096` sends
  `max_tokens: 20096` for that request.

Two details worth knowing:

- Setting `agent.thinking` or running `/thinking` replaces any `reasoning`,
  `reasoning_effort`, or `thinking` block and `output_config.effort` in your
  provider options. Other options are left alone. This avoids two sources of truth
  fighting over the same field.
- `NIMLET_THINKING=high ./nimlet` overrides the config for one run, which is handy
  when you want to try a level without saving it.

A model can also require thinking. On those, `/thinking none` resolves to
`low (thinking required)` rather than sending an invalid request.

## Hosted web search

```text
/web on
```

turns on the provider's own search tool. It is hosted, not local: the provider
searches the public web as part of the same request, so there is no nimlet-side
fetching, nothing new to approve, and no extra tool output in your transcript.

It works on `anthropic`, `google`, and `openai`, and on Zen's Gemini models,
which nimlet sends to the provider's native Google endpoint. Anywhere else,
`/web` reports:

```text
on (this provider or model has no hosted search)
```

Hosted search is per model, not just per provider: switching to a Zen model that
is served on the gateway's OpenAI-compatible path turns it off again.

Hosted search is only offered to the model in act mode, and when it is active the
model is told to use it for current docs, APIs, and facts that are not in the
repository. The setting is saved as `agent.web_search`.

## Images and attachments

When you attach an image, or paste one, nimlet checks the catalog before sending
it. Models that accept image input get the image; models that do not have images
dropped from the request rather than failing the turn. Unknown models are assumed
to accept them.

## Costs in /stats

Prices come from the catalog, per million tokens, including separate cache read and
write rates. nimlet estimates the cost of each response and adds them up for the
session, so `/stats` can show:

```text
Latest: ↑1204  ↓356  R980  CH81.4%
Context: 42120 / 200000 (21%)
Latest cost: $0.0042
Session: ↑18904  ↓4210
Session cost: $0.0731
```

These are estimates from published prices, not billing. A provider's own dashboard
is the authority, and models missing from the catalog show no cost at all.

## Where choices are saved

`/model`, `/provider`, `/thinking`, `/web`, and `/theme` write to your config
immediately — the project config if the project is trusted and has a `.nimlet`
directory, otherwise the global one. That is why a model you picked last week is
already selected today.

Startup flags (`--provider`, `--model`, `--thinking`, `--api-key`, `--tools`) are
deliberately the opposite: they apply to one process and are never written back.

## Where to go next

- [Configuration](/guides/configuration/) for the config keys behind all of this
- [Context and compaction](/guides/context-and-compaction/) for how the context
  window is resolved and used
- [Commands and shortcuts](/reference/commands/) for `/doctor`, which prints the
  endpoint and key status without revealing a key
