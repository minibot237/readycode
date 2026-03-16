# readycode

An agent that drives Claude Code through long-running, multi-step work.

## The Problem

Claude Code is great at executing well-scoped tasks in a single conversation. But real work — documenting an entire codebase, implementing a feature across many files, refactoring a module — takes many sequential steps where each step depends on what you learned in the last one.

Today you do this manually: run Claude Code, read the output, figure out the next prompt, paste it in, repeat. readycode automates that loop.

## How It Works

Two channels, one driving agent:

- **Thinking channel** — a separate Claude context that sees the full plan, progress so far, and results from the last step. It decides what to do next, evaluates whether work is on track, and formulates the next implementation prompt.
- **Implementation channel** — a Claude Code terminal session that receives prompts from the thinking channel and executes them. This is where files actually get read, written, and tested.

The loop:
1. User provides a high-level goal ("document this codebase", "implement auth from this spec")
2. Thinking channel breaks it into steps and generates the first prompt
3. Implementation channel (Claude Code) executes the prompt
4. Output flows back to the thinking channel
5. Thinking channel evaluates progress, decides next step, generates next prompt
6. Repeat until done or escalate to user

## Key Design Decisions

**Why two channels instead of one?**
Context efficiency. The implementation channel burns context on file contents, diffs, and tool use. The thinking channel stays lean — it sees summaries and results, not raw file contents. This lets the thinking stay coherent across many more steps than a single context could handle.

**What's the thinking channel?**
Claude API. Stateless calls with a managed context window. readycode owns the message history and can summarize/compress as needed.

**What's the implementation channel?**
A real Claude Code process running in a terminal. readycode sends prompts to its stdin and reads output. Claude Code handles all the file I/O, tool use, and git operations.

**When does it stop?**
The thinking channel decides. It can: continue to the next step, pause and ask the user for input, or declare the work complete. There's a step budget to prevent runaway loops.

## Tool Use

The thinking channel can use tools beyond just prompting Claude Code:

- **Read files** — peek at specific files to inform the next prompt without burning implementation context
- **Run commands** — lightweight checks (test output, git status, file existence) to verify progress
- **Summarize** — compress implementation output before adding it to thinking context

## What It's Good For

- "Document every module in this codebase" — systematic, repetitive, benefits from consistent approach
- "Implement this feature spec" — multi-file changes where each step informs the next
- "Refactor X to use Y" — find all instances, change them one by one, verify each works
- "Review and fix all TODO comments" — scan, prioritize, address sequentially

## What It's Not

- Not a CI/CD tool — it's interactive, meant to run while you watch (or don't)
- Not an autonomous agent with internet access — it operates on local code
- Not a replacement for Claude Code — it's a driver for Claude Code

## Status

Just getting started. This document is the first artifact.
