# MCP-Backed Skills

Ankole registers external MCP capabilities through enabled Skills. A Skill's
`agents/openai.yaml` is the single declaration consumed by the main Agent
Computer and by BackgroundAgentJob preparation. Job preparation applies the
same parser to the currently effective standalone Skills and enabled member
Skills inside selected Agent Plugins. There is no independent MCP registry, shell bridge, persisted
worker-side client config, or Job/Plugin option map.

## Ownership

- The Skill owns domain routing instructions in `SKILL.md` and stable MCP
  connection metadata in `agents/openai.yaml`.
- The control plane owns Skill enablement and encrypted operator credentials.
  WorkerEnv resolves the effective in-memory variables for one agent turn.
- Main Agent Computer owns the native TypeScript MCP client and exposes one
  allowlisted model tool named `mcp`.
- BackgroundAgentJob preparation resolves the declarations from the current
  effective standalone Skills matching its saved names and the current enabled
  Agent Plugin Skills, then writes ordinary Codex MCP configuration. Codex owns
  those clients. Main-Agent connections and Job
  connections are never shared.
- The remote MCP server owns initialization, schemas, and tool results.

## Skill Declaration

Only entries under `dependencies.tools[]` with `type: "mcp"` are accepted. The
main consumer supports the two transport shapes below:

```yaml
dependencies:
  tools:
    - type: "mcp"
      value: "remote-data"
      description: "Remote data service"
      transport: "streamable_http"
      url: "https://example.com/mcp"
      bearer_token_env_var: "REMOTE_DATA_API_KEY"

    - type: "mcp"
      value: "local-tool"
      description: "Local stdio service"
      transport: "stdio"
      command: "/opt/local-tool/bin/server --stdio"
```

`type`, `value`, `description`, `transport`, `url`, and `command` follow the
Codex `agents/openai.yaml` metadata shape. `bearer_token_env_var` is an Ankole
extension on the same tool entry for non-interactive HTTP bearer credentials;
Codex's metadata loader ignores the unknown field. It contains an environment
variable name, never the secret value.

The loader rejects malformed entries, unsupported transports, unknown fields
inside an MCP entry, oversized metadata, and metadata symlinks that escape the
Skill directory. Missing `agents/openai.yaml` or missing `dependencies.tools`
means the Skill has no MCP dependency.

## Enablement And Conflicts

The main turn reads declarations only from the actual filesystem directories
of Skills enabled in the resolved agent context. A disabled Skill cannot add a
server. A Skill marked `long_running: true` is excluded from the main-agent MCP
allowlist because the main agent may only route that Skill to a
BackgroundAgentJob.

Servers are keyed by `value`. Repeated declarations deduplicate only when
transport, URL or command, bearer environment-variable name, and description
are identical. Any mismatch is a hard preparation error naming the conflicting
server and Skills; Ankole never selects one declaration by precedence.

## Main-Agent Tool Contract

The model sees at most one MCP tool, named `mcp`:

- `list` without `server` never opens a connection. It returns allowlisted
  server names and descriptions, plus tool names and short descriptions only
  when that catalog is already present in the bounded worker-process cache.
- `list` with one `server` lazily connects only to that selected server, fills
  its catalog cache, and returns bounded tool names and short descriptions. It
  never fans out to all enabled servers. Neither list form exposes URLs,
  commands, credentials, or schemas.
- `describe` requires one server and one tool and returns only that tool's input
  schema and optional output schema.
- `call` requires one server and one tool and invokes only that selected tool.
  It cannot call a disabled server or a tool absent from the server's validated
  catalog.

Tool catalogs are cached in the worker process with a five-minute TTL and a
32-entry LRU bound. The key is a one-way hash over the complete server
identity, the contributing enabled Skill metadata-file generation, and the
effective credential identity. A declaration refresh or WorkerEnv credential
change therefore misses the old entry; a failed refresh is never cached.
Pending loads are not shared across turns, so one turn's cancellation cannot
cancel another. Before a successful catalog enters the cache, Agent Computer
recursively checks names, descriptions, and schema keys and values for any
WorkerEnv value visible to that server. A match fails closed without caching or
echoing the value; schema redaction is forbidden because it would mutate the
server contract.

An MCP transport is never pooled. Each remote catalog load or call creates a
fresh official `@modelcontextprotocol/sdk` client, connects, performs one
bounded operation, and closes in `finally`. Streamable HTTP receives an
optional bearer header from WorkerEnv. Stdio runs the declared command with the
filtered WorkerEnv map and the SDK's safe base environment.

The caller's `AbortSignal` and request timeout apply to connection, catalog
discovery, and calls. Timeout precedence is model request, then Skill server
metadata `timeout_ms`, then the `360s` default. Values below `100ms` are
rejected; there is no Ankole-owned maximum. Codex Jobs receive the same value
as `tool_timeout_sec`. Catalog pages, tool counts, schema bytes, result
bytes, nesting, strings, and error messages all have explicit limits. Tool
output is treated as untrusted content; binary/control characters are cleaned,
large values are truncated or rejected, and resolved WorkerEnv secret values
are redacted from both values and object keys before model projection.

## Hermes Floor And Timeout Tradeoff

| Boundary | Previous Ankole | Hermes reference | Current Ankole | Tradeoff |
| --- | --- | --- | --- | --- |
| MCP operation timeout | `30s` default, model override capped at `120s` | No fixed per-call ceiling; the turn lifecycle is the outer bound | `360s` default, `100ms` minimum, no maximum; request override beats server metadata | A misconfigured tool can wait longer, but cancellation and the outer actor lease remain available and legitimate long I/O is no longer killed at two minutes. |

## Credential Boundary

Stable endpoints, commands, and credential variable names may be checked into
a Skill. Credential values must not appear in `SKILL.md`, `agents/openai.yaml`,
workspace files, shell commands, logs, tool details, or schema caches. The
control plane supplies them through turn-scoped WorkerEnv only.

A missing bearer variable fails the selected server operation with the variable
name, not the secret. Models and users must never be asked to paste a key into
chat or a file. Stdio servers receive the same filtered operator-managed
WorkerEnv boundary as other worker execution; reserved worker identity and
bootstrap variables are not injectable.

## Skill Authoring Rules

An MCP-backed Skill should name the server and route common user intents to
concrete tool names. When the Skill cannot choose a tool, it may call `list`
with that one server; it must not probe every enabled server. It should call
`describe` only when the selected tool's arguments are uncertain, then call
that tool directly. It should also explain freshness, warnings, partial
results, and provider-specific semantics that the transport cannot infer.

Do not add an MCP CLI, daemon, host config import, OAuth state file, or a second
JSON declaration. Interactive OAuth installation needs a separate product and
credential-ownership design; it is not silently emulated by Agent Computer.
