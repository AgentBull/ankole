---
name: lark-oa
description: "Operate bot-useful Lark work-management APIs as this digital employee's application: tasks, OKRs, and attendance. Use only when the installed endpoint explicitly supports bot identity."
default_enabled: true
category: productivity
tags: [lark, task, okr, attendance, oa]
metadata:
  upstream: https://github.com/larksuite/cli/tree/v1.0.69/skills
  upstream_tag: v1.0.69
  modified_for: Ankole bot-only Agent Plugin runtime
---

# Lark OA

Use `lark-cli` with the application bot identity supplied by this Agent's Lark signal binding. This skill deliberately keeps only OA operations that are meaningful under tenant access; it never impersonates an employee.

Before the first command, read [references/bot-runtime.md](references/bot-runtime.md). Then read the domain reference:

- Tasks, OKRs, and attendance: [references/tasks-okr-attendance.md](references/tasks-okr-attendance.md)
- Capability limits and permission failures: [references/unsupported-and-permissions.md](references/unsupported-and-permissions.md)

## Completeness contract

For every operation:

1. Run `lark-cli task|okr|attendance --help`.
2. Inspect the exact command's help and require bot identity support.
3. Run the displayed `lark-cli schema <service>.<resource>.<method>` before typed calls.
4. Execute with `--as bot --format json`.

All installed bot-capable endpoints in these three services are supported, even when a shortcut is not listed here. Personal task views and other person-only operations are unsupported rather than emulated.

Destructive Task or OKR operations may be marked `high-risk-write`. Use `--dry-run` first and pass `--yes` only after explicit confirmation.
