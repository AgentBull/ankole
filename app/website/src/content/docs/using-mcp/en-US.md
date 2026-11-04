---
title: Use an MCP-backed Skill
description: Configure connections and use MCP tools from Agent Skills or Applet Actions.
section: Developer guide
order: 123
---

Enable the relevant Skill for an Agent and ask for the business outcome. The Agent reads the Skill, selects a tool, and invokes MCPorter from the shell. Main Agents and Background Agent Jobs use the same control-plane gateway; neither loads the entire upstream catalog as native model tools.

## Configure access

For built-in GitHub, Lark, and Linear Toolkits, configure an application on the Pod Connections page. Members connect their own accounts when the operation needs personal authority. Select a named connection when several are available. Missing consent returns a link for the member to authorize and retry.

For a Skill's remote HTTP server, configure the value named by `bearer_token_env_var` in Environment variables. The gateway reads that value and injects it upstream; the remote secret is excluded from Worker snapshots. Local `stdio` servers execute in the Worker and follow their declared command contract.

## Use tools in an Applet

Publish an Action in the Applet server module. Its handler calls `AnkoleRuntime.mcp.call(tool, arguments, {server, connection})`; team operations use `AnkoleRuntime.admin.mcp`. The Function Runtime host manages invocation credentials. Use the Automation panel to create a Job, connect sources, and inspect Runs. Applet Actions do not launch Worker scripts or inherit an Agent's enabled Skills.

## Recover from failures

Use each tool's declared input and output contract. Pass shell JSON through stdin and an explicit timeout as shown in [MCP reference](../mcp/). Check business errors, pagination, and partial results even when transport succeeds. A partial write identifies the completed resource; repair the remaining operation instead of blindly repeating the entire request. An uncertain write outcome requires checking upstream state first.

See [Automation Jobs](../automation-jobs/) and [Environment variables](../worker-env/).
