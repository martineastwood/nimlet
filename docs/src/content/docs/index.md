---
title: nimlet
description: A local coding agent for your repository. A native binary with fast startup, low memory, and idle CPU until it works.
template: splash
hero:
  title: Nimlet Coding Agent
  tagline: Fast to start, light on memory, no CPU until you ask.
  actions:
    - text: Install
      link: /guides/install/
      variant: primary
      icon: right-arrow
    - text: Quickstart
      link: /guides/quickstart/
      variant: secondary
      icon: right-arrow
    - text: View on GitHub
      link: https://github.com/martineastwood/nimlet
      variant: secondary
      icon: external
---

<div class="landing-shell not-content">
  <p class="landing-lede">Point Nimlet at a repo, describe the change, and it inspects, edits, runs the commands you approve, and keeps the session. Extend it in any language so it works the way you do.</p>

  <section class="landing-terminal" aria-labelledby="landing-terminal-title">
    <div class="landing-terminal-bar">
      <div class="landing-terminal-dots" aria-hidden="true"><span></span><span></span><span></span></div>
      <span id="landing-terminal-title">your-project</span>
      <span class="landing-terminal-mode">act mode</span>
    </div>
    <pre class="not-content"><code><span class="landing-prompt">$</span> nimlet
<span class="landing-input">› Fix the failing parser test and run the focused test.</span>
<span class="landing-muted">plan</span>   Inspect the parser and its tests
<span class="landing-muted">read</span>   src/parser.nim, tests/parser_test.nim
<span class="landing-muted">edit</span>   Apply the smallest safe change
<span class="landing-muted">bash</span>   nimble test parser
<span class="landing-success">done   The focused test passes.</span></code></pre>
  </section>

  <section class="landing-section" aria-labelledby="landing-runtime-title">
    <p class="landing-kicker">Native binary</p>
    <h2 id="landing-runtime-title">A small process you can keep close to the work</h2>
    <p class="landing-section-intro">Nimlet compiles to native code. There is no language runtime to install, startup is fast, and memory stays low enough to run one process per branch, workspace, or CI job.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>Small process</h3>
        <p>Compiled to native code, not interpreted. Startup is fast and memory use stays low, so you can run several Nimlet processes without a heavy runtime behind each one.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Idle when waiting</h3>
        <p>It waits on you, a provider, or a subprocess. No polls, no timers, no idle CPU.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Your provider, your keys</h3>
        <p>Requests go straight to the API you pick. Credentials stay in your environment or in <code>~/.nimlet/auth.json</code>.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Parallel-friendly</h3>
        <p>Run independent processes for separate workspaces, branches, or jobs. Each one has its own queues and session.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-work-title">
    <p class="landing-kicker">In your repository</p>
    <h2 id="landing-work-title">From a task to a tested change</h2>
    <p class="landing-section-intro">Ask for the outcome you want. Nimlet gathers context from the project, makes the smallest edit that fits, and runs the checks you approve.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>See the whole workspace</h3>
        <p>Read files, search by pattern, inspect Git history, and attach the context that matters instead of pasting files in.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Plan before you act</h3>
        <p>Start in read-only plan mode, switch to act mode when you are ready, and reuse the investigation instead of starting over.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>You decide what runs</h3>
        <p>Reads, searches, and workspace edits run freely. Shell commands and extensions ask the first time, with per-session and per-project grants.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Come back later</h3>
        <p>Queue the next thought while a turn runs, resume a saved session, and let compaction make room for longer tasks.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-customize-title">
    <p class="landing-kicker">Extend it</p>
    <h2 id="landing-customize-title">Any language. No SDK.</h2>
    <p class="landing-section-intro">An extension is a program Nimlet starts and keeps running. Python, Go, Rust, JavaScript, a shell script: if it can read stdin and write stdout, it can add tools, slash commands, hooks, and live status to Nimlet. There is no client library and no language lock-in.</p>
    <div class="landing-extend">
      <div class="landing-code">
        <div class="landing-code-bar"><span>.nimlet/extensions/notes/extension.mjs</span></div>
        <pre class="not-content"><code><span class="landing-muted">#!/usr/bin/env node</span>
