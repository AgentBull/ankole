---
title: MCP server reference
description: How Skill-backed MCP dependencies enter Main, Background, and Automation executions.
section: Reference
order: 201
---

Ankole uses MCP behind Skills for domain integrations. It does not keep an Agent-level MCP registry or a persistent mcporter config.

Skill MCP dependencies are not registered as native model tools. The Agent does not receive their complete MCP catalogs. This keeps the Skill as the routing owner and avoids a second tool-selection surface.

## Declare a dependency

Add MCP dependencies under `dependencies.tools` in the Skill `openai.yaml`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup service"
      transport: streamable_http
      url: https://mcp.example.com/mcp
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

One Skill can declare at most 64 dependencies. The schema is strict and rejects unknown or transport-incompatible fields.

### `streamable_http`

| Field | Meaning |
| --- | --- |
| `url` | HTTP or HTTPS server URL |
| `bearer_token_env_var` | Environment variable name that contains the bearer token |
| `enabled_tools` | Optional exact raw-name allowlist |
| `disabled_tools` | Optional exact raw-name denylist |

Store the token in [Environment variables](../worker-env/). Put only its variable name in the Skill.

### `stdio`

| Field | Meaning |
| --- | --- |
| `command` | Trusted command line that starts the server |
| `enabled_tools` | Optional exact raw-name allowlist |
| `disabled_tools` | Optional exact raw-name denylist |

Agent Computer runs the command through `/bin/sh -lc`. Use stdio only for trusted, first-party server commands.

The declaration does not set a call timeout. The Skill or Automation script passes `--timeout` to each mcporter list or call command.

## Enabled set and conflicts

An execution receives the union of MCP dependencies from its current enabled Skills. Two Skills can use the same server name only when their connection, description, and filter fields match. A conflict stops execution setup.

`ankole-runtime` controls which model can read the Skill. The Main Agent uses `any` and `main` Skills. Background Agent Jobs use `any` and `background_job` Skills. Automation Jobs do not run a model, so they receive dependencies from all current enabled Skills without an `ankole-runtime` filter.

Disabling a Skill removes its dependency from the next turn, Background execution, or Automation attempt.

## Generated mcporter config

Agent Computer writes a unique `0600` config for each execution and injects its path as `MCPORTER_CONFIG`. The file always contains `imports: []`, so mcporter does not merge Agent Home, project, Codex, editor, or host configuration. The file is removed when the execution ends.

The file contains only connection facts and credential variable names. It never contains WorkerEnv secret values.

Main Agents call mcporter through the command tool. Background Agent Jobs call it through the Codex terminal. Automation Jobs call it from `main.ts` with `Bun.spawn`.

## Native model-visible MCP boundary

No bundled model-visible MCP server currently ships with Ankole. A future concrete integration must use the same `mcp__<server>` namespace, tool names, descriptions, and deferred loading behavior in Main and Background. Ankole passes the server JSON Schema into each runtime unchanged. Main uses its Responses tool owner; Background uses Codex native MCP and lets Codex own that projection. Ankole does not rewrite one runtime's schema to imitate the other, and it does not add an empty registry or a general local MCP loader for this future case.

## Select and call one tool

The Skill must select one domain tool before schema discovery. Inspect only that tool when its current schema is needed:

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

Send the argument object through stdin. Do not interpolate JSON into shell text:

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

An Automation script uses the same argv, writes JSON to the child stdin, checks the exit code, and parses stdout.

## Security limits

MCP output is untrusted input. The Skill and mcporter path does not provide Ankole's former native output-schema validation, MCP annotation scheduling, tool-level approval UI, or result redaction against every WorkerEnv secret. Use it for trusted, first-party MCP Skills. The remote credential scope remains the real read or write permission boundary.

## Next steps

- To author the Skill instructions, read [Writing a Skill](../writing-a-skill/).
- To configure the bearer token, read [Environment variables](../worker-env/).
- To operate an enabled capability, read [Using MCP](../using-mcp/).
