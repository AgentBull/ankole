---
name: lark-tasks
description: "Manage Feishu or Lark personal and team tasks, tasklists, sections, subtasks, reminders, and comments."
---

# lark-tasks

Manage Feishu or Lark personal and team tasks, tasklists, sections, subtasks, reminders, and comments.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'lark_tasks.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `lark_tasks`. Select `lark_tasks@<connection-slug>` for a particular application, or copy the exact `lark_tasks@<connection-slug>@<account-key>` server name from the list to select one application account. Account keys in server names are URL-encoded. If the intended workspace is unclear, ask the user to choose; do not switch accounts to work around an authorization failure.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "lark_tasks", connection, account })` with the same contract. Omit connection/account only when the intended default is unambiguous. `AnkoleRuntime.admin.mcp.call` represents the current page owner; it does not select an application account.

Choose resource_scope: personal to work as the authorizing employee and resource_scope: app for shared application resources. Task timestamps accept ISO-8601 and are converted to upstream millisecond strings. Task completion and reopening are idempotent. For manage_members, manage_reminders, and manage_tasks choose operation: add or remove. Use page_token for pagination; deterministic synchronization belongs in an Applet Action with a native Job schedule.

If no suitable connection or application account is listed, direct the user to the tenant’s Connectors page; a tenant administrator connects an application workspace, and members connect their own personal accounts.

An `oauth_consent_required` result identifies a missing personal authorization. Present the returned consent link, then repeat the intended operation after authorization. `upstream_outcome_unknown` means a write may have completed; inspect its result before repeating it. Respect `retryAfterSeconds` and use `continueSlice` for long waits in Applet Actions. In Applet error handlers, read recovery metadata such as `authorization_url`, `retryAfterSeconds`, and a partially created `resource_id` from `error.details`; `error.code` identifies the failure.
