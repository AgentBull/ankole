---
name: lark-calendar
description: "Manage Feishu or Lark personal and shared calendars, events, attendees, invitations, and free/busy queries."
---

# lark-calendar

Manage Feishu or Lark personal and shared calendars, events, attendees, invitations, and free/busy queries.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'lark_calendar.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `lark_calendar`. Select `lark_calendar@<connection-slug>` for a particular application, or copy the exact `lark_calendar@<connection-slug>@<account-key>` server name from the list to select one application account. Account keys in server names are URL-encoded. If the intended workspace is unclear, ask the user to choose; do not switch accounts to work around an authorization failure.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "lark_calendar", connection, account })` with the same contract. Omit connection/account only when the intended default is unambiguous. `AnkoleRuntime.admin.mcp.call` represents the current page owner; it does not select an application account.

Choose resource_scope: personal for the employee's calendar and resource_scope: app for shared calendars. Omit calendar_id to resolve the current identity's primary calendar. Event times accept ISO-8601 and are converted to upstream second strings. calendar_reply_event always represents an authorized human. Prefer creating the event and adding attendees as separate steps. If calendar_create_event returns partial_write_completed, keep resource_id and retry only calendar_manage_attendees; do not create the event again.

If no suitable connection or application account is listed, direct the user to the tenant’s Connectors page; a tenant administrator connects an application workspace, and members connect their own personal accounts.

An `oauth_consent_required` result identifies a missing personal authorization. Present the returned consent link, then repeat the intended operation after authorization. `upstream_outcome_unknown` means a write may have completed; inspect its result before repeating it. Respect `retryAfterSeconds` and use `continueSlice` for long waits in Applet Actions. In Applet error handlers, read recovery metadata such as `authorization_url`, `retryAfterSeconds`, and a partially created `resource_id` from `error.details`; `error.code` identifies the failure.
