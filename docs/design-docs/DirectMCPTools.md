# Direct MCP Tools

A Direct MCP server is a release-defined model tool provider. Agent Computer
projects its selected tools directly to the model. A Skill is not the routing
owner for this mode.

Use this mode only when the server has a small, cohesive tool surface and its
live schemas are the best instructions for tool selection. Use an
[MCP-backed Skill](MCPBackedSkills.md) when domain workflow knowledge must
select one tool before the model reads its schema.

## Registration Owner

`app/agent_computer/src/tools/mcp/direct-registry.ts` is the only release
registry. A record contains these non-secret facts:

- server name and model namespace
- namespace description
- stdio command, arguments, and working directory
- operation timeout
- exact model-visible tool allowlist
- optional WorkerEnv variable names

This registry is part of the Worker release. It is not Agent state, Skill
metadata, or operator configuration. A Direct MCP server has no runtime
eligibility field. Main Agent turns, Background Agent Jobs, and Automation Jobs
all receive the same registered capability. A runtime can ignore it, but
Agent Computer does not add an enable or disable decision for that runtime.

## Runtime Projection

The three runtimes use the same registry but need different call mechanics.

| Runtime | Model or script surface | Connection owner |
| --- | --- | --- |
| Main Agent | Deferred Responses namespace tools | Agent Computer MCP client |
| Background Agent Job | Deferred Codex dynamic namespace tools | Agent Computer MCP client |
| Automation Job | Entry in the invocation-scoped `MCPORTER_CONFIG` | Automation script through mcporter |

Main and Background setup list each registered server. Agent Computer caches
only a successful bounded catalog for the Worker process. Each tool call starts
a fresh stdio connection and closes it after the result. A catalog failure
removes only that server from the current model surface and writes a bounded
Worker diagnostic.

The Main Agent permits direct and programmatic calls for each Direct MCP tool.
MCP annotations control only parallel local execution. They do not remove the
programmatic caller. Thus, a server that omits annotations cannot remove the
PTC declaration from an existing stateful conversation.

Background projection keeps the MCP namespace. It sends each child tool's live
JSON Schema and `deferLoading` value through the Codex app-server dynamic tool
contract. It does not add the server to Codex project `mcp_servers`.

Automation setup writes every Direct MCP record and every resolved Skill MCP
dependency to one attempt-scoped mcporter config. Config generation does not
start a server. The process starts only if `main.ts` calls it. The config uses
the same `0600`, `imports: []`, and cleanup contract as Skill-backed MCP.

## Flint Chart Contract

The first Direct MCP server is `flint-chart-mcp` 0.4.1. It runs from the local
Worker dependency with this effective command:

```sh
bunx --bun --no-install flint-chart-mcp --backends vegalite --disable-file-reference
```

`bunx --no-install` must use the dependency in the Worker image. It must not
download a package during a turn or Automation attempt. The larger local image
is an accepted cost because chart rendering must stay local.

Agent Computer exposes only these tools:

- `render_chart`
- `compile_chart`
- `validate_chart`
- `list_chart_types`

It does not expose `create_chart_view`, resources, prompts, or the MCP App.
`render_chart` returns PNG by default and accepts SVG when the caller requests
it. `compile_chart` returns a Vega-Lite specification. No ECharts or Chart.js
backend is available.

Map and Choropleth are not supported. The policy proxy removes them from
`list_chart_types` and rejects them before a compile, validation, or render
call reaches Flint. This policy applies to native calls and mcporter calls.
Flint also rejects `data.url`; callers must send rows through
`data.values`. This rule removes local file reads and remote URL ambiguity from
the chart contract.

## Result and Artifact Contract

Agent Computer validates MCP result envelopes and any declared output schema.
It bounds model text and structured result details. It accepts supported image
types only, validates the PNG signature, and limits image size.

Main Agent chart artifacts use:

```text
<Agent Home>/user-files/generated-charts/
```

Background Agent Job artifacts use:

```text
<Job Workspace>/artifacts/generated-charts/
```

A PNG image becomes a `.png` file and model image content. An SVG render
becomes an `.svg` file. The `spec` object from a Flint Vega-Lite compile becomes
a directly usable `.vl.json` file. The tool result includes each absolute
artifact path so the Agent can attach or use the file.

Automation calls mcporter directly, so its script owns result parsing and file
storage. Direct MCP registration gives the script access; it does not add a
second Automation SDK.

## Security and Limits

For native Main and Background calls, the MCP child receives the SDK safe
environment plus only the WorkerEnv values named by its registry record. Agent
Computer redacts those declared values from native MCP result text and bounded
error messages.

An Automation script and its mcporter child receive the attempt's existing
WorkerEnv. Secret values do not enter the registry or mcporter config, but this
path does not add native result redaction. The Automation script owns result
parsing and persistence under its existing sandbox contract.

The client limits catalog pages, tool count, schema size, catalog size,
argument size, result text, image size, and total stdio message size. Native
Flint operations time out after 60 seconds. An Automation script must pass its
own explicit mcporter timeout. The server applies its own row, file, and canvas
limits.

Direct registration is not a third-party extension contract. The current
extension model is trusted and first-party. Add another Direct MCP server only
after review of its package, process command, tool allowlist, data access,
credentials, result forms, and all three runtime projections.

## Verification

Tests must prove these facts:

- one registry record produces the expected mcporter entry without a runtime
  gate
- Main preserves the namespace, live schema, deferred flag, and both caller
  modes; Background preserves the namespace, live schema, and deferred flag
- Automation receives the registry entry even when it has no enabled Skill and
  can call it through mcporter
- Flint hides the MCP App and exposes exactly four tools
- omitted render format produces a valid PNG artifact
- SVG is accepted when requested and compile produces a Vega-Lite spec
- Map and Choropleth are absent from discovery and rejected on calls
- the canonical Worker image can start the local dependency with `bunx`
