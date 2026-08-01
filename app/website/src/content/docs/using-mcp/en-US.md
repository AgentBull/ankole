---
title: Use an MCP-backed Skill
description: How an enabled Skill routes an Agent or Automation script to an MCP server through mcporter.
section: Developer guide
order: 123
---

Ankole uses MCP behind Skills. The Skill owns domain routing and result rules. The pinned mcporter CLI owns protocol discovery and calls for the one tool that the Skill selects.

For an Agent-specific domain integration, do not register an MCP server directly on the Agent. Enable the Skill that declares it. Disabling that Skill removes the dependency from the next execution. Release-defined Direct MCP tools are a separate platform contract and need no Skill.

## Main Agent and Background Agent Job

Ask the Agent for the business result, not for an MCP tool name. The Agent reads the matching Skill, chooses one tool, and inspects only that tool's current schema when needed. It then calls mcporter with a JSON argument object on stdin.

The Main Agent uses its command tool. A Background Agent Job uses its Codex terminal. Neither path exposes the complete MCP catalog as native model tools.

## Automation Job

An Automation Job does not read Skill instructions. The Agent that writes `main.ts` must encode the selected tool, arguments, bounds, and result checks in the script.

Each Automation attempt receives the current enabled Skill dependencies and release-defined Direct MCP servers through `MCPORTER_CONFIG`, plus the latest Agent WorkerEnv. Call mcporter with `Bun.spawn`, write JSON to stdin, check the exit code, and parse stdout. Do not create `~/.mcporter/mcporter.json`.

## Credentials

The Skill stores a credential variable name such as `MCP_HTTP_TOKEN`. Configure its value in [Environment variables](../worker-env/). The generated config contains the variable name, not its value.

If a variable is missing, the call fails. Do not paste a token into chat, a Skill, a script, an argument file, or a shell command.

## Failures and result bounds

An invalid declaration or conflicting server definition fails before the model command or Automation script starts. Transport, protocol, argument, and server errors produce a nonzero mcporter exit.

Command and Automation logs are bounded. Follow the Skill's pagination, freshness, warning, and partial-result rules. A successful process exit does not prove that a business result is complete.

## References

- [MCP server reference](../mcp/) defines declaration and runtime behavior.
- [Writing a Skill](../writing-a-skill/) shows the authoring shape.
- [Environment variables](../worker-env/) defines credential storage.
