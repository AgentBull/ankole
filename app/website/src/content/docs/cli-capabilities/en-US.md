---
title: Worker CLI capabilities
description: Ship an Agent capability as a shell command whose --help carries the contract, and place one-sentence pointers where the Agent makes the related decision.
section: Developer guide
order: 114
---

Some Ankole capabilities are shell commands in the Agent Computer, not model-visible tools. The Agent calls them through the shell, like `gh` or `kubectl`. Webhook endpoint commands and automation job commands use this shape.

This page describes when to ship a capability in this shape and the disclosure architecture that makes it discoverable and correct without a tool registration, a Skill index entry, or a system prompt section.

## When a CLI is the right shape

A capability fits the CLI shape when all of these hold:

- The Agent uses it inside a larger shell workflow, next to other commands, and a script or a background agent job can also need to call it.
- It matters only on one decision path. An Agent that never creates a webhook never needs to know `create-webhook-cli` exists.
- It does not need a JSON schema for the model to fill; a few flags carry the input.

A model-visible tool costs context in every turn. A CLI costs nothing until the Agent walks the path where it matters.

## The disclosure architecture

Three rules replace tool registration and Skill indexing:

**`--help` is the contract document.** The CLI's `--help` output carries the knowledge an Agent needs to use the capability correctly: what it is, the trust model, the guarantees, and what a complete use looks like. It ships with the binary, so it is versioned with the behavior it describes and can never drift the way a separate document can. Write it for a reader with no other context, and state goals and constraints rather than procedures. `create-webhook-cli --help` is the reference example.

**Pointers sit on the decision surfaces.** Discovery comes from one-sentence pointers placed where the Agent is already making the adjacent decision: a tool description, a Skill that integrates a specific external system, or another CLI's `--help`. Each pointer states the condition under which the capability is relevant and where to read more, without steering the choice. Every capability of this shape must have at least one pointer on a surface that the Agent always visits on the relevant path — the path that makes a capability meaningful also names the surfaces that disclose it.

**Generic knowledge lives in `--help`; domain knowledge lives in the plugin Skill.** The contract that holds for every use of the capability belongs to `--help`. A Skill that integrates one external system keeps only what that system adds. The GitHub webhook Skill, for example, opens by directing the Agent to `create-webhook-cli --help` for the general webhook contract and covers only hook registration, ping verification, delivery reconciliation, and the GitHub hook quota. A second integration reuses the whole generic layer for free.

## Automation jobs

An automation job is a deterministic script that consumes a trigger instead of waking an Agent conversation for every delivery. A checkback, cron schedule, or webhook endpoint can name an `automation_job_id`. A trigger without this field keeps the direct wake behavior.

The Agent creates one directory inside its Agent Home, adds `main.ts`, checks its setup and non-SDK branches by hand, and registers the directory with `create-automation-job-cli`. The Worker resolves the directory and entrypoint through real paths at registration and at every run. It executes the current files with Bun, so an edit takes effect without another registration.

Each attempt receives the latest Agent WorkerEnv and an invocation-scoped `MCPORTER_CONFIG` generated from the current enabled Skills. The Worker does not predict which server the script will use. The script can call one selected MCP tool with mcporter and stdin JSON. Automation does not read Skill instructions, and it does not use a persistent Agent Home mcporter config.

The run SDK provides `context()` and `emitEvent(payload)`. `context().event` is the same CloudEvents envelope that a direct trigger would append as an ActorEvent. A script can finish without an emission for a silent success, or call `emitEvent` one or more times to append durable `automation_job.emitted` events to the owner session.

`context()` and `emitEvent` exist only inside a platform run. A direct `bun main.ts` run can check the setup and branches that do not call these functions. After registration, use a test trigger for every SDK branch and inspect its durable run. `emitEvent` does not fall back to stdout: its promise resolves only after the ActorEvent is durable.

Every trigger consumption creates a durable run in the same PostgreSQL transaction that claims the checkback, advances the cron schedule, or accepts the webhook. Script exceptions, non-zero exits, and timeouts are terminal script outcomes and do not retry. A Worker loss is an infrastructure failure: the run gets a new fenced attempt through the existing Oban wake edge. Replays can repeat script side effects, so the script must make repetition harmless.

Use these commands inside an active Agent turn:

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

The Console Automation Jobs page shows each job and its recent run status, attempts, error, exit code, and bounded stdout and stderr tails. `create-automation-job-cli --help` remains the normative model-facing guide.

## Requirements for a new CLI capability

- Place the implementation under `app/agent_computer/src/cli/`, one directory per command family.
- Serve the full contract from `--help` and `-h`, on stdout with exit 0, without any turn or network dependency. The command wrappers prepend a subcommand, so detect the help flag anywhere in the argument list.
- Keep a short usage string for argument errors; it is not the contract document.
- Add a pointer sentence to each decision surface where an Agent would need the capability, and keep the pointer free of preference: state the condition, name the `--help`.
- When a plugin Skill integrates the capability with an external system, open the Skill with the pointer to `--help` and keep the Skill to the domain delta.
