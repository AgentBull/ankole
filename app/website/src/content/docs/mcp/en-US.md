---
title: MCP server reference
description: How Model Context Protocol servers are declared and loaded — the openai.yaml dependency model, the two transports, timeouts, and how enabled skills contribute servers.
section: Reference
order: 201
---

Ankole agents can call Model Context Protocol (MCP) servers as tools during a turn. This page is the reference for how an MCP server is declared, which transports are supported, and how the set of servers an agent sees is built.

The decisive property, stated up front: MCP servers are not configured at the agent level. They are declared as tool dependencies inside a skill's `openai.yaml`, and an agent sees the union of MCP servers from its **enabled** skills. There is no separate "agent MCP config" file — the skill is the only registration source.

## Where a server is declared

A skill declares its MCP dependencies in its `openai.yaml` metadata, under `dependencies.tools`. Each entry has `type: mcp`, a `value` (the server name), an optional `description`, a `transport`, and transport-specific fields. A skill may declare up to 64 dependencies.

```yaml
# inside a skill's openai.yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup tool"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MCP_HTTP_TOKEN
      timeout_ms: 60000
    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: npx -y @example/mcp-server
      timeout_ms: 120000
```

When a turn runs, the Agent Computer loads the MCP declarations from every enabled skill, deduplicates by server name, and starts the servers. Two skills that declare the same server name contribute one server, with both skills recorded as the source.

## The two transports

An MCP dependency is one of two transports, and the schema is strict — a field that belongs to one transport is rejected on the other.

### `streamable_http`

A remote server reached over HTTP. Fields:

| Field | Meaning |
|---|---|
| `url` | the server's HTTP URL (validated as a URL) |
| `bearer_token_env_var` | the name of an environment variable whose value is sent as the bearer token |
| `timeout_ms` | optional request timeout |

Use `streamable_http` for hosted MCP servers you authenticate to with a token. The token itself never goes in the YAML — only the name of the environment variable that holds it, so the secret stays in [WorkerEnv](../worker-env/) and out of the skill bundle.

### `stdio`

A local server started as a subprocess. Fields:

| Field | Meaning |
|---|---|
| `command` | the command line to start the server (1–1024 characters) |
| `timeout_ms` | optional request timeout |

Use `stdio` for MCP servers shipped as executables or `npx`-style packages. The server runs as a child process of the worker for the duration of the turn's MCP use.

## Timeouts

The default MCP timeout is 360,000 ms (six minutes). The minimum is 100 ms. Set `timeout_ms` on a dependency when a server needs more or less than the default. A tool call that exceeds the timeout is cancelled, so a misbehaving MCP server cannot stall a turn indefinitely.

## Server names

A server name is 1–1024 characters, trimmed, with no control characters. It is the key the model sees and the key the loader deduplicates on, so a stable, descriptive name matters: rename a server and the model loses any cached understanding of it, and two skills that intend the same server must use the same name to be merged.

## How the enabled set is built

The loader reads the `openai.yaml` of every skill the agent has enabled — not every skill the installation ships. A skill that is declared but not enabled on the agent contributes no MCP servers. Enabling a skill that declares MCP servers makes those servers available on the agent's next turn; disabling it removes them. This keeps the MCP surface a projection of the agent's effective capabilities, not a second configuration surface an operator has to manage separately.

A generation hash is computed from the actual enabled skill metadata files that contribute each declaration, so the loader can tell when the set has materially changed and restart servers as needed.

## What MCP in Ankole is not

It is not a place to mount arbitrary long-running services. MCP servers are tools a turn calls; they start, answer, and stop on the turn's schedule. It is not a way to bypass the permission boundary — the agent calls MCP tools as itself, under its own authority. And it is not configured per agent; the skill is the registration source, so enabling and disabling skills is how an operator changes which MCP servers an agent sees.

## Next steps

- For the skills that declare MCP dependencies, read the [Agent Library](../agent-library/) developer page.
- For the environment variables a `bearer_token_env_var` resolves to, read [WorkerEnv secrets](../worker-env/).
- For the worker that runs MCP tools during a turn, read the [Agent Computer](../agent-computer/) developer page.
