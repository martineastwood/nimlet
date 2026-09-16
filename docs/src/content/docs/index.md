---
title: nimlet
description: A local coding agent for software projects.
template: splash
hero:
  title: Nimlet
  tagline: Built in Nim. Compiled to C. Uses less RAM than your browser's 40th tab.
  actions:
    - text: Start with nimlet
      link: /guides/quickstart/
      variant: primary
      icon: right-arrow
    - text: Explore the docs
      link: /reference/tools/
      variant: secondary
      icon: open-book
---

<div class="landing-shell">
  <p class="landing-lede">The coding agent with instant startup, low memory, and CPU that stays idle unless it's actually working. Use it in your terminal, in CI, or run in parallel without your laptop fan filing a complaint.</p>

  <section class="landing-terminal" aria-labelledby="landing-terminal-title">
    <div class="landing-terminal-bar">
      <div class="landing-terminal-dots" aria-hidden="true"><span></span><span></span><span></span></div>
      <span id="landing-terminal-title">your-project</span>
      <span class="landing-terminal-mode">act mode</span>
    </div>
    <pre><code><span class="landing-prompt">$</span> nimlet

<span class="landing-input">› Fix the failing parser test and run the focused test.</span>

<span class="landing-muted">plan</span>   Inspect the parser and its tests
<span class="landing-muted">read</span>   src/parser.py, tests/parser.test.js
<span class="landing-muted">edit</span>   Apply the smallest safe change
<span class="landing-muted">bash</span>   npm test -- parser.test.js

<span class="landing-success">done   The focused test passes.</span></code></pre>
  </section>

  <section class="landing-section" aria-labelledby="landing-runtime-title">
    <p class="landing-kicker">A small process with room to work</p>
    <h2 id="landing-runtime-title">Keep the agent close to the job.</h2>
    <p class="landing-section-intro">Nimlet is a compiled native binary with no language toolchain required on the machine where you run it. It stays quiet while you decide what to do next, then gives you clean interfaces for people, scripts, and automation.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>Compiled and lightweight</h3>
        <p>Nimlet starts quickly, and keep CPU and memory overhead low so you can focus on your work rather than your system's resources.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Ready for CI</h3>
        <p>Use print mode for a final answer, JSON mode for versioned events, or RPC mode when a controller needs a long-running process.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Parallel-friendly</h3>
        <p>Run independent nimlet processes for separate workspaces, branches, or jobs. Each process has its own queues and session.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Bring your provider</h3>
        <p>Choose a wired provider and model, keep credentials in your environment or config, and send requests directly to it.</p>
      </article>
    </div>
  </section>

  <section class="landing-section landing-split" aria-labelledby="landing-customize-title">
    <div>
      <p class="landing-kicker">Make it yours</p>
      <h2 id="landing-customize-title">Extend the workflow around the task.</h2>
      <p class="landing-section-intro">Keep the built-in surface small, then add the context, procedures, commands, and actions your projects need. Your customizations stay in familiar files and executables alongside the work.</p>
    </div>
    <div class="landing-links">
      <a href="/guides/instructions/" class="landing-link"><span>Instructions</span><small>Set project and personal rules that reach every request.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/skills/" class="landing-link"><span>Skills</span><small>Load detailed procedures only when a task calls for them.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/prompt-templates/" class="landing-link"><span>Prompt templates</span><small>Turn recurring requests into slash commands.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/external-tools/" class="landing-link"><span>External tools</span><small>Expose your own executables as typed model tools.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/extensions-and-hooks/" class="landing-link"><span>Persistent extensions</span><small>Add tools, commands, hooks, and live status updates with any programming language.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-work-title">
    <p class="landing-kicker">A focused surface for software work</p>
    <h2 id="landing-work-title">From a task to a tested change.</h2>
    <p class="landing-section-intro">Ask for the outcome you want. Nimlet can inspect the project, make a change, run the checks you approve, and keep the conversation available when you come back.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>See the whole workspace</h3>
        <p>Read files, search by pattern, inspect Git history, and attach the context that matters to the request.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Choose the level of control</h3>
        <p>Start in read-only plan mode, switch to act mode when ready, and approve shell commands or other risky actions as they appear.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Keep working in context</h3>
        <p>Queue the next thought while a turn runs, resume saved sessions, and let compaction make room for longer tasks.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Fit your workflow</h3>
        <p>Add instructions, skills, prompt templates, short-lived tools, or persistent extensions when the built-ins are not enough.</p>
      </article>
    </div>
  </section>

  <section class="landing-section landing-split" aria-labelledby="landing-interfaces-title">
    <div>
      <p class="landing-kicker">One agent, several ways to use it</p>
      <h2 id="landing-interfaces-title">Use the surface that fits the job.</h2>
    </div>
    <div class="landing-links">
      <a href="/guides/interactive-tui/" class="landing-link"><span>TUI</span><small>Work conversationally in the terminal with queues, mentions, and shortcuts.</small><span aria-hidden="true">↗</span></a>
      <a href="/reference/json-mode/" class="landing-link"><span>JSON mode</span><small>Run one turn and consume versioned JSONL events from a script.</small><span aria-hidden="true">↗</span></a>
      <a href="/reference/rpc-mode/" class="landing-link"><span>RPC mode</span><small>Drive a long-running nimlet process with prompts, steering, and follow-ups.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/external-tools/" class="landing-link"><span>Tools and extensions</span><small>Connect your own executables when your project needs a specialized action.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-start" aria-labelledby="landing-start-title">
    <div>
      <p class="landing-kicker">Start in a few lines</p>
      <h2 id="landing-start-title">Bring your provider. Keep your project.</h2>
      <p>With the `nimlet` binary installed and available on your `PATH`, set a provider key and launch it from the workspace you want to work on.</p>
    </div>
    <pre><code><span class="landing-prompt">$</span> export OPENROUTER_API_KEY=your-key
<span class="landing-prompt">$</span> cd /path/to/your/project
<span class="landing-prompt">$</span> nimlet</code></pre>
  </section>

  <p class="landing-footer-link"><a href="/guides/quickstart/">Read the quickstart</a> or <a href="https://github.com/martineastwood/nimlet">view nimlet on GitHub</a>.</p>
</div>
