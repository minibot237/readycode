# readycode

A native Mac app that decomposes large coding tasks and executes them through Claude Code — while you sleep.

## The Problem

Claude Code is brilliant within a single context window. But real work — building an app from a spec, documenting an entire codebase, implementing a feature that touches 30 files — is bigger than one session. The work needs to be broken into CC-sized pieces, sequenced, executed, and verified.

Today you do this manually: figure out the next chunk, write the prompt, run CC, check the result, repeat. readycode automates the whole pipeline — from planning through execution.

## Core Insight

**Files are the coordination layer.** CC sessions communicate through the filesystem, not through terminal parsing. The planner writes step files. The supervisor reads them and dispatches to the implementer. Results are fed back as files. Any session can pick up where the last left off because the state is on disk.

## How It Works

Three concerns, file-driven coordination:

### 1. Planning Pipeline (before any code runs)

Turns a big goal into CC-sized work units through progressive decomposition:

**Pass 1 — Phase Decomposition.** A planner session reads the full project specs/goals and breaks the work into major phases. Each phase becomes a file:

```
.readycode/plan/
  phase-01-app-shell.md
  phase-02-live-data.md
  phase-03-charts.md
  ...
```

**Pass 2 — Step Decomposition.** The planner (same or fresh session) reads all phases + original specs and breaks each phase into implementable steps:

```
.readycode/plan/
  step-01.1-bundle-structure.md
  step-01.2-metal-model.md
  step-01.3-widget-grid.md
  step-02.1-price-service.md
  ...
```

**Pass 3 — Validation.** Walk each step and ask: "Can a single CC session with fresh context execute this completely?" If not, split it further. Repeat until every step passes.

The result: an ordered sequence of step files, each one a self-contained prompt that CC can execute in one go.

**Adaptive complexity.** Simple tasks ("fix this bug", "add a README") might produce 1–3 steps total. The planner should recognize simple work and skip the multi-pass decomposition. A "document this codebase" might need 40 steps. The pipeline adapts to the scope.

Each step file has a standard format:
```markdown
# Step 1.3: Widget Grid View
> Build the 2x2 metal card layout with bid/ask/change display

[detailed implementation prompt for the implementer]

## Acceptance Criteria
- [ ] Four metal cards in a grid
- [ ] Bid price large and colored
- [ ] Click to select
```

The first line is the title (readycode displays it in the progress panel). The blockquote is the summary (shows in logs). The body is the implementation prompt. Acceptance criteria tell the reviewer what to check.

### 2. Execution Engine

Walks the step files in order:

1. **Pre-flight (Reviewer).** Readycode sends the reviewer: header context + the step file + current repo state. The reviewer can adjust the prompt if something from a previous step changes the approach, or approve it as-is. Writes `.readycode/dispatch/current-step.md` with the final prompt.

2. **Implementation.** Readycode sends the dispatch file content to the implementer (persistent CC PTY session). Implementer executes — reads files, writes code, runs tests.

3. **Post-flight (Reviewer).** Readycode feeds the implementer's output summary back to the reviewer. Reviewer checks against acceptance criteria and writes a status file:

```json
// .readycode/dispatch/status.json
{
  "step": "step-01.3-widget-grid.md",
  "result": "complete",       // complete | revise | blocked
  "notes": "All criteria met. Build succeeds.",
  "next": "step-01.4-app-menu.md"
}
```

4. **Advance or revise.** If `complete`, move to the next step. If `revise`, the reviewer writes revision notes and readycode sends the implementer another pass. If `blocked`, pause and notify the user.

5. **Repeat** until all steps are done.

### 3. Context Management

CC sessions have finite context windows. readycode manages this:

**Header file.** A persistent context file (`.readycode/header.md`) sent with every planner/reviewer call. Contains: project description, conventions, what's been built so far. Updated by the reviewer after each phase completes.

**Planner continuity.** The planner writes all its output as files. If context gets heavy during planning, it writes a handoff file (`.readycode/plan/handoff.md`) summarizing decisions made, and readycode starts a fresh planner session that reads the handoff + all step files generated so far.

**Reviewer continuity.** The reviewer is a persistent PTY session that builds context over time. It knows what happened in previous steps because it was there. When it feels context is getting heavy, it tells readycode — writes a handoff and gets a fresh session. The instruction is explicit: "If your context feels full, write a handoff file and tell me you need a fresh session."

**Implementer isolation.** Each step gets the implementer in a reasonably clean state. For long runs, readycode may restart the implementer PTY between phases (not between steps within a phase) to keep context fresh.

## The Three Roles

### Planner
- **When:** Before execution starts
- **Job:** Decompose the goal into CC-sized step files
- **Session:** Can be multiple sequential `-p` calls or a PTY session. Doesn't need to be persistent across the whole run — its output is files.
- **Context needs:** Reads project specs, existing code structure. Writes step files.

### Reviewer
- **When:** Between steps during execution
- **Job:** Pre-flight prompt adjustment, post-flight quality check, decide next action
- **Session:** Persistent PTY (Claude Code). Builds up project understanding over time.
- **Context needs:** Accumulates — knows what happened in previous steps. Manages its own context via handoff files when full.

