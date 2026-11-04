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
  command, connection selection, and tool filters.
- The control plane owns the active set of enabled Skills and encrypted
  operator credentials.
- Agent Computer resolves the active Skill declarations and writes an
  invocation-scoped `mcporter` config file.
- Connectors holds remote credentials in the control plane. WorkerEnv supplies a
  short-lived internal token bound to the active Turn.
- `mcporter` opens the MCP connection, fetches the selected tool's schema when
  requested, and invokes the tool.
- The remote or local MCP server validates arguments, enforces its own
  permissions, and returns the result.

Because the model selects tools from Skill instructions, MCP serves purely as
the wire protocol for executing the chosen call.

## Shared Skill Packages

`Ankole.AIAgent.Library.Skills` owns the required `SKILL.md` manifest and
all companion files in `skills` and `skill_files`. The catalog uses the manifest
description. `skill_view` reads the manifest, and the Agent explicitly reads
referenced documents, scripts, templates and `agents/openai.yaml` by relative path.

At startup and during catalog refresh, Ankole compares shipped packages with
`skills.upstream_state`. The fingerprint covers the manifest and the relative
paths, hashes and modes of managed files. Ankole updates an unchanged package
atomically, including upstream additions and removals. If a person changed any
managed file or the manifest, Ankole preserves the local package and records the
pending upstream fingerprint. Additional local files remain outside that fingerprint.

The Agent identity determines package enablement. Main runs read complete
packages from the shared read-only `/drive/Skills` mount. Background Agent Jobs
materialize the intersection of their initial Skill
selection and the Agent's currently enabled Skills before loading MCP dependencies.
The MCP loader reads the same package files as the Agent.

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
`transport` is `connector`, `streamable_http`, or `stdio`:

- **`connector`**: Requires `toolkit` and may set `connection`, `account`,
  `enabled_tools`, and `disabled_tools`. The control plane selects the named
  tenant connection; omission requires an unambiguous default connection.
  Plugin `ToolSpec` declarations generate these tool filters, individual
  `references/<tool>.json` schemas, and Applet SDK types.

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

Declarations do not configure a call timeout; each Skill passes an explicit `--timeout` flag to `mcporter` that fits its
workflow. If `agents/openai.yaml` or `dependencies.tools` is absent, the Skill
declares no MCP dependencies.

The loader rejects unknown fields, malformed entries, symlinks that escape the
Skill directory, and metadata files larger than 64 KiB. A single Skill may
declare at most 64 dependencies, and a single execution may load at most 128
enabled Skills. MCP servers are resolved from those enabled Skill declarations.

## Selection and Conflicts

A Skill's optional `ankole-runtime` metadata controls which runtimes see its
model instructions:

- Omitted or `any`: visible to both the main Agent and Background Agent Jobs.
- `main`: visible only to the main Agent.
- `background_job`: visible only to Background Agent Jobs.

Accordingly, the main Agent loads MCP dependencies from enabled `any` and
`main` Skills, while a Background Agent Job loads dependencies from its
selected `any` and `background_job` Skills (including member Skills of its
selected Agent Plugins). Applet Automation Jobs execute in Function Runtime. Their
MCP calls use the Job's execution Principal or the current Page owner through
`admin.mcp.call`.

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
environment Workspaces write this file under
`/var/share` by default (or `TMPDIR` when set), while Background Agent Job
attempts write it inside the Job workspace's `temp/` directory.

The generated file always sets `imports: []`. Together with the explicit
`MCPORTER_CONFIG` environment variable, that empty import list prevents
`mcporter` from reading MCP configs from Agent Home, the project tree, Codex,
an editor, or the host machine.

Agent Computer renders Connector entries as the control-plane
`/api/internal/mcp/toolkits/:toolkit` URL and remote Skill entries as
`/api/internal/mcp/skills/:skill/:server`. Both use protocol `2026-07-28` and
an internal Turn token. The Worker renews this token every five minutes and
atomically updates the disposable config and Git context file. It also refreshes
the active connection and application-account choices from the control plane.
The Worker command and MCPorter enforce their caller-selected timeouts. The
gateway bounds upstream work by the current Turn token's expiry; Function
Runtime calls use the remaining Applet invocation budget.
`mcporter list` exposes connection aliases such as `github@work`, and aliases
such as `github@work@42` select a particular application account. An account key
is URL-encoded in the alias, including dots, while the gateway receives its
original value. Human OAuth accounts stay bound to the authorized Human and
are not listed as application choices. The gateway resolves remote Skill credentials and attaches them to
upstream requests. Local `stdio` entries use `/bin/sh -lc` with the declared
command. Generated files contain no external credential values.

Each execution runtime receives an isolated view of the config:

| Execution | Skill source | Config lifetime | Call owner |
| --- | --- | --- | --- |
| Main Agent | Current Skill summaries when the environment Workspace opens | One Worker environment Workspace | Main Agent command tool |
| Background Agent Job | Current selected standalone and Plugin Skills | One prepared Codex execution | Codex terminal |
| Applet route or Automation Job | Explicit Toolkit or enabled Skill | One host invocation, in memory | Function Runtime MCPorter library |

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

