---
title: Worker CLI capabilities
description: Ship an Agent capability as a shell command whose --help carries the contract, and place one-sentence pointers where the Agent makes the related decision.
section: Developer guide
order: 114
---

Several Ankole capabilities ship as shell commands inside the Agent Computer rather than as model-visible tools, so Agents invoke them from the shell just like `kubectl`. `ankole-pod` (`pages.*`, `base.*`, `applet build|publish|pull`), `ankole-files`, `ankole-browser`, webhook endpoint commands, and automation job commands all follow this pattern.

This page explains when to package a capability as a CLI and how Ankole's progressive disclosure pattern makes it discoverable and accurate without adding a JSON tool schema, a Skill catalog entry, or permanent system-prompt text.

## When a CLI is the right shape

Ship a capability as a Worker CLI when all three conditions hold:

- The Agent invokes it as part of a broader shell workflow alongside standard Unix commands, and scripts or Background Agent Jobs may also call it directly.
- It is needed only along a specific decision path—for example, an Agent that never sets up a webhook never needs to know that `create-webhook-cli` exists.
- Its inputs fit naturally into command-line flags rather than requiring a structured JSON tool schema.

Every model-visible tool consumes prompt tokens on every turn, whereas a CLI consumes zero context until the Agent enters the workflow where it is relevant.

## The disclosure architecture

Three conventions replace up-front tool registration and Skill indexing:

**`--help` is the contract document.** Calling `--help` prints everything that an Agent needs to use the command safely: what it does, its trust and security boundaries, its durability guarantees, and what a complete workflow looks like. Because `--help` ships inside the binary itself, it stays version-locked to the implementation and cannot drift like external prose. Write `--help` for a caller with zero prior context, emphasizing goals and invariants over rigid step-by-step recipes; `create-webhook-cli --help` is the canonical example.

**Pointers sit on the decision surfaces.** Agents discover the CLI through concise one-sentence pointers placed right where they make the adjacent decision—inside a related tool description, an external-system Skill, or another CLI's `--help`. Each pointer states when the capability applies and which `--help` command to read next, without biasing the Agent's choice. Every CLI capability must have at least one pointer on a surface that the Agent inevitably visits along that workflow.

**Generic knowledge lives in `--help`; domain knowledge lives in the plugin Skill.** Universal rules for a CLI belong in its `--help`. A Skill supplies the external service's operation contracts and points to platform capabilities when a task needs them. For example, a Toolkit upload operation uses a Pod file reference, so the Skill directs the Agent to `pod-content` to upload a Worker file before calling that operation.

## Automation jobs

Automation Jobs run published Applet Actions in Function Runtime. The Agent builds and publishes the Applet with `ankole-pod applet`, then uses `ankole-pod jobs` to discover Actions, create or configure Jobs, manage schedules and webhook endpoints, and inspect Runs. Read `ankole-pod --help` before invoking these commands.

An Applet server exports `{routes, actions}`. Each Action declares its handler, idempotency and concurrency policy. The handler reads `ctx.signal` and `ctx.job.config`, persists cursors through `ctx.state`, and can continue within a bounded Run using `continueSlice()`. External calls use `AnkoleRuntime.mcp`, or `AnkoleRuntime.admin.mcp` for team authority.

The same Job and source operations are available in the Applet Automation panel and through `useAppletJobs()` and `useJobSources(jobID)`. Inspect real Run input, result, error and logs after a test trigger. See [Automation Jobs](../automation-jobs/) for ownership and recovery.

## Requirements for a new CLI capability

- Place the implementation under `app/agent_computer/src/cli/`, using one directory per command family.
- Print the complete contract from `--help` and `-h` on stdout with exit code `0`, requiring neither an active turn nor network access; because command wrappers prepend a subcommand, scan the entire argument list for the help flag.
- Emit a brief usage line on invalid arguments rather than dumping the full contract document.
- Place a neutral one-sentence pointer on every decision surface where an Agent would naturally need the capability, stating the condition and naming `--help`.
- When pairing the CLI with an external-integration Skill, open `SKILL.md` with a pointer to `--help` and restrict the Skill body to external-system specifics.