<span class="kw">import</span> readline <span class="kw">from</span> <span class="str">'node:readline'</span>&#10;
<span class="kw">const</span> send = (message) => process.stdout.write(JSON.stringify(message) + <span class="str">'\n'</span>)
send({
  type: <span class="str">'register'</span>,
  commands: [{ name: <span class="str">'note'</span>, description: <span class="str">'Append a note to NOTES.md'</span> }],
  tools: [{
    name: <span class="str">'save_note'</span>,
    description: <span class="str">'Save a note about the current work.'</span>,
    input_schema: { type: <span class="str">'object'</span>, properties: { text: { type: <span class="str">'string'</span> } }, required: [<span class="str">'text'</span>] },
  }],
})&#10;
<span class="kw">for await</span> (<span class="kw">const</span> line <span class="kw">of</span> readline.createInterface({ input: process.stdin })) {
  <span class="kw">const</span> message = JSON.parse(line)
  <span class="kw">if</span> (message.type === <span class="str">'shutdown'</span>) <span class="kw">break</span>
}</code></pre>
      </div>
      <div class="landing-grid">
        <article class="landing-card">
          <span class="landing-card-index">01</span>
          <h3>Stay in the language you ship</h3>
          <p>JSON lines on stdin and stdout. No plugin host, no bundle step, no FFI into the agent process.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">02</span>
          <h3>Spawn a tool, or keep a process</h3>
          <p>A <code>tool.json</code> executable runs per call. An extension stays up, sees session events, and can push status whenever it likes.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">03</span>
          <h3>Commands, tools, and hooks</h3>
          <p>Register slash commands, model tools, and lifecycle hooks from the same program. Reply when you have something to change.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">04</span>
          <h3>Files next to the work</h3>
          <p>Put extensions in <code>.nimlet/extensions</code> or the portable <code>~/.agents/extensions</code> layout other agents already share.</p>
        </article>
      </div>
    </div>
    <div class="landing-links">
      <a href="/guides/extensions-and-hooks/" class="landing-link"><span>Persistent extensions</span><small>A long-running program in any language: tools, commands, hooks, and live status.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/external-tools/" class="landing-link"><span>External tools</span><small>Expose a one-shot executable as a typed model tool.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/skills/" class="landing-link"><span>Skills</span><small>Load Markdown procedures only when a task calls for them.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/prompt-templates/" class="landing-link"><span>Prompt templates</span><small>Turn recurring requests into slash commands.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/instructions/" class="landing-link"><span>Instructions</span><small>Set project and personal rules that reach every request.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-section landing-split" aria-labelledby="landing-interfaces-title">
    <div>
      <p class="landing-kicker">One agent, several surfaces</p>
      <h2 id="landing-interfaces-title">Use the interface that fits the job</h2>
      <p class="landing-section-intro">The same agent is an interactive TUI, a one-shot command, a JSON event stream, or a long-running RPC process.</p>
    </div>
    <div class="landing-links">
      <a href="/guides/interactive-tui/" class="landing-link"><span>TUI</span><small>Work in the terminal with queues, mentions, and shortcuts.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/quickstart/" class="landing-link"><span>Print mode</span><small>Run one turn and keep stdout to the final answer, including from a pipe.</small><span aria-hidden="true">↗</span></a>
      <a href="/reference/json-mode/" class="landing-link"><span>JSON mode</span><small>Emit versioned JSONL events for a single run.</small><span aria-hidden="true">↗</span></a>
      <a href="/reference/rpc-mode/" class="landing-link"><span>RPC mode</span><small>Drive a long-running process with prompts, steering, follow-ups, and interrupts.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-start" aria-labelledby="landing-start-title">
    <div>
      <p class="landing-kicker">Start in a few lines</p>
      <h2 id="landing-start-title">Bring your provider. Keep your project.</h2>
      <p>Install the release binary on macOS, Linux, or Windows through WSL, set a provider key, and launch nimlet from the workspace you want to work on.</p>
    </div>
    <pre><code><span class="landing-prompt">$</span> curl -fsSL https://nimlet.niminal.dev/install.sh | sh
<span class="landing-prompt">$</span> export OPENROUTER_API_KEY=your-key
<span class="landing-prompt">$</span> cd /path/to/your/project
<span class="landing-prompt">$</span> nimlet</code></pre>
  </section>

  <p class="landing-footer-link"><a href="/guides/install/">Install nimlet</a>, <a href="/guides/quickstart/">read the quickstart</a>, or <a href="https://github.com/martineastwood/nimlet">view nimlet on GitHub</a>.</p>
</div>
