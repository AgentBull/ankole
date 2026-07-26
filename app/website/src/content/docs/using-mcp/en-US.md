---
title: Using MCP servers
description: How an Ankole agent uses Model Context Protocol servers as tools — where a server is declared, the two transports, the default timeout, why the agent sees a server only when the skill that declares it is enabled, and how an operator changes which MCP servers an agent sees.
section: User guide
order: 35
---

Model Context Protocol (MCP) servers are how an Ankole agent calls an external tool service during a turn — a lookup API, a local command server, a hosted knowledge base. This page is the operator view of MCP in use: what an MCP server is to the agent, where it is declared, the two transports, and how the set of servers an agent sees is built. It is the use-side companion to the [MCP server reference](../mcp/).

The decisive property, stated up front: MCP servers are not configured at the agent level. They are declared as tool dependencies inside a skill's `openai.yaml`, and an agent sees the union of MCP servers from its **enabled** skills. There is no separate "agent MCP config" — the skill is the only registration source, so enabling and disabling skills is how you change which MCP servers an agent sees.

## What an MCP server is to the agent

To the agent, an MCP server is a set of tools. The model sees the server's tools in the turn's tool set, calls them like any other tool, and gets results back. The agent does not know the transport, the URL, or the command — those are declared in the skill, not shown to the model. The worker config in `app/agent_computer/src/tools/mcp/` loads the declarations, starts the servers, and exposes their tools.

This is the same projection model the [Agent Library](../agent-library/) uses elsewhere: the effective capability surface is what the agent actually sees, and it is built from enabled skills, not from a second configuration surface an operator has to manage.

## Where a server is declared

A skill declares its MCP dependencies in its `openai.yaml`, under `dependencies.tools`. Each entry has `type: mcp`, a `value` (the server name), an optional `description`, a `transport`, and transport-specific fields. A skill may declare up to 64 dependencies.

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

- **`streamable_http`** — a remote server reached over HTTP. It takes a `url`, a `bearer_token_env_var` (the name of the environment variable whose value is sent as the bearer token), and an optional `timeout_ms`. Use it for hosted MCP servers you authenticate to with a token. The token itself never goes in the YAML — only the name of the environment variable that holds it, so the secret stays in [WorkerEnv](../worker-env/) and out of the skill bundle.
- **`stdio`** — a local server started as a subprocess. It takes a `command` (1–1024 characters) and an optional `timeout_ms`. Use it for MCP servers shipped as executables or `npx`-style packages. The server runs as a child process of the worker for the duration of the turn's MCP use.

## Timeouts

The default MCP timeout is 360,000 ms (six minutes). The minimum is 100 ms. Set `timeout_ms` on a dependency when a server needs more or less than the default. A tool call that exceeds the timeout is cancelled, so a misbehaving MCP server cannot stall a turn indefinitely. Pick the timeout by the worst realistic latency of the server, not by a guess; a server that sometimes takes 90 seconds should not be given a 60-second budget.

## How the enabled set is built

The loader reads the `openai.yaml` of every skill the agent has **enabled** — not every skill the installation ships. A skill that is declared but not enabled on the agent contributes no MCP servers. Enabling a skill that declares MCP servers makes those servers available on the agent's next turn; disabling it removes them.

A generation hash is computed from the actual enabled skill metadata files that contribute each declaration, so the loader can tell when the set has materially changed and restart servers as needed. The consequence for the operator: the MCP surface tracks the agent's effective capabilities exactly. There is no drift between "what skills are on" and "what MCP servers are loaded."

## How to change which servers an agent sees

Because the skill is the only registration source, the operator's lever is skill enablement, through the [Agent Library](../agent-library/) default-then-override model:

1. **Add or remove a server** by authoring or editing the skill that declares it. See [Writing a skill](../writing-a-skill/).
2. **Turn a server on for an agent** by enabling the skill that declares it. A builtin skill with `default_enabled: true` already contributes its servers to every agent.
3. **Turn a server off for an agent** by narrowing (disabling) the skill that declares it.

For an HTTP server that needs a token, the corresponding environment variable must be set in [WorkerEnv](../worker-env/); the `bearer_token_env_var` in the YAML is only the name, and an unset variable means the server authenticates without a token or fails at call time.

## What the operator does not touch

The transport wiring, the server start/stop lifecycle, and the deduplication-by-name are the loader's job, not flags an operator sets. A server name is 1–1024 characters, trimmed, with no control characters — it is the key the model sees and the key the loader deduplicates on, so rename a server and the model loses any cached understanding of it, and two skills that intend the same server must use the same name to be merged. Those are constraints to respect when authoring the skill, not runtime knobs.

## Next steps

- For the full schema, transports, and loader behavior, read the [MCP server reference](../mcp/).
- For the catalog and enablement model that decides which skills — and therefore which MCP servers — are on, read the [Agent Library](../agent-library/) developer page.
- For how to author a skill that declares an MCP dependency, read [Writing a skill](../writing-a-skill/).
- For the environment variables a `bearer_token_env_var` resolves to, read [Worker environment](../worker-env/).
