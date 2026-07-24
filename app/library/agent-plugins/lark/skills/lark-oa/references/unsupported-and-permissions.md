# Unsupported operations and permission handling

The OA skill is bot-only. In the pinned `lark-cli` v1.0.69 catalog, every generated Approval method is user-only. Route approval definitions, instances, creation, cancellation, CC, and decisions to `lark-approvals`. Do not relabel an Approval command with `--as bot` or switch identity inside this Skill.

Do not act as an employee, task inbox owner, or personal OKR owner. Personal task views and APIs that depend on a logged-in employee are unsupported.

An endpoint is usable only when command help lists bot identity and the application has both the required scope and organizational visibility. Attendance and OKR APIs commonly require administrator configuration or an explicit availability range in addition to scopes.

On failure:

1. Preserve the structured error and inspect `permission_violations`, `console_url`, `error.code`, `error.message`, and `error.hint`.
2. For missing scope, provide the developer-console URL and exact bot scopes. Do not start an authorization flow.
3. For visibility errors, identify the missing app availability, administrator grant, record membership, or target ownership.
4. If the binding app identity or tenant token is absent, report that this Agent has no available Lark signal binding; preserve the provider error and do not request credentials in chat.
5. Never switch identities to complete an unsupported personal workflow.

If the bot can create a Task or OKR item but cannot perform its human-owned step, create or update the item as requested and clearly hand off that step to the assigned employee.
