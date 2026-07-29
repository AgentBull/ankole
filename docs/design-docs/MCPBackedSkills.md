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
`bearer_token_env_var`, `timeout_ms`, `enabled_tools`, and `disabled_tools`.
The bearer field names an environment variable; it never contains the secret.

A stdio entry requires a `command` and can set `timeout_ms`, `enabled_tools`,
and `disabled_tools`. It cannot define a URL or bearer variable.

Tool filters contain raw MCP tool names. `enabled_tools` is an allowlist.
`disabled_tools` is a denylist and wins when one raw name occurs in both lists.

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

Agent Computer reads each enabled server catalog and gives AIGateway one
Responses namespace for each server. The namespace contains the real MCP tools.
Each child function has `defer_loading: true`, so its schema is not in the
model context until Tool Search selects it.

AIGateway owns search for the main Agent. It uses the official `tool_search`
surface, searches the deferred child functions, returns the matching namespace
children in `tool_search_output`, and maps the selected namespaced function
call back to the exact server and raw tool. Agent Computer validates the
arguments as a JSON object before it opens a new connection and invokes the raw
tool. The MCP server owns validation against its declared input schema, as it
does when Codex calls it directly.

The main Agent also declares the official `programmatic_tool_calling` tool by
default. Every model-visible MCP child permits both `direct` and
`programmatic` callers, as Codex 0.146 does in code mode. `readOnlyHint` controls
parallel execution only. It does not control whether a program can call the
tool.

The `mcp` `list`, `describe`, and `call` meta-tool does not exist. The model
sees the official namespace, Tool Search, and child function items.

## Match the Codex 0.146 MCP Surface

The same MCP registration and server response must expose the same
model-visible tool set in the main Agent and in Codex 0.146. This includes each
namespace, child name, description, input schema, visibility decision, filter
decision, collision result, and call failure shape. Search ownership can differ
because it does not change this contract.

Agent Computer keeps raw server and tool names for filters and calls. It
projects model names with the Codex 0.146 rules:

- Replace each character other than an ASCII letter, digit, or underscore with
  an underscore.
- Prefix a server namespace with `mcp__`.
- Ignore a repeated raw tool identity.
- Add the Codex 12-hex SHA-1 suffix when sanitized identities collide.
- Keep the complete flattened name, `namespace__child`, at 64 characters or
  fewer. Shorten with the same hash suffix when needed.

The worker uses the MCP initialize instructions as the namespace description.
It lowers the MCP input schema with the Codex rules. These rules replace
`const` with `enum`, supply missing object properties and array items, remove
unreachable definitions and unsupported fields, and compact schemas larger
than the Codex limit. It omits a tool when the schema cannot be lowered.

An absent or non-array `_meta.ui.visibility` value makes a tool visible. An
array value must contain `model`. Agent Computer applies `enabled_tools` first
and `disabled_tools` second against raw names.

Main-Agent Tool Search returns at most eight results by default. Its bilingual
BM25 corpus contains the flattened canonical name, canonical child name, raw
tool name, raw server name, tool title, tool description, MCP initialize
instructions, and root input-schema property names. AIGateway removes the
private corpus field before it sends or returns a public tool spec.

MCP calls return the bounded MCP `content`, `structuredContent`, and `isError`
shape to the model. A connection, transport, or protocol failure becomes an MCP
error result instead of changing the public function-call protocol.

## Use MCP from a Background Agent Job

Job preparation writes the same selected MCP declarations into Codex
configuration. Codex 0.146 uses its native Tool Search implementation to load
the deferred MCP child functions. It exposes the selected child as a namespaced
function call and invokes it through the official Codex MCP client.

AIGateway serves a full Codex model card with `supports_search_tool: true`.
This setting enables Codex Tool Search without adding an Ankole MCP meta-tool.
Agent Computer also enables Codex native code mode, so a Job can call selected
MCP tools from isolated JavaScript. Codex code mode is a client-side mechanism,
not the Responses API `programmatic_tool_calling` wire type.

Codex owns the Job-side projection. Agent Computer mirrors that pinned
projection for the main Agent instead of sharing its implementation. A
differential integration test registers one real stdio fixture in both paths,
runs Codex 0.146 Tool Search, and compares the loaded tool specs with the main
Agent catalog.

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

The main Agent uses the server `timeout_ms` value. It uses the 360-second
default when the declaration has no timeout.

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

Name the server and the tools that handle common requests. Explain when the
Agent must search for a less common tool. Do not tell the Agent to call the old
`mcp` meta-tool.

Explain data freshness, warnings, partial results, and provider behavior in the
Skill.

Do not add an MCP CLI, daemon, host configuration import, or second declaration
file.
