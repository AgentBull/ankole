---
title: MCP server reference
description: Declare Connector, remote HTTP, and local MCP dependencies and call them through the correct runtime.
section: Reference
order: 201
---

Skills choose domain tools; MCPorter handles discovery and calls. Skill dependencies are not registered as native model tools. Agent Workers call the control plane's MCP gateway, which resolves credentials and invokes Connector or remote MCP services.

## Declare a dependency

Use `dependencies.tools` in `agents/openai.yaml`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: github
      transport: connector
      toolkit: github
      enabled_tools:
        - repos_get
    - type: mcp
      value: lookup
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: LOOKUP_TOKEN
      enabled_tools:
        - search
```

`connector` requires `toolkit` and optionally selects `connection` and `account`. Configure tenant applications and personal grants on the Pod Connections page. `streamable_http` requires `url`; its optional `bearer_token_env_var` names a configured WorkerEnv value that the control plane resolves for the proxy. The referenced remote secret is excluded from the Worker's environment snapshot. Optional `protocol_version` accepts `auto`, `legacy`, or `2026-07-28`.

Trusted local servers may use `transport: stdio` and `command`. They execute inside Agent Computer through `/bin/sh -lc`. All transports can declare exact `enabled_tools` or `disabled_tools` names. A Skill supports up to 64 dependencies; conflicting declarations for the same server fail setup.

## Runtime behavior

Main Agents use enabled `any` and `main` Skills. Background Agent Jobs use enabled `any` and `background_job` Skills. Each execution receives a disposable `MCPORTER_CONFIG` with `imports: []`. Connector and remote entries point to internal gateway endpoints and use a short-lived Turn token, renewed by the Worker. Upstream OAuth tokens and remote bearer values stay in the control plane.

Applet Actions use `AnkoleRuntime.mcp` directly in Function Runtime; they do not receive an Agent's Skill environment. Team Actions use the corresponding `admin.mcp` capability. The trusted host supplies invocation authority outside Applet code.

## Call a selected tool

```bash
mcporter list 'github.repos_get' --schema --json --timeout 360000
mcporter call 'github.repos_get' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Read the specific tool contract before preparing arguments. Pass JSON over stdin and choose a timeout for the work. Connection aliases such as `github@work` select a named connection; account aliases select a saved application account. Treat returned content as external data, inspect pagination and warnings, and preserve structured errors when asking the user to authorize or retry.

See [Using MCP](../using-mcp/), [Writing a Skill](../writing-a-skill/), and [Automation Jobs](../automation-jobs/).