## Applet tools and streaming files

The trusted Function Runtime host runs MCPorter for
`AnkoleRuntime.mcp.call(tool, arguments, {server, connection?, account?, skill?})`.
Without `skill`, `server` identifies a Connector Toolkit. With `skill`, the
gateway resolves the named HTTP server from the execution Principal's enabled
Skills. Calls return the tool's structured output. `admin.mcp.call` uses the
Page's current owner; the ordinary call uses the route caller or personal Job's
authorizing human. A service Job has no ordinary caller identity.

The control plane sends separate signed caller and admin contexts to the host.
The host removes these headers before opening the user isolate and consumes MCP
capability frames itself. Protocol discovery requires a valid signed context;
tool discovery and calls recheck current Principal, Page, and Turn or Attempt
authority. Notifications receive an empty HTTP 202 response. A GET route can call only tools declaring
`readOnlyHint: true`. Connector `ToolSpec` schemas validate both input and output;
fields marked `int64` or `uint64` become decimal strings. Plugins resolve static
ToolSpec schemas at compile time while exposing the original declarations to
tool discovery and generated clients. Skill calls validate arguments against the schema
returned by their selected server.

The internal gateway implements stateless MCP `2026-07-28`, including
`server/discover`, complete result envelopes, and cache metadata. Its pure Elixir
`RemoteMCP` adapter handles upstream legacy initialization and session reuse,
keyed by tenant, execution identity, endpoint, and credentials. The connection
cache also retains the upstream tool catalog for ten minutes; credential changes
select a separate cache entry. Explicit session expiry can recreate a session. A lost response to a non-idempotent write returns
an unknown outcome instead of silently replaying the write. Idle sessions expire
and close after ten minutes. A completed tool response with `isError: true`
remains a tool error; it does not imply an unknown write outcome. Text-only
results retain their content without inventing structured output.
HTTP and JSON-RPC failures retain the upstream status, message, and error details
so callers can correct invalid arguments or recover authorization. The gateway
redacts the injected credential from these diagnostics. HTTP 401 responses,
including OAuth-style error bodies, preserve their status so the Toolkit gateway
can use the shared credential recovery path.

`Ankole.Files.HTTP` owns the shared HTTP/file bridge alongside
`Ankole.Connectors.Files`. Uploading a `file_ref` (`HTTP.upload` or
`Connectors.Files.multipart`) authorizes and resolves the `pod_files` entry via
`Ankole.Pod.Files` and its immutable `file_objects` row in a short read, releases
the database connection, and streams the upload in 8 MiB chunks. `HTTP.download`
streams an HTTP response into `file_objects` and commits the `pod_files`
reference through `Ankole.Pod.Files.upload/8`. Neither direction assembles a
large file in memory. JSON
requests and responses are each limited to 5,000,000 bytes; UTF-8 validation runs
on the complete buffered response, so split multibyte characters remain valid.
The bridge decodes gzip and deflate JSON responses with the same limit on decoded
bytes. Invalid HTTP URLs return a non-retryable error before sending a request.

If a non-idempotent request has sent bytes and loses its response, the bridge
returns `%{code: "upstream_outcome_unknown", retryable: false, request_sent: true}`.
The caller reconciles the upstream outcome before deciding whether to retry.
Local Toolkit validation and credential rejection return `request_sent: false`.
REST rejection details preserve the provider's response body. The gateway removes
the exact injected credential values from error details and proxied MCP content
before returning them to a caller.

## Failure Contract

Agent Computer aborts execution setup before any user command starts if it encounters an invalid Skill summary, an inaccessible Skill
root, a malformed MCP declaration, or conflicting definitions for the same
server name. At call time, `mcporter` exits with a non-zero status on a missing
bearer variable, connection failure, protocol error, invalid argument, or
remote server error. Callers must preserve the diagnostic output and never
treat partial `stdout` as a valid result.

Because command and Codex terminal output enforce byte limits, Skills must pass server pagination and
result-size parameters that stay within those execution bounds.

Agent Computer never fetches MCP catalogs during setup, nor does config
generation open network sockets or spawn `stdio` servers. An MCP connection
lives only for the duration of a single `mcporter list` or `mcporter call`
process.

## Security and Deliberate Limits

Connectors owns remote application roots and personal refresh tokens. Workers
receive an internal Turn token; Function Runtime hosts receive invocation tokens.
The gateway checks the live execution identity before using external credentials.
Local Git authentication uses `GIT_ASKPASS` to exchange the active Turn token for
a short-lived repository credential, without storing it in a credential helper.
The helper returns the fixed HTTPS username locally and exchanges the password
once per request. It prints an authorization link when consent is required.
An explicit connection remains authoritative. Without one, Ankole matches the
repository's HTTPS host and port to active GitHub connections, using the matching
default or sole match; multiple nondefault matches require a connection choice.

Tool filters and Skill guidance select supported capabilities. Connector tools
also enforce explicit subject policy, credential selection, schemas, and
read-only annotations in the gateway. Local `stdio` Skills remain trusted
first-party code and use the ordinary Worker execution boundary. Treat upstream
content as data rather than instructions.

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
