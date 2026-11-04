---
name: linear
description: "Find and manage Linear issues, projects, cycles, comments, teams, labels, and workflow states through the official MCP service."
---

# linear

Find and manage Linear issues, projects, cycles, comments, teams, labels, and workflow states through the official MCP service.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'linear.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `linear`. Select `linear@<connection-slug>` for a particular application, or copy the exact `linear@<connection-slug>@<account-key>` server name from the list to select one application account. Account keys in server names are URL-encoded. If the intended workspace is unclear, ask the user to choose; do not switch accounts to work around an authorization failure.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "linear", connection, account })` with the same contract. Omit connection/account only when the intended default is unambiguous. `AnkoleRuntime.admin.mcp.call` represents the current page owner; it does not select an application account.

Connect a tenant-owned Linear OAuth application. Resolve team and workflow state names before creating issues. save_issue and save_project create when id is absent and update when it is present. Cursor pagination supports bounded Applet slices. The published tool contract is explicit; an upstream_contract_changed error requires a connector update rather than an arbitrary remote tool call.

If no suitable connection or application account is listed, direct the user to the tenant’s Connectors page; a tenant administrator connects an application workspace, and members connect their own personal accounts.

An `oauth_consent_required` result identifies a missing personal authorization. Present the returned consent link, then repeat the intended operation after authorization. `upstream_outcome_unknown` means a write may have completed; inspect its result before repeating it. Respect `retryAfterSeconds` and use `continueSlice` for long waits in Applet Actions. In Applet error handlers, read recovery metadata such as `authorization_url`, `retryAfterSeconds`, and a partially created `resource_id` from `error.details`; `error.code` identifies the failure.

List operations return `result.items`, `result.has_next_page`, and `result.cursor`; keep the cursor when continuing a sync. The adapter unwraps JSON text or structured content from Linear and reports `upstream_contract_changed` if its page shape changes.
