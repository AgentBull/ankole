# MCP-Backed Skills

This document specifies Skill-backed MCP dependencies. Release-defined servers
that are direct model tool providers use the separate
[Direct MCP Tools](DirectMCPTools.md) contract.

An MCP dependency is an execution adapter for a Skill. It is not a second
model-visible tool registry. An enabled Skill declares the connection in
`agents/openai.yaml`, explains tool selection in `SKILL.md`, and calls the
server through the pinned `mcporter` CLI.

`agents/openai.yaml` is the only registration source for Skill-backed MCP.
Ankole does not keep an Agent-level Skill MCP registry, a persistent mcporter
config, or a native Skill MCP projection for the main Agent or Codex.

## Ownership

- `SKILL.md` tells a model when to use the capability, which tool to select,
  and how to read the result.
- `agents/openai.yaml` stores the stable server name, transport, endpoint or
  command, credential variable name, and tool filters.
- The control plane owns the current enabled Skill set and encrypted operator
  credentials.
- Agent Computer resolves the current Skill declarations and writes one
  invocation-scoped mcporter config.
- WorkerEnv supplies credential values to the current execution.
- `mcporter` opens the MCP connection, reads a selected tool schema, and calls
  the selected tool.
- The MCP server validates input, enforces its permissions, and returns the
  result.

The model chooses a tool from Skill knowledge. MCP is only the protocol used to
make the selected call.

## Declaration

The loader accepts MCP entries only under `dependencies.tools`. Each entry must
use `type: mcp`.

```yaml
dependencies:
  tools:
    - type: mcp
      value: remote-data
      description: "Remote data service"
      transport: streamable_http
      url: https://example.com/mcp
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

`value` is the mcporter server name. `description` is optional. `transport`
must be `streamable_http` or `stdio`.

A `streamable_http` entry requires an HTTP or HTTPS `url`. It can set
`bearer_token_env_var`, `enabled_tools`, and `disabled_tools`. The bearer field
contains an environment variable name. It must never contain a secret value.

A `stdio` entry requires `command`. It can set `enabled_tools` and
`disabled_tools`. It cannot set `url` or `bearer_token_env_var`. Agent Computer
starts it through `/bin/sh -lc` because the declaration is trusted,
first-party configuration.

The declaration does not set a call timeout. Each Skill or Automation script
must pass an explicit `--timeout` value to mcporter that matches its workflow.

The loader rejects unknown fields, malformed entries, and metadata larger than
64 KiB. One Skill can declare at most 64 dependencies. One execution can read
at most 128 enabled Skills and 32 distinct MCP servers. A metadata symlink
cannot leave its Skill directory.

If `agents/openai.yaml` or `dependencies.tools` is absent, the Skill declares
no MCP dependency.

## Selection and Conflicts

The optional `ankole-runtime` Skill metadata controls model instruction
visibility. An absent value and `any` permit the main Agent and Background
Agent Jobs. `main` permits only the main Agent. `background_job` permits only
Background Agent Jobs.

The main Agent loads dependencies from `any` and `main` Skills. A Background
Agent Job loads dependencies from its selected `any` and `background_job`
Skills, including selected Agent Plugin member Skills.

Automation Jobs do not run a model and do not read Skill instructions. For
each attempt, the control plane sends the current enabled Skill summaries to
Agent Computer. Agent Computer loads all MCP dependencies from that set without
an `ankole-runtime` filter. This does not add an `automation_job` Skill runtime.

Several Skills can declare the same server name only when all connection,
description, and filter fields match. Ankole then records all source Skill
names. If a field differs, setup fails. Ankole does not choose a winner.

`enabled_tools` is an exact raw-name allowlist. `disabled_tools` is an exact
raw-name denylist. When both fields exist, Agent Computer writes the allowlist
after it removes all denied names. This preserves the rule that the denylist
wins and avoids an invalid mcporter config with both filter modes.

## Per-Execution Config

Agent Computer writes a unique JSON file under `/var/share` with mode `0600`.
It injects the file path as `MCPORTER_CONFIG` and removes the file when the
execution ends. It writes a config even when the server set is empty.

The generated file always contains `imports: []`. The explicit
`MCPORTER_CONFIG` path and this empty import list prevent mcporter from reading
an Agent Home, project, Codex, editor, or host MCP config.

An HTTP entry becomes `baseUrl` plus `bearerTokenEnv`. A stdio entry becomes
`command: /bin/sh` plus `args: [-lc, <declared command>]`. Credential values are
not read while the file is generated and cannot enter the file.

Each execution receives a fresh view:

| Execution | Skill source | Config lifetime | Call owner |
| --- | --- | --- | --- |
| Main Agent | Current conversation Skill summaries | One text turn | Main Agent command tool |
| Background Agent Job | Current selected standalone and Plugin Skills | One prepared Codex execution | Codex terminal |
| Automation Job | Current enabled Agent Skill summaries | One Automation attempt | `main.ts` |

The file can also contain release-defined Direct MCP servers. Those entries do
not come from Skills and follow [Direct MCP Tools](DirectMCPTools.md).

Background Job project config removes any existing `mcp_servers` table. A
workspace template or resumed project cannot restore the old native Codex MCP
path.

## Model Call Contract

A Skill must identify one tool before it asks the server for a schema. It must
not list the full catalog as a discovery step. When the current schema is
needed, use:

```bash
mcporter list 'server-name.tool-name' --schema --json --timeout 360000
```

Write the argument object to a temporary JSON file. Then call the selected tool
through stdin so quotes, Unicode text, and shell characters are not
interpolated:

```bash
mcporter call 'server-name.tool-name' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

