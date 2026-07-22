# MCP-Backed Skills

An enabled Skill can give an Agent access to an MCP server. The Skill declares
that server in `agents/openai.yaml`. No other file registers MCP servers.

The main Agent and Background Agent Jobs read the same declaration format, but
each process opens its own connection.

## Who Does What

- `SKILL.md` tells the Agent when and how to use the server.
- `agents/openai.yaml` gives the stable connection settings.
- The control plane enables Skills and stores encrypted operator credentials.
- WorkerEnv sends the needed variables to one Agent turn.
- Agent Computer runs MCP calls for the main Agent.
- Codex runs MCP calls inside a Background Agent Job.
- The remote server defines its tools and returns their results.

The main Agent and Jobs never share an MCP connection. Ankole has no separate
MCP registry or worker-side configuration database.

## Declare a Server in a Skill

The loader accepts MCP entries only under `dependencies.tools`.
Each entry must use `type: "mcp"`.

```yaml
dependencies:
  tools:
    - type: "mcp"
      value: "remote-data"
      description: "Remote data service"
      transport: "streamable_http"
      url: "https://example.com/mcp"
      bearer_token_env_var: "REMOTE_DATA_API_KEY"
      timeout_ms: 360000

    - type: "mcp"
      value: "local-tool"
      transport: "stdio"
      command: "/opt/local-tool/bin/server --stdio"
```

`value` names the server. `description` is optional. `transport` selects
`streamable_http` or `stdio`.

An HTTP entry requires an HTTP or HTTPS `url`. It can also set
`bearer_token_env_var` and `timeout_ms`. The bearer field names an environment
variable; it never contains the secret.

A stdio entry requires a `command` and can set `timeout_ms`. It cannot define a
URL or bearer variable.

The timeout must be an integer of at least 100 milliseconds.
Ankole does not set a maximum timeout below the JavaScript safe integer limit.

The loader rejects unknown fields, malformed entries, and metadata larger than
64 KiB. One Skill can declare at most 64 MCP servers. A metadata symlink cannot
leave the Skill directory.

If the file or `dependencies.tools` is absent, the Skill declares no MCP server.

## Decide Which Declarations Apply

The optional `ankole-runtime` field in `SKILL.md` controls which process can use
the Skill. An absent field and `any` permit both processes. `main` permits only
the main Agent. `background_job` permits only Background Agent Jobs.

The main Agent loads MCP declarations from `any` and `main` Skills. Job
preparation loads declarations from selected `any` and `background_job` Skills.
An invalid value rejects the Skill source.

`value` identifies a server. Several Skills can declare the same server only
when every connection field matches, including the description and timeout.
Ankole then records all source Skill names.

If any field differs, Ankole reports a conflict and stops preparation. It does
not guess which Skill should win.

## Use MCP from the Main Agent

Agent Computer adds one `mcp` tool when at least one server is available. The
tool supports `list`, `describe`, and `call`.

### List

`list` without a server returns allowed server names and descriptions without
opening a connection. It includes cached tool summaries when available.

`list` with a server connects only to that server, reads its tool catalog, and
caches the result.

Neither form reveals URLs, commands, credentials, or schemas.

### Describe

`describe` requires one server and one tool.
It returns the selected tool description and schemas.
It rejects a tool outside the validated server catalog.

### Call

`call` requires one server and one tool.
It invokes only the selected tool.
It accepts an optional argument object and request timeout.

The tool rejects a disabled server.
It also rejects a tool outside the validated catalog.

## Limit and Cache Tool Catalogs

A catalog can contain at most 20 pages and 256 tools.
One tool schema can use at most 64 KiB.
The complete catalog can use at most 512 KiB.

The worker process caches successful catalogs for five minutes.
The least-recently-used cache contains at most 32 entries.

The cache key includes:

- all nonsecret connection settings
- the current versions of source Skill metadata
- the identity of the current credential

A changed declaration or credential creates a new cache entry. The cache does
not store failures, and concurrent turns do not share an unfinished load.

Before caching, Agent Computer checks catalog text and object keys for secret
WorkerEnv values. If it finds one, it rejects the catalog instead of changing
the server schema.

## Open a New Connection for Each Operation

Each catalog load or tool call creates a new official MCP SDK client. Agent
Computer closes it when the operation ends.

HTTP transport can read a bearer token from WorkerEnv. Stdio transport runs the
declared command through `/bin/sh -lc` with the safe SDK environment and allowed
WorkerEnv values.

The main Agent selects the timeout in this order:

1. The model request `timeout_ms` value.
2. The server `timeout_ms` value.
3. The 360-second default.

The caller abort signal covers connection, discovery, and tool calls.

Job preparation writes the server timeout as Codex `tool_timeout_sec`.
It uses the 360-second default when the Skill has no timeout.

## Treat Server Output as Untrusted

Agent Computer limits description, schema, result, error, nesting, collection,
and string sizes. It removes binary and control characters. It truncates fields
with declared limits and rejects a complete result that is too large.

It removes WorkerEnv secrets from result values and object keys. MCP output
remains untrusted input to the model.

## Keep Credentials out of Skills

A Skill can store endpoints, commands, and credential variable names. It must
never store a credential value.

Credential values must not appear in these locations:

- `SKILL.md`.
- `agents/openai.yaml`.
- Agent files.
- Shell commands.
- Logs.
- Tool details.
- Catalog caches.

The control plane supplies credentials through WorkerEnv for one turn. A
missing bearer variable reports only its name. The model must not ask a user to
paste a credential into chat or a file.

WorkerEnv never injects reserved worker identity or bootstrap variables.

Ankole does not install OAuth credentials interactively. That flow first needs
a credential ownership contract that names the component which stores and
refreshes the credential.

## Write Clear Skill Instructions

Name the server and the tools that handle common requests. If tool selection is
uncertain, call `list` for one server. Call `describe` only when the arguments
remain unclear. Then call the selected tool.

Explain data freshness, warnings, partial results, and provider behavior in the
Skill.

Do not add an MCP CLI, daemon, host configuration import, or second declaration
file.
