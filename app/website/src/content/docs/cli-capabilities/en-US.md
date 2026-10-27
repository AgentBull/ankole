---
title: Worker CLI capabilities
description: Ship an Agent capability as a shell command whose --help carries the contract, and place one-sentence pointers where the Agent makes the related decision.
section: Developer guide
order: 114
---

Several Ankole capabilities ship as shell commands inside the Agent Computer rather than as model-visible tools, so Agents invoke them from the shell just like `gh` or `kubectl`. `ankole-pod` (`pages.*`, `base.*`, `applet build|publish|pull`), `ankole-files`, `ankole-browser`, webhook endpoint commands, and automation job commands all follow this pattern.

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

**Generic knowledge lives in `--help`; domain knowledge lives in the plugin Skill.** Universal rules that hold across every use of the CLI belong in `--help`, while a Skill integrating a specific external service documents only service-specific details. The GitHub webhook Skill, for instance, opens by pointing the Agent to `create-webhook-cli --help` for the platform webhook contract and then covers only GitHub hook creation, ping verification, delivery reconciliation, and GitHub's hook quota—letting future integrations reuse the generic contract without duplication.

## Automation jobs

An automation job runs a deterministic script in response to a trigger instead of waking an Agent conversation on every event. Any checkback, cron schedule, or webhook endpoint can specify an `automation_job_id`; omitting that field keeps the default direct Agent wakeup.

To create one, the Agent creates a workspace directory with `main.ts`, tests setup and non-SDK branches manually, and registers the directory with `create-automation-job-cli`. Registration uploads the directory to a new control-plane drive folder at `automation/<directory name>-<random suffix>` and returns that path as `drive_prefix`. On each trigger fire, the Worker copies the current contents of `drive_prefix` into a fresh ephemeral run directory and executes `main.ts` with Bun, so any files written into the working directory are discarded when the run ends. To update the script later, the Agent runs `ankole-files put <dir> <drive_prefix>`, applying the change immediately without re-registering.

Each run receives the Agent's latest WorkerEnv plus an invocation-scoped `MCPORTER_CONFIG` generated from the Agent's currently enabled Skills. Rather than guessing which MCP server the script might call, the Worker exposes all enabled MCP servers so the script can invoke a tool via `mcporter` over stdin JSON—without loading Skill markdown instructions or relying on a persistent mcporter config in Agent Home.

Inside a platform run, the SDK provides `context()` and `emitEvent(payload)`, where `context().event` carries the same CloudEvents envelope that a direct trigger would append as a Signal. A script can exit quietly without calling `emitEvent`, or call `emitEvent` one or more times to append durable `automation_job.emitted` Signals to the owner session (`emitEvent` never falls back to stdout; its promise resolves only after the Signal commits in PostgreSQL). Because `context()` and `emitEvent` exist only during managed platform runs, direct `bun main.ts` executions test setup and pure logic branches; after registration, fire a real test trigger to verify every branch that calls the SDK and inspect its durable run record.

Every trigger consumption creates a durable run row in the same PostgreSQL transaction that claims the checkback, advances the cron schedule, or accepts the webhook. Script exceptions, non-zero exit codes, and timeouts count as terminal script outcomes and do not retry. Losing a Worker mid-run, by contrast, counts as an infrastructure failure and dispatches a new fenced attempt via the Oban wake edge—because replays can repeat side effects, scripts must be idempotent.

Agents manage automation jobs during an active turn with four commands:

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

In the Console, **Automation Jobs** displays each job alongside its recent run statuses, attempt counts, error messages, exit codes, and bounded stdout/stderr tails, while `create-automation-job-cli --help` serves as the normative model-facing specification.

## Requirements for a new CLI capability

- Place the implementation under `app/agent_computer/src/cli/`, using one directory per command family.
- Print the complete contract from `--help` and `-h` on stdout with exit code `0`, requiring neither an active turn nor network access; because command wrappers prepend a subcommand, scan the entire argument list for the help flag.
- Emit a brief usage line on invalid arguments rather than dumping the full contract document.
- Place a neutral one-sentence pointer on every decision surface where an Agent would naturally need the capability, stating the condition and naming `--help`.
- When pairing the CLI with an external-integration Skill, open `SKILL.md` with a pointer to `--help` and restrict the Skill body to external-system specifics.
