# MCP-Backed Skills

Ankole exposes MCP capabilities through skills and the existing shell tools. It
does not add remote MCP tools to the main agent's native model tool registry.
The same contract works for main-agent turns and Codex delegation turns.

## Ownership

- A skill owns the model-facing routing instructions and a checked-in MCP
  client config, normally `config/mcporter.json` below its `SKILL.md`.
- The Agent Computer image owns a pinned `mcporter` command and its runtime
  dependencies. Both main-agent commands and Codex subagent commands execute
  that command inside the existing bubblewrap sandbox.
- The control plane owns operator-managed credentials. WorkerEnv resolves the
  effective variables for an agent and sends them only on the ephemeral turn
  path to Agent Computer.
- The remote provider owns MCP initialization, tool schemas, and tool results.

This keeps MCP as an implementation detail of a skill rather than a second tool
registry or protocol loop inside Ankole's agent loop.

## Skill Contract

Each MCP-backed skill must:

1. Pass its config explicitly on every invocation:

   ```bash
   mcporter --config <skill-directory>/config/mcporter.json list <server> --schema
   mcporter --config <skill-directory>/config/mcporter.json call <server>.<tool> --args '<json>' --output json
   ```

2. Keep stable, non-secret endpoints in the skill config. Secret headers and
   parameters must reference WorkerEnv variables such as `${PROVIDER_API_KEY}`.
3. Set `imports` to an empty list unless the skill deliberately composes
   another checked-in config. It must not discover user or host MCP configs.
4. Use ephemeral connections by default. A daemon or persisted OAuth state
   needs a concrete latency or provider requirement and a separate ownership
   design.
5. Tell the model how to select tools and interpret freshness, warnings,
   partial results, and provider-specific semantics. The CLI only transports
   MCP calls; it does not replace domain guidance.

## Runtime And Security

The command tool and the Codex delegation turn both receive the same resolved
WorkerEnv map for the agent. Their bubblewrap view mounts the image-provided
Bun global package closure read-only, so `mcporter` and its dependencies are
available without copying credentials or dependency trees into a skill.

A skill config is not an authorization boundary: a model with shell access can
read any skill that is enabled for that agent and use environment variables
available to that turn. Credential isolation therefore belongs in WorkerEnv
scope and skill enablement. Secrets must not be committed, embedded in images,
or written into workspace config files.

## Client Compatibility Boundary

Skills depend on the small command contract above, not on mcporter internals.
The image currently supplies the upstream CLI because it already handles
Streamable HTTP, SSE, stdio, initialization, schema discovery, and calls. If
Ankole later needs tighter startup, auditing, or dependency control, it can
replace `/usr/local/bin/mcporter` with an Ankole-owned compatible
implementation without changing skill packages or the agent loop.
