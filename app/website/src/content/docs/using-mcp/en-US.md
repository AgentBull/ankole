---
title: Use an MCP-backed Skill
description: How an enabled Skill routes an Agent or Automation script to an MCP server through mcporter.
section: Developer guide
order: 123
---

Ankole integrates MCP servers behind Skills rather than exposing them directly to language models: each Skill defines domain routing and output-handling rules, while the pinned `mcporter` CLI handles protocol discovery and tool invocation for whichever tool the Skill selects.

To give an Agent a domain MCP integration, enable the Skill that declares that MCP dependency rather than trying to register an MCP server directly on the Agent; disabling the Skill removes its MCP server from the next execution.

## Main Agent and Background Agent Job

Ask the Agent for the business outcome you want rather than naming a raw MCP tool. When the request matches an enabled Skill, the Agent reads `SKILL.md`, picks the appropriate domain tool, fetches that single tool's JSON Schema if needed, and invokes `mcporter` with a JSON argument object over `stdin`.

Main Agents run `mcporter` via the `command` tool, whereas Background Agent Jobs invoke it inside the Codex terminal; neither surface registers the upstream MCP catalog as native model tools.

## Automation Job

Because Automation Jobs execute deterministic TypeScript without a language model, they do not read `SKILL.md` at runtime—the Agent authoring `main.ts` bakes the chosen MCP tool name, argument payload, timeouts, and output checks directly into the script.

Every Automation attempt receives the MCP servers of all currently enabled Skills through `MCPORTER_CONFIG`, alongside the Agent's latest WorkerEnv variables. Inside `main.ts`, invoke `mcporter` via `Bun.spawn`, write JSON arguments to child `stdin`, check the exit code, and parse `stdout`—never create a persistent `~/.mcporter/mcporter.json` file.

## Credentials

A Skill's `openai.yaml` references only an environment-variable name such as `MCP_HTTP_TOKEN`, while you store the actual secret value under [Environment variables](../worker-env/). Because the generated `MCPORTER_CONFIG` file records only that variable name, `mcporter` fails immediately if the variable is missing—never paste bearer tokens into chat messages, Skill Markdown, scripts, JSON files, or shell commands.

## Failures and result bounds

If a Skill contains a malformed MCP declaration or two enabled Skills define conflicting settings for the same server name, Agent Computer aborts setup before the command or Automation script starts. At call time, `mcporter` exits with a non-zero status on transport, protocol, schema, or upstream server errors.

Because shell and Automation output logs are size-bounded, follow the Skill's pagination, freshness, warning, and partial-result rules—a `0` exit code from `mcporter` means the RPC succeeded, not that the business query returned a complete dataset.

## References

- [MCP server reference](../mcp/) defines declaration and runtime behavior.
- [Writing a Skill](../writing-a-skill/) shows the authoring shape.
- [Environment variables](../worker-env/) defines credential storage.
