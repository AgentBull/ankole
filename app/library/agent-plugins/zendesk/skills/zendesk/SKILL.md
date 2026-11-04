---
name: zendesk
description: "Find and use zendesk operations through Ankole connections."
---

# zendesk

Read [the operation index](references/index.md), then open the selected operation's JSON contract for inputs, outputs, and retry annotations.

Write the JSON arguments to a temporary file, then call:

```sh
mcporter call 'zendesk.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Delete the temporary file after the call and check the exit code before parsing stdout. Results are returned in `result`.

Use `mcporter list` to find connections. The default server is `zendesk`; an explicit connection uses `zendesk@<connection-slug>`. Use the exact server name from discovery when selecting a team account. A personal account represents only its owner and that owner's personal assistant.

If a call returns `oauth_consent_required`, show the returned `authorization_url` so the user can authorize or bind their account. After the user finishes, resume the original operation. Do not ask the user to provide secrets in chat.

Applet routes and personal Job Actions use `AnkoleRuntime.mcp.call(tool, args, { server: "zendesk", connection, account })` with the route caller or personal Job's Human authority. Service Job Actions have no ordinary caller; use `AnkoleRuntime.admin.mcp.call(tool, args, { server: "zendesk", connection, account })` to act as the Applet's current owner. Both surfaces use the same published contract and check the acting principal's connection permissions. Select an explicit connection when the intended workspace is ambiguous.

A write that returns `upstream_outcome_unknown` may have completed. Inspect the resource before repeating it. Respect rate limit retry metadata. Platform permissions still apply to every operation.
