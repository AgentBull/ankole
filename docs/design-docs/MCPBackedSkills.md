# MCP-Backed Skills

This document specifies how Skills declare and execute MCP dependencies. The
separate contract for model-visible MCP servers appears under
[Model-Visible MCP Boundary](#model-visible-mcp-boundary) below.

In Ankole, an MCP dependency is an execution adapter behind a Skill, not a
second model-visible tool registry. Each enabled Skill declares its server
connection in `agents/openai.yaml`, documents when and how to call tools in
`SKILL.md`, and invokes the server through the pinned `mcporter` CLI.

`agents/openai.yaml` is the sole registration source for Skill-backed MCP
servers. Ankole maintains no Agent-level registry for Skill MCP servers, no
persistent `mcporter` config file, and no native MCP tool projection for Skills
in either the main Agent or Codex.

## Ownership

Responsibilities split cleanly across the stack:

- `SKILL.md` tells the model when to use a capability, which tool to choose,
  and how to interpret the response.
- `agents/openai.yaml` declares the stable server name, transport, endpoint or
  command, credential environment variable name, and tool filters.
- The control plane owns the active set of enabled Skills and encrypted
  operator credentials.
- Agent Computer resolves the active Skill declarations and writes an
  invocation-scoped `mcporter` config file.
- WorkerEnv injects credential values into the execution environment.
- `mcporter` opens the MCP connection, fetches the selected tool's schema when
  requested, and invokes the tool.
- The remote or local MCP server validates arguments, enforces its own
  permissions, and returns the result.

Because the model selects tools from Skill instructions, MCP serves purely as
the wire protocol for executing the chosen call.

## Declaration

The Skill loader accepts MCP entries only under `dependencies.tools`, and every
entry must set `type: mcp`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: remote-data
      description: "Remote data service"
      transport: streamable_http
      url: https://example.com/mcp
      protocol_version: 2026-07-28
      bearer_token_env_var: REMOTE_DATA_API_KEY
      enabled_tools:
        - quote
        - announcements

    - type: mcp
      value: local-data
      transport: stdio
      command: /opt/local-data/bin/server --stdio
      disabled_tools:
        - delete_record
```

`value` sets the `mcporter` server name, `description` is optional, and
`transport` must be either `streamable_http` or `stdio`:

- **`streamable_http`**: Requires an HTTP or HTTPS `url` and may optionally set
  `protocol_version`, `bearer_token_env_var`, `enabled_tools`, and
  `disabled_tools`. `protocol_version` accepts `auto` (the default), `legacy`,
  or `2026-07-28`; pin a version only when the server's protocol contract
  requires it. `bearer_token_env_var` names an environment variable and must
  never contain a literal secret value.
- **`stdio`**: Requires `command` and may set `enabled_tools` and
  `disabled_tools`, but cannot set `url` or `bearer_token_env_var`. Because
  Skill declarations are trusted first-party configuration, Agent Computer
  launches `command` via `/bin/sh -lc`.

Declarations do not configure a call timeout; instead, each Skill or Automation
script passes an explicit `--timeout` flag to `mcporter` that fits its
workflow. If `agents/openai.yaml` or `dependencies.tools` is absent, the Skill
declares no MCP dependencies.

The loader rejects unknown fields, malformed entries, symlinks that escape the
Skill directory, and metadata files larger than 64 KiB. A single Skill may
declare at most 64 dependencies, and a single execution may load at most 128
enabled Skills and 32 distinct MCP servers.

## Selection and Conflicts

A Skill's optional `ankole-runtime` metadata controls which runtimes see its
model instructions:

- Omitted or `any`: visible to both the main Agent and Background Agent Jobs.
- `main`: visible only to the main Agent.
- `background_job`: visible only to Background Agent Jobs.

Accordingly, the main Agent loads MCP dependencies from enabled `any` and
`main` Skills, while a Background Agent Job loads dependencies from its
selected `any` and `background_job` Skills (including member Skills of its
selected Agent Plugins). Automation Jobs do not run a model or read Skill
instructions; instead, on each attempt the control plane sends summaries of the
Agent's currently enabled Skills to Agent Computer, which loads every MCP
dependency in that set without filtering on `ankole-runtime`. Ankole does not
define a separate `automation_job` value for `ankole-runtime`.

Multiple Skills may declare the same server `value` only if every connection,
description, and filter field matches identically. When they match, Ankole
merges them and records all contributing Skill names; if any field differs,
Agent Computer fails setup rather than picking a winner.

For tool filtering, `enabled_tools` is an allowlist of exact raw tool names and
`disabled_tools` is a denylist of exact raw tool names. When a declaration
includes both fields, Agent Computer subtracts all denied names from
`enabled_tools` and writes only the resulting allowlist. That way, the denylist
always takes precedence while avoiding an invalid `mcporter` config that sets
both filter modes at once.

## Per-Execution Config

For every execution—even when the resolved server set is empty—Agent Computer
writes a fresh JSON config file with mode `0600`, exports its path as
`MCPORTER_CONFIG`, and deletes the file during execution cleanup. Main
environment Workspaces and Automation attempts write this file under
`/var/share` by default (or `TMPDIR` when set), while Background Agent Job
attempts write it inside the Job workspace's `temp/` directory.

The generated file always sets `imports: []`. Together with the explicit
`MCPORTER_CONFIG` environment variable, that empty import list prevents
`mcporter` from reading MCP configs from Agent Home, the project tree, Codex,
an editor, or the host machine.

When rendering server entries, Agent Computer translates a pinned HTTP entry
into `baseUrl`, `protocolVersion`, and a `bearerToken` `${VARIABLE}`
placeholder; for unpinned HTTP entries, it omits `protocolVersion` so
`mcporter` negotiates the protocol version automatically. It translates a
`stdio` entry into `command: /bin/sh` with `args: [-lc, <declared command>]`.
Agent Computer never reads secret values while generating this file, so raw
credentials cannot land on disk; instead, `mcporter` expands `${VARIABLE}` at
call time and attaches the `Bearer` authorization scheme.

Each execution runtime receives an isolated view of the config:

| Execution | Skill source | Config lifetime | Call owner |
| --- | --- | --- | --- |
| Main Agent | Current Skill summaries when the environment Workspace opens | One Worker environment Workspace | Main Agent command tool |
| Background Agent Job | Current selected standalone and Plugin Skills | One prepared Codex execution | Codex terminal |
| Automation Job | Current enabled Agent Skill summaries | One Automation attempt | `main.ts` |

Because the main model loop runs in the control plane, it requests an
environment Workspace only when a tool needs the Worker's computer; turns that
never invoke an environment tool create no `mcporter` config. Opening a
Workspace loads the current Skill declarations, and closing the Workspace—or
hitting idle expiry or a preparation error—removes its config file. Changes to
scripts or MCP declarations take effect the next time Agent Computer prepares
an execution, whereas Skill instruction reads reflect live updates immediately.

When Agent Computer prepares a Background Agent Job, it strips any existing
`mcp_servers` table from the project config and never places Skill-backed
dependencies into that table. Consequently, neither a workspace template nor a
resumed project directory can inject a native Codex MCP server.

## Model-Visible MCP Boundary

Ankole does not currently ship a bundled model-visible MCP server. If a
concrete capability introduces one, both runtimes must align their observable
behavior without copying Codex internals:

- The main Agent exposes the server under the `mcp__<server>` namespace, keeps
  original tool names and descriptions, and loads schemas through deferred Tool
  Search.
- A Background Agent Job registers the server through Codex's native
  `mcp_servers` config; Agent Computer must not wrap it as a dynamic tool.
- Both runtimes expose the same model-visible namespace, tool names, and
  loading behavior while keeping their own execution owners.
- Ankole passes the server's standard JSON Schema into each runtime unchanged:
  the main Agent projects it through Responses, and Background Agent Jobs let
  Codex own its native MCP projection. Neither adapter may strip or rewrite
  schema constraints to mimic the other runtime's implementation details.

Across Ankole, a model-visible tool's canonical identity is always the pair
`{namespace, name}`. Responses groups tools in a namespace container and echoes
that namespace on every `function_call`, and durable history, Job replay, Tool
Search, and execution all preserve both fields. If a runtime has only a flat
local name slot at its terminal boundary, it may construct a reversible alias
there, but that alias never replaces the `{namespace, name}` identity in Ankole
or MCP.

Because Codex reserves the `mcp__` prefix for native MCP servers, the
dynamic-tool projection for Background Agent Jobs quarantines `mcp__` and
accepts only explicitly allowed non-MCP namespaces. Any future model-visible
MCP integration must ship with a concrete server owner and tests rather than an
empty registry or a general-purpose local MCP loader.

## Model Call Contract

A Skill must pick a specific tool from its domain instructions before querying
the server for a schema; it must never list the full server catalog as a
discovery step. When the model needs to inspect the selected tool's current
schema, it runs:

```bash
mcporter list 'server-name.tool-name' --schema --json --timeout 360000
```

To invoke the tool safely without shell interpolation of quotes, Unicode text,
or metacharacters, write the JSON argument object to a temporary file and pipe
it over `stdin`:

```bash
mcporter call 'server-name.tool-name' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, the model must delete the temporary argument file and
check the process exit code before parsing `stdout`.

An Automation script invokes `mcporter` via `Bun.spawn` with the same argument
vector, writing a single JSON object to child `stdin`, checking the exit code,
and parsing `stdout`. Automation scripts must never write a persistent
`mcporter` config file.

## Failure Contract

Agent Computer aborts execution setup before any user command or Automation
script starts if it encounters an invalid Skill summary, an inaccessible Skill
root, a malformed MCP declaration, or conflicting definitions for the same
server name. At call time, `mcporter` exits with a non-zero status on a missing
bearer variable, connection failure, protocol error, invalid argument, or
remote server error. Callers must preserve the diagnostic output and never
treat partial `stdout` as a valid result.

Because main command output, Codex terminal output, and Automation `stdout` and
`stderr` all enforce strict byte limits, Skills must pass server pagination and
result-size parameters that stay within those execution bounds.

Agent Computer never fetches MCP catalogs during setup, nor does config
generation open network sockets or spawn `stdio` servers. An MCP connection
lives only for the duration of a single `mcporter list` or `mcporter call`
process.

## Security and Deliberate Limits

WorkerEnv injects credentials into the same trusted Worker environment that
runs the model's shell command or Automation script, while the generated
`mcporter` config file contains only `${VARIABLE}` placeholders. If a required
environment variable is missing, the diagnostic message must report the
variable's name without ever printing a credential value.

Treat all MCP server output as untrusted input. By design, the Skill and
`mcporter` path omits four client-side mechanisms:

- Validating responses against MCP output schemas.
- Mapping MCP tool annotations to programmatic callers or parallel scheduling.
- Rendering native tool-level activity indicators or interactive approval UI.
- Scrubbing WorkerEnv secret values from MCP tool results.

Because client-side secret redaction is absent, any secret that a server
accidentally echoes in its response can enter persistent command history.
Ankole accepts this narrower boundary only for trusted, first-party MCP Skills,
since those secrets already reside in the same Worker environment and never
appear in the generated config file. Do not connect untrusted third-party MCP
servers through this contract without a dedicated security review.

Ultimately, the remote credential's permission scope is the real security and
write boundary. Tool filters in `agents/openai.yaml` and guidance in `SKILL.md`
steer trusted code, not untrusted adversaries. If an Automation Job requires
narrower authority than the main Agent, issue it a separate credential identity
or omit that MCP dependency from the Agent's enabled Skills.

## Authoring Rules

- Scope each domain Skill to a single server or one cohesive workflow.
- Document business routing, freshness rules, pagination, warnings, and
  partial-result handling in `SKILL.md`.
- Keep `agents/openai.yaml` strictly to connection settings and exact tool
  filters.
- Fetch schemas only for the specific tool you intend to call.
- Pass call arguments as JSON over `stdin`; never inline argument JSON or
  secrets in shell command strings.
- Do not introduce a generic `mcporter` Skill, a generated per-server CLI, a
  background daemon, a persistent config file, or a second manifest format
  without concrete production evidence.
- Do not build a general-purpose local MCP loader or empty bundled server
  registry; new domain integrations should use this Skill contract unless a
  capability has a reviewed model-visible contract and a dedicated runtime
  owner.
