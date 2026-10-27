---
title: Principal and AuthZ
description: The permission boundary of an Ankole deployment instance — Principals as accountable subjects, permission grants, group membership, and runtime enforcement rather than prompt convention.
section: Developer guide
order: 106
---

Every action in Ankole—a human signing in, an Agent running a turn, or a background job waking its owner—executes on behalf of a Principal, and `Ankole.AuthZ` decides what that Principal may do at the moment of execution. This page maps that permission model to the implementation in `Ankole.Principals` and `Ankole.AuthZ`.

Authorization in Ankole is enforced at runtime boundaries rather than requested through model prompts. Each Principal is a durable, accountable subject whose grants live in PostgreSQL; on every checked operation, the Rust kernel evaluates an explicit snapshot and returns a decision that the caller must honor.

## The Principal: one accountable subject

A Principal is the durable accountable subject for humans, Agents, and system services. Every Principal belongs to a single tenant and carries a globally unique opaque `uid`. Its `principals` row records a `type` (`:human`, `:agent`, or `:system`), a `status` (`:active` or `:disabled`), and—for `:human` rows—a `membership` of `:member` or `:guest` (`nil` for `:agent` and `:system`).

Each human Principal owns one `HumanUser` row, zero or more site-scoped `SiteCredential` rows (`principal_site_credentials`, such as verified Email OTP addresses), and zero or more tenant-scoped `ExternalIdentity` rows (`principal_external_identities`, federated from Identity Providers). Each Agent Principal owns one `Agent` row. Routing every actor through a single `principals` table keeps accountability uniform: every audit entry, permission grant, and group membership references a stable Principal `uid`.

Human `membership` governs collaboration boundaries inside a tenant. Internal `member` humans automatically match the computed `all_humans` group, whereas external `guest` humans require explicit Pod page shares or Agent grants, cannot join built-in administrator groups (`siteadmin` or `pod_admin`), cannot access Private space, and do not receive the Brain `world` scope.

When a Principal is disabled, it loses authority everywhere immediately: the kernel returns `principal_disabled` on every check, revoking access across the deployment without requiring operators to hunt down individual grants.

## The grant: who may do what

Every row in `permission_grants` belongs to exactly one grantee owner (`num_nonnulls(principal_uid, group_id, source_page_id) = 1`), enforced at both the Ash layer (`Ankole.AuthZ.Validations.GrantShape`) and PostgreSQL check constraints:

- a Principal (`principal_uid`),
- a Principal group (`group_id`), or
- a **Pod Page Userset** (`source_page_id` paired with a `source_action` of `page_view`, `page_write_records`, `page_edit`, or `page_manage`).

Pod ACL grants additionally record `target_page_id` and `target_scope` (`container` for subtree inheritance, or `self` for the target page alone). Every grant specifies:

- a `resource_pattern` — validated by `Input.validate_resource_pattern_syntax` across unified colon-separated namespaces: `site_console:**` (Site Console), `tenant_console:**` (Pod administration), `agent:<uid>` and `agent:<uid>:tool:<fn>` (runtime Agent and tool invocation), and `pod:**` (`pod:space:**`, `pod:private:<uid>:**`, `pod:**:<page-id>:**`, `pod:**:<page-id>:page`). A bare `"**"` pattern is rejected;
- an `action` — an exact action string containing no colons;
- a `condition` — a CEL boolean expression (defaulting to `"true"`) validated by `Input.validate_condition_syntax`;
- a `description` and `metadata` for operator context.

Separate partial unique indexes enforce natural-key uniqueness (`owner + resource_pattern + action + condition`) across Principal, group, and Userset grants. All grant creation, upsert, and update paths run in the control plane, while PostgreSQL constraints reject malformed owner shapes or invalid rules in storage.

## Groups: static and computed membership

A Principal group is a named collection through which Principals inherit grants. Each group carries a `domain` (`:operator`, `:directory`, `:im_group`, or `:signal_source`), a `kind` (`:static` or `:computed`), and—for computed groups—a CEL `computed_condition`.

Every tenant ships with the built-in computed `all_humans` group (`principal.type == "human" && principal.membership == "member" && principal.status == "active"`) and the built-in static `pod_admin` group (`tenant_console:**` operations in that Pod). The privileged site tenant also includes the built-in static `siteadmin` group (`site_console:**` and `tenant_console:**`). Only active Human `member` Principals may join `siteadmin` or `pod_admin`. Switching the selected data tenant in the Site Console never alters the operator's own Principal identity or `siteadmin` check. Static memberships are stored in `principal_group_memberships`, computed memberships are evaluated against the authorization snapshot at check time, and external directories and chat channels sync their groups through `principal_group_external_bindings`.

## How a decision is made

The Elixir control plane and the Rust kernel divide authorization work cleanly so that checks remain deterministic and enforceable:

