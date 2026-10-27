---
title: MCP server reference
description: How Skill-backed MCP dependencies enter Main, Background, and Automation executions.
section: Reference
order: 201
---

Ankole integrates MCP servers behind Skills rather than maintaining an Agent-level MCP registry or a persistent `mcporter` configuration file.

Because Ankole never registers Skill MCP dependencies as native model tools or exposes full MCP tool catalogs to the model, each Skill remains the sole routing owner without introducing a competing tool-selection surface.

## Declare a dependency

Declare MCP dependencies under `dependencies.tools` in the Skill's `openai.yaml` file:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup service"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      protocol_version: 2026-07-28
      bearer_token_env_var: MCP_HTTP_TOKEN
      enabled_tools:
        - lookup

    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: bunx --bun @example/mcp-server
      disabled_tools:
        - delete_record
```

A single Skill can declare up to 64 dependencies. Ankole validates this schema strictly and rejects unknown fields or fields incompatible with the chosen transport.

### `streamable_http`

| Field | Meaning |
| --- | --- |
| `url` | HTTP or HTTPS server URL |
| `protocol_version` | Optional protocol mode: `auto`, `legacy`, or `2026-07-28` (defaults to `auto`) |
| `bearer_token_env_var` | Name of the environment variable holding the bearer token |
| `enabled_tools` | Optional allowlist of exact raw tool names |
| `disabled_tools` | Optional denylist of exact raw tool names |

Pin `protocol_version` only when the upstream server requires a specific MCP protocol revision. Store the actual bearer token in [Environment variables](../worker-env/), and reference only the variable name in `openai.yaml`.

### `stdio`

| Field | Meaning |
| --- | --- |
| `command` | Trusted command line used to spawn the MCP server |
| `enabled_tools` | Optional allowlist of exact raw tool names |
| `disabled_tools` | Optional denylist of exact raw tool names |

Agent Computer launches `stdio` servers via `/bin/sh -lc`, so use `stdio` only for trusted, first-party server commands.

Because the YAML declaration does not configure a call timeout, the Skill instructions or Automation script must pass `--timeout` on every `mcporter list` or `mcporter call` command.

## Enabled set and conflicts

Each execution receives the union of MCP dependencies declared across its currently enabled Skills. Multiple Skills may declare the same server name only if their connection fields, description, and tool filters match identically; otherwise, Agent Computer aborts execution setup with a conflict error.

The Skill's `ankole-runtime` frontmatter field determines which execution surface sees the Skill: Main Agents load `any` and `main` Skills, while Background Agent Jobs load `any` and `background_job` Skills. Because Automation Jobs do not run a language model, they receive the MCP dependencies of all currently enabled Skills regardless of `ankole-runtime`.

When you disable a Skill, Ankole removes its MCP dependencies starting on the next turn, Background Agent Job execution, or Automation Job attempt.

## Generated mcporter config

Before each execution, Agent Computer writes a temporary `0600` configuration file and exposes its path via `MCPORTER_CONFIG`. That file always sets `imports: []` so `mcporter` never merges configuration from Agent Home, project directories, Codex, editors, or the host, and Agent Computer deletes the file as soon as the execution finishes.

The generated file holds only server connection metadata and credential environment-variable names—never decrypted WorkerEnv secret values.

At runtime, Main Agents invoke `mcporter` through the `command` tool, Background Agent Jobs invoke it from the Codex terminal, and Automation Jobs spawn it from `main.ts` with `Bun.spawn`.

## Select and call one tool

Skill instructions should direct the Agent to pick the specific domain tool first and fetch its live JSON Schema only when needed:

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

Pass the JSON argument object over `stdin` rather than interpolating JSON into a shell command string:

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation scripts follow the same pattern: pass the exact argument vector to `Bun.spawn`, write the JSON payload to child `stdin`, verify the exit code, and parse `stdout`.

## Security limits

Treat all MCP responses as untrusted input. Neither the Skill layer nor `mcporter` validates output schemas, schedules calls by MCP annotations, prompts for per-tool human approval, or redacts WorkerEnv secrets from tool results. Use this integration path only for trusted, first-party MCP Skills, and scope the remote credential itself to enforce read/write boundaries.

## Next steps

- To author the Skill instructions, read [Writing a Skill](../writing-a-skill/).
- To configure the bearer token, read [Environment variables](../worker-env/).
- To operate an enabled capability, read [Using MCP](../using-mcp/).