### Implementer
- **When:** During step execution
- **Job:** Execute the implementation prompt — read files, write code, run commands, test
- **Session:** Persistent PTY (Claude Code) with bypass permissions. This is the session that does real work.
- **Context needs:** Per-step. Gets the dispatch prompt and works within a single step's scope.

## File Structure

```
.readycode/
  header.md                    # project context, sent with every planner/reviewer call
  config.json                  # telegram bot token, preferences

  plan/                        # output of the planning pipeline
    phase-01-app-shell.md
    phase-02-live-data.md
    step-01.1-bundle.md
    step-01.2-model.md
    step-01.3-grid.md
    ...
    handoff.md                 # planner context handoff (if needed)

  dispatch/                    # current execution state
    current-step.md            # the active implementation prompt
    status.json                # reviewer's verdict on last step

  logs/                        # per-run timestamped logs
    2026-03-16_20-13-10/
      planner.log
      reviewer.log
      implementer.log
      system.log

  completed/                   # finished step files (moved here after completion)
    step-01.1-bundle.md
    step-01.2-model.md
```

## UI

### Main Window

**Setup Panel (top)**
- **Working folder** — file picker for the target codebase
- **Task** — file path to specs/instructions, or direct text entry (saved to file)
- **Additional instructions** — extra context injected into the planner's prompt

**Progress Panel (center)**
- **Step list** — all steps from the plan, displayed as a checklist. Current step highlighted. Completed steps checked off. Grouped by phase.
- **Current step** — the title and summary of what's being executed right now
- **Run time** — elapsed time, prominently displayed
- **Progress** — "Step 7/23 · Phase 2/5"

**Log Panel (right)**
- **Running log** — human-readable narrative. Step headers from the step files, reviewer verdicts, implementer activity summaries.
- Filterable: All / Planner / Reviewer / Implementer / System

**Control Bar**
- Run state: Planning → Running → Paused → Blocked → Complete
- Start / Pause / Resume / Stop
- Thinker and Implementer buttons open xterm.js terminal windows

### Terminal Windows

Separate floating windows for reviewer and implementer PTYs:
- xterm.js in WKWebView for proper terminal rendering
- Positioned top-right (reviewer) and bottom-right (implementer)
- See the raw CC interaction in real-time

### Notifications (Telegram)

- **Blocked** — reviewer can't proceed, needs human input
- **Phase complete** — milestone notification with summary
- **All complete** — final notification with stats
- **Error** — CC crashed, context limit, build failure

## Architecture

### Native Mac App (Swift)

- Single-file Swift, `swiftc` compilation, same pattern as Minibot.app
- SwiftUI dashboard + NSWindow management
- WKWebView + xterm.js for terminal windows
- PTY hosting via `forkpty` for reviewer and implementer sessions
- File watching (DispatchSource or polling) for step/status files
- Timer-based orchestration loop

### Auto-Responses

A pattern-matching table for interactive prompts CC throws:
- Trust folder → Enter
- Install LSP plugin → Enter
- Growing list as we discover new prompts

### Permissions

- Implementer runs with `--dangerously-skip-permissions`
- Reviewer runs with `--dangerously-skip-permissions`
- Target codebase should be a git repo (everything reversible)
- App has its own TCC grants (Full Disk Access)

### Logging

Every PTY byte logged to disk, timestamped. Step headers logged to the system log. Reviewer verdicts logged. The log panel shows the human-readable version. Raw logs are for debugging.

## Key Design Decisions

**Why files instead of terminal parsing?**
We tried parsing markers from CC's TUI output. It doesn't work reliably — the terminal renders text with ANSI codes, cursor movements, line wrapping, and screen redraws that mangle structured markers. Files are clean, reliable, and inspectable. CC writes files naturally.

**Why progressive decomposition instead of one-shot planning?**
A single planning pass tends to either over-plan (50 micro-steps for a 3-step task) or under-plan (3 vague phases for complex work). Progressive decomposition adapts: simple tasks skip to execution fast, complex tasks get properly broken down. The validation pass catches steps that are still too big.

**Why a persistent reviewer instead of stateless checks?**
The reviewer needs to know what happened in previous steps. "The implementer created a stub PriceService in step 2.1" matters when reviewing step 2.2 which fills it in. A persistent session builds this understanding naturally. Handoff files handle the case where context gets full.

**Why separate planner and reviewer roles?**
The planner runs before execution and may need multiple passes with fresh context. The reviewer runs during execution and benefits from continuity. Different lifecycle, different context needs.

**Why restart implementer between phases but not steps?**
Steps within a phase are related — the implementer benefits from knowing it just created file X when asked to modify file X in the next step. But between phases, the context from phase 1 is noise when executing phase 3. A fresh session keeps the implementer focused.

## What It's Good For

- "Build this app from these specs" — the planning pipeline shines here
- "Document every module in this codebase" — systematic, many small steps
- "Implement this feature across the codebase" — multi-file, multi-step
- "Refactor X to use Y everywhere" — repetitive with verification
- Any work you'd kick off before bed and review in the morning

## What It's Not

- Not a CI/CD tool — it runs on your Mac, on your code
- Not a replacement for Claude Code — it's a supervisor that gets more out of CC
- Not fully autonomous — it can ask for help via Telegram when stuck

## Status

Working prototype. PTY management, xterm.js terminals, auto-responses, basic orchestration loop proven. Rebuilding orchestration layer around file-based coordination and the planning pipeline.
