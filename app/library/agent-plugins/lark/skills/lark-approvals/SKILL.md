---
name: lark-approvals
description: "Read, submit, and process Feishu or Lark approvals, including attachments and comments."
---

# lark-approvals

Read, submit, and process Feishu or Lark approvals, including attachments and comments.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'lark_approvals.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `lark_approvals`. Select `lark_approvals@<connection-slug>` for a particular application, or copy the exact `lark_approvals@<connection-slug>@<account-key>` server name from the list to select one application account. Account keys in server names are URL-encoded. If the intended workspace is unclear, ask the user to choose; do not switch accounts to work around an authorization failure.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "lark_approvals", connection, account })` with the same contract. Omit connection/account only when the intended default is unambiguous. `AnkoleRuntime.admin.mcp.call` represents the current page owner; it does not select an application account.

Approval actions represent the active human who authorized this call. Ankole uses verified identity-provider user_id bindings for the interfaces that accept application tokens. Add-sign and rollback require personal OAuth because the upstream interfaces require a user token. approvals_create_instance requires a stable uuid; preserve it across retries. Form accepts an array of controls or an object keyed by definition control ID/name. Read the definition before constructing an unfamiliar form. Upload attachments with approvals_upload_file and use the returned file_code in the form. To handle cards, bind card.action.trigger from `connector://<auth-config-id>/lark` to the Applet Action that owns the flow, verify the operator against the authorized human, perform the selected approval action, and update the card using lark_im.im_update_message.

If no suitable connection or application account is listed, direct the user to the tenant’s Connectors page; a tenant administrator connects an application workspace, and members connect their own personal accounts.

For a file created in the Worker workspace, use the Pod `files.upload` operation with the target page ID, `local_path`, and role before calling an upload tool. Follow the `pod-content` Skill to choose or create that page and handle file versions. Use the returned `page_id` and `file.path` as `pages/<page-id>/<path>` in `file_ref`; a Worker filesystem path is not a Pod file reference.

An `oauth_consent_required` result identifies a missing personal authorization. Present the returned consent link, then repeat the intended operation after authorization. `upstream_outcome_unknown` means a write may have completed; inspect its result before repeating it. Respect `retryAfterSeconds` and use `continueSlice` for long waits in Applet Actions. In Applet error handlers, read recovery metadata such as `authorization_url`, `retryAfterSeconds`, and a partially created `resource_id` from `error.details`; `error.code` identifies the failure.

For a complete personal pending-task → interactive card → verified click → approval → card update Applet, use [the approval inbox example](examples/approval-inbox/README.md) and its packaged server source.
