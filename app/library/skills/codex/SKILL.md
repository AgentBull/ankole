---
name: codex
description: "Delegate bounded Codex sub-agent runs."
default_enabled: true
category: autonomous-ai-agents
tags: [Sub-Agent, Codex, OpenAI, Automation, Knowledge-Work]
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Sub-Agent, Codex, OpenAI, Automation, Knowledge-Work, Coding-Agent, Code-Review, Refactoring]
    related_skills: [claude-code, hermes-agent]
---

# Codex Sub-Agent Runs

Use `codex_delegate` when you want another autonomous agent loop to take a bounded task and work through it inside the BullX workspace computer. Codex can plan, inspect files, write and run commands or scripts, validate outputs, and return a concise final message or artifact.

This is useful when the main agent can define the goal and review the result, but should not personally drive every command step.

## When to call

Call `codex_delegate` when:

- the task needs several command/script/file iterations
- the task may take a while and can run in the background
- the task can be described with a clear goal, inputs, constraints, and output
- multiple independent tasks can run in parallel
- you want a second agent loop to investigate, build, analyze, or produce an artifact

Do not call it for simple reads, one-shot commands, targeted edits, or deterministic transformations. Use `read_file`, `command`, `terminal`, or `patch` directly for those.

## How to prompt Codex

Give Codex a complete task prompt. It sees its prompt and the workspace, not your hidden conversation state.

Include:

- the goal and definition of done
- relevant files, paths, data sources, and `workdir`
- allowed changes and output locations
- validation commands or checks
- what the final answer should contain
- constraints that should not be guessed

Keep the prompt narrow enough that Codex can finish without turning into an open-ended responsibility.

## One-Shot Runs

Use `wait=true` or omit `wait` when the main run needs the result before continuing:

```text
codex_delegate(
  prompt="<complete bounded task prompt>",
  workdir="/workspace/user-files/<workdir>"
)
```

For non-repository workspace work, set `skipGitRepoCheck=true` when appropriate:

```text
codex_delegate(
  prompt="<complete bounded task prompt>",
  workdir="/workspace/user-files/<workdir>",
  skipGitRepoCheck=true
)
```

## Background Runs

Use `wait=false` for slow work or parallel work:

```text
codex_delegate(
  prompt="<complete bounded task prompt>",
  workdir="/workspace/user-files/<workdir>",
  wait=false
)
```

The tool returns a `session_id`. Monitor it with:

```text
process(action="poll", session_id="<id>")
process(action="log", session_id="<id>")
process(action="kill", session_id="<id>")
```

Be patient with long-running sub-agents. Poll for progress and inspect logs, but do not keep restarting or interfering unless there is a clear failure.

## Parallel Runs

Parallel Codex runs are appropriate when the tasks are independent. Give each run a separate workdir or output path so they do not race on the same files.

```text
codex_delegate(prompt="<task A>", workdir="/workspace/user-files/<workdir-a>", wait=false)
codex_delegate(prompt="<task B>", workdir="/workspace/user-files/<workdir-b>", wait=false)
process(action="list")
```

After completion, inspect each final message, logs, changed files, and artifacts before combining results or taking irreversible actions.

## Operational Notes

- Use the native `codex_delegate` tool. It handles Codex credentials, prompt files, logs, and final-message capture.
- OpenAI auth should be configured as encrypted BullX runtime credentials:
  `skill/codex/auth_json` -> `/workspace/temp/.codex/auth.json`, and optional
  `skill/codex/config_toml` -> `/workspace/temp/.codex/config.toml`.
- `workdir` must stay under `/workspace`.
- Codex runs inside the same BullX workspace computer. Use explicit workdirs and output paths when separation matters.
- Put durable artifacts under `/workspace/user-files`; `/workspace/temp` is disposable.

## Rules

1. **Prefer `codex_delegate`** — it is the BullX path for Codex sub-agent runs.
2. **Delegate bounded work** — give Codex a complete task, not an open-ended role.
3. **Give enough context** — include required files, paths, constraints, success criteria, and expected output.
4. **Use background mode deliberately** — set `wait=false` for slow or parallel work, then monitor with `process`.
5. **Separate concurrent runs** — use distinct workdirs or output paths.
6. **Review before acting** — inspect final messages, logs, diffs, generated files, or validation output before committing to the user.
7. **Avoid unbounded nesting** — do not ask Codex to spawn more agents unless orchestration depth is explicit and bounded.