The model must remove the temporary argument file after the call. It must check
the process exit code before it parses stdout.

An Automation script must use `Bun.spawn` with the same argv. It writes one
JSON object to the child stdin, checks the exit code, and parses stdout. It must
not create a persistent mcporter config.

## Failure Contract

An invalid Skill summary, inaccessible Skill root, malformed declaration, or
server conflict fails setup before a user command or Automation script starts.
A missing bearer variable, connection error, protocol error, invalid argument,
or server error fails the mcporter process. The caller must keep the diagnostic
and must not treat partial stdout as a successful result.

Main command output, Codex terminal output, and Automation stdout and stderr
remain bounded by their existing execution contracts. Skills must set server
pagination and result-size bounds that fit those contracts.

Agent Computer does not fetch an MCP catalog during setup. Config generation
does not open a network connection or start a stdio server. A connection exists
only while a mcporter list or call process uses it.

## Security and Deliberate Limits

WorkerEnv provides credentials to the same trusted sandbox that runs the model
command or Automation script. The generated file stores only environment
variable names. A missing variable diagnostic must name the variable and must
not print a credential value.

The server output is untrusted input. Removing the native MCP client also
removes these client-side guarantees:

- MCP output-schema validation.
- MCP annotation mapping to programmatic callers or parallel scheduling.
- Native tool-level activity and approval UI.
- MCP-result redaction against all WorkerEnv secret values.

The last item removes a defense against a server that accidentally returns a
secret and lets command output enter persistent history. Ankole accepts this
narrower contract for trusted, first-party MCP Skills. The secret already
exists in the same sandbox, and the config still stores only its variable
name. Do not use this contract for an untrusted third-party server without a
separate security review.

The real write boundary is the remote credential scope. Tool filters and Skill
instructions guide trusted code; they do not create a security boundary. If an
Automation Job needs less authority than the main Agent, give it a different
credential identity or do not expose that dependency to the Agent.

## Authoring Rules

- Keep one domain Skill for one server or one cohesive workflow.
- Put business routing, freshness, pagination, warnings, and partial-result
  rules in `SKILL.md`.
- Put only connection facts and exact tool filters in `agents/openai.yaml`.
- Inspect only the selected tool schema.
- Use stdin JSON for calls. Do not put argument JSON or secrets in shell text.
- Do not add a generic mcporter Skill, a generated server CLI, a daemon, a
  persistent config, or a second declaration file without production evidence
  that requires it.
- Do not use this document to force a small release-defined model tool provider
  behind a Skill. Review that server against the Direct MCP criteria instead.