- **The control plane owns durable state, Ash enforcement, and snapshot assembly.** Protected Ash actions declare authorization rules via `Ankole.AuthZ.Extension` and enforce them at runtime through `Ankole.AuthZ.Authorizer` using `%Ankole.AuthZ.Actor{principal, interactive_principal, turn_authority, authn, interactive_authn}`. Verified browser, OIDC, and Worker authentication facts populate `context.request.authn` for CEL evaluation. Whenever `interactive_principal` is present—such as on a human-initiated Agent turn—both the Agent and the initiating Human must be authorized (`Human ∩ Agent`).
- **The Rust kernel and PostgreSQL evaluate deterministic rules.** For standard checks, `Ankole.AuthZ.Snapshot` fetches the Principal, its static group memberships, and candidate grants in a single SQL query, and the Rust kernel evaluates resource patterns, computed groups, and CEL conditions. For Pod pages, Ankole evaluates request-dependent CEL conditions once in the Rust kernel and then resolves the 4-bit ACL anchor graph (`page_view=1`, `page_write_records=2`, `page_edit=4`, `page_manage=8`; roles `view=1`, `contribute=3`, `edit=7`, `manage=15`)—spanning direct grants, groups, container inheritance, and Userset edges—inside PostgreSQL using `WITH RECURSIVE` (`UNION` least fixed point).

`Ankole.AuthZ` exposes `authorize(subject, resource, action, context)`, `allowed?/4` for boolean checks, `authorize_decision/4` for a full decision map, `authorize_all_decision/4` for multi-action checks on a single resource, `authorize_checks/3` for independent resource/action checks over a shared snapshot, and `evaluate_pod_context/2` for Pod ACL evaluation. None of these entrypoints ever trusts a caller's self-asserted permissions.

## Decision statuses

Every authorization check resolves to one of four statuses, each imposing a clear contract on the caller:

- **`allow`** — the action is permitted and execution may proceed.
- **`deny`** — the action is forbidden, with `deniedAction` identifying the blocked action; the caller must abort.
- **`principal_disabled`** — the Principal is disabled, which callers must treat as an immediate denial.
- **`invalid_request`** — the authorization request itself was malformed, signaling a caller bug rather than a transient failure.

Ankole emits telemetry diagnostics on every decision so denials remain observable, and `Ankole.AuthZ.Decision.result/1` converts a decision map into `:ok | {:error, reason}`—the tuple shape that callers branch on.

## Where enforcement actually bites

An Agent cannot prompt or reason its way around AuthZ because the runtime enforces permissions at every privileged boundary:

- **AIGateway** resolves the calling subject from a verified credential, and that Principal's grants govern which model selectors and upstream providers it may invoke.
- **Tool preparation and dispatch** check `agent:<uid>:tool:<fn>` (`invoke` with normalized `context.request.args`), while Pod operations intersect `Human ∩ Agent` permissions on human-initiated turns.
- **Session Drivers and Worker Jobs** verify the persisted workspace epoch fence or durable Job attempt fence alongside the authenticated Worker connection before committing results.
- **Site Console (`/api/v2`) and Pod administration (`/api/v2/pod/admin`)** require verified browser session proofs, CSRF tokens, and active `site_console:**` or `tenant_console:**` grants.

Because the model never asserts its own authority, every boundary independently verifies the Principal and its grants before acting.

## The operator surface

Site Console JSON:API routes under `/api/v2` manage Principals, groups, and grants (`site_console:**`), while Pod administrators manage tenant members, invitations, settings, and Identity Providers under `/api/v2/pod/admin/*` (`tenant_console:**`):

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/principals` | List Principals |
| `POST` | `/api/v2/principals` | Pre-create a Human member Principal |
| `GET` | `/api/v2/principals/:uid` | Read one Principal |
| `PATCH` | `/api/v2/principals/:uid` | Update a Human Principal's profile (`display_name`) |
| `PATCH` | `/api/v2/principals/:uid/membership` | Change a Human Principal's `membership` (`member` or `guest`) |
| `GET` | `/api/v2/principals/:uid/access` | Read Human access state, restrictions, and restoration review |
| `POST` | `/api/v2/principals/:uid/access-disables` | Suspend (`suspended`) or offboard (`offboarded`) a Human Principal |
| `POST` | `/api/v2/principals/:uid/access-restorations` | Restore a disabled Human Principal after clearing restrictions |
| `GET` | `/api/v2/principals/:uid/groups` | List a Principal's groups |
| `GET` | `/api/v2/principals/:uid/grants` | List a Principal's grants |
| `GET` | `/api/v2/principal-groups` | List groups |
| `POST` | `/api/v2/principal-groups` | Create an operator group |
| `GET` | `/api/v2/principal-groups/:name` | Read a group |
| `PATCH` | `/api/v2/principal-groups/:name` | Update a group |
| `DELETE` | `/api/v2/principal-groups/:name` | Delete an operator group |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | Preview a computed group's members |
| `POST` | `/api/v2/permission-grants` | Create an operator permission grant (`PATCH`/`DELETE` on `/api/v2/permission-grants/:id`) |

All grant and membership mutations pass through `Ankole.AuthZ`, which validates grantee owner shapes, resource-pattern syntax, and CEL condition syntax before writing to PostgreSQL, where check constraints and partial unique indexes enforce the same invariants.

## What Principal and AuthZ are not

AuthZ is neither a system-prompt guideline nor a per-request role claim—it verifies durable Principal grants at the execution boundary. Nor does a Principal split a tenant into sub-organizations; it identifies one accountable actor whose permissions are granted, grouped, and audited. Finally, the Rust kernel is not a separate policy store that operators configure independently: it deterministically evaluates snapshots assembled by the Elixir control plane.

## Next steps

- For how a verified token resolves to a Principal at the AIGateway edge, read the [AIGateway API](../ai-gateway/).
- For how the Agent Principal's Driver fence protects turn commits, read [Sessions](../sessions/).
