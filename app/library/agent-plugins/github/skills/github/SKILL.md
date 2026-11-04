---
name: github
description: "Manage GitHub repositories, branches, files, issues, pull requests, reviews, checks, Actions, and releases."
---

# github

Manage GitHub repositories, branches, files, issues, pull requests, reviews, checks, Actions, and releases.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'github.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `github`. Select `github@<connection-slug>` for a particular application, or copy the exact `github@<connection-slug>@<account-key>` server name from the list to select one application account. Account keys in server names are URL-encoded. If the intended workspace is unclear, ask the user to choose; do not switch accounts to work around an authorization failure.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "github", connection, account })` with the same contract. Omit connection/account only when the intended default is unambiguous. `AnkoleRuntime.admin.mcp.call` represents the current page owner; it does not select an application account.

All remote collaboration uses this Toolkit. Local git clone, fetch, and push use the provided GIT_ASKPASS integration under the active Turn. For a non-default connection or installation, set the same selectors on the Git command: `ANKOLE_GITHUB_CONNECTION=development ANKOLE_GITHUB_ACCOUNT=42 git clone https://github.com/owner/repo.git`. Use the original account key, not its URL-encoded server-name form. These selectors choose the same connection and account as the Toolkit; they contain no credentials. repos_create_branch requires a refs/heads/ ref and a commit SHA. Use repos_get_content before repos_put_content so updates include the current SHA. Binary logs/artifacts download to an explicit Pod destination; release asset uploads take file_ref. issues_manage_labels replaces the issue's full label set. A failed non-idempotent write with upstream_outcome_unknown must be inspected through a read tool before any repeat.

If no suitable connection or application account is listed, direct the user to the tenant’s Connectors page; a tenant administrator connects an application workspace, and members connect their own personal accounts.

For a file created in the Worker workspace, use the Pod `files.upload` operation with the target page ID, `local_path`, and role before calling an upload tool. Follow the `pod-content` Skill to choose or create that page and handle file versions. Use the returned `page_id` and `file.path` as `pages/<page-id>/<path>` in `file_ref`; a Worker filesystem path is not a Pod file reference.

An `oauth_consent_required` result identifies a missing personal authorization. Present the returned consent link, then repeat the intended operation after authorization. `upstream_outcome_unknown` means a write may have completed; inspect its result before repeating it. Respect `retryAfterSeconds` and use `continueSlice` for long waits in Applet Actions. In Applet error handlers, read recovery metadata such as `authorization_url`, `retryAfterSeconds`, and a partially created `resource_id` from `error.details`; `error.code` identifies the failure.
