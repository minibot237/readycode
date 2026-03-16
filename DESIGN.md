# readycode

A native Mac app that drives two Claude Code sessions through long-running, multi-step work — while you sleep.

## The Problem

Claude Code is great at executing well-scoped tasks in a single conversation. But real work — documenting an entire codebase, implementing a feature across many files, refactoring a module — takes many sequential steps where each step depends on what you learned in the last one.

Today you do this manually: run Claude Code, read the output, figure out the next prompt, paste it in, repeat. readycode automates that loop.

## How It Works

Two Claude Code terminal sessions, one supervisor app:

- **Thinker** — a Claude Code session that sees the high-level goal, progress so far, and results from the last implementation step. It decides what to do next and formulates the next implementation prompt.
- **Implementer** — a Claude Code session pointed at the target codebase. It receives prompts from the thinker and does the actual file reading, writing, testing, and committing.
- **readycode** — a native macOS app that hosts both sessions as PTYs, reads their output streams, detects when each is idle/waiting for input, and writes prompts into them. It orchestrates the handoff between thinker and implementer.

The loop:
1. User provides a high-level goal ("document this codebase", "implement auth from this spec")
2. readycode prompts the thinker with the goal
3. Thinker outputs a plan and the first implementation prompt
4. readycode captures that prompt, writes it into the implementer's terminal
5. Implementer (Claude Code) executes — reads files, writes code, runs tests
6. readycode captures the implementer's output, writes a summary/status back to the thinker
7. Thinker evaluates progress, decides next step, outputs the next prompt
8. Repeat until the thinker declares done, or escalates to the user

## Architecture

### Native Mac App (Swift)

readycode is a macOS application, not a CLI tool. Reasons:

- **TCC permissions** — the app gets its own permission grants (Full Disk Access, etc.), isolated from the user's shell. Same pattern as Minibot.app.
- **PTY hosting** — the app spawns two pseudo-terminals via `forkpty`/`posix_openpt`, runs `claude` in each. Full read/write access to both streams.
- **Background operation** — runs unattended overnight. macOS app lifecycle keeps it alive, can show status in menu bar or a window.
- **Logging** — everything that flows through both PTYs gets logged to disk, timestamped. This is critical for debugging and understanding CC's output patterns.

### Terminal I/O

Each Claude Code session runs inside a PTY managed by readycode. The app:

- **Reads** the full output stream from each session (ANSI codes, tool output, everything)
- **Writes** prompts and responses into each session's stdin
- **Logs** all I/O to timestamped log files for post-hoc analysis

### Idle Detection

The key technical challenge: knowing when Claude Code has finished its current task and is waiting for input. This needs to be learned empirically.

Approach:
- Log everything, study the patterns
- Look for the input prompt marker (whatever CC prints when it's ready for the next message)
- May need to handle edge cases: permission prompts, error states, context limit warnings
- Start simple, iterate based on what the logs tell us

### Permissions / YOLO Mode

Both Claude Code sessions run with permissions bypassed:
- Default new sessions to bypass permissions (CC's built-in setting)
- No interactive approval prompts to block the loop
- The target codebase should be a git repo so everything is reversible

### Logging

readycode logs aggressively — every byte from both PTYs, timestamped. This serves two purposes:
1. **Debugging** — when something goes wrong at 3am, the logs tell the story
2. **Pattern learning** — we need to understand CC's output format to build reliable idle detection, question detection, and output parsing

## Key Design Decisions

**Why two CC sessions instead of one?**
Context efficiency. The implementer burns context on file contents, diffs, and tool use. The thinker stays lean — it sees summaries and results, not raw file contents. This lets the thinking stay coherent across many more steps than a single session could handle.

**Why not use the Claude API for the thinker?**
Both sessions are Claude Code. Same interface, same tool access, same capabilities. The thinker could use CC's tools to peek at files, check git status, etc. No API keys to manage, no separate billing, no different behavior to reason about.

**Why a Mac app and not a CLI?**
TCC permissions, proper app lifecycle for long-running background work, and a path to a UI for monitoring both streams live. CLI tools don't get their own TCC grants.

**When does it stop?**
The thinker decides. It can: continue to the next step, pause and ask the user for input, or declare the work complete. There's a step budget to prevent runaway loops.

## What It's Good For

- "Document every module in this codebase" — systematic, repetitive, benefits from consistent approach
- "Implement this feature spec" — multi-file changes where each step informs the next
- "Refactor X to use Y" — find all instances, change them one by one, verify each works
- "Review and fix all TODO comments" — scan, prioritize, address sequentially
- Long tasks you'd kick off before bed and review in the morning

## What It's Not

- Not a CI/CD tool — it runs on your Mac, on your code
- Not an autonomous agent with internet access — it operates on local repos
- Not a replacement for Claude Code — it's a supervisor for Claude Code

## Status

Design phase. This document is the first artifact.
