---
title: Principal and AuthZ
description: The permission boundary of an Ankole deployment instance — Principals as accountable subjects, permission grants, group membership, and runtime enforcement rather than prompt convention.
section: Developer guide
order: 106
---

Every action in Ankole — a human signing in, an agent running a turn, a job waking its owner — is done by a Principal, and what that Principal may do is decided by AuthZ at the moment of the action. This page maps that boundary against the real code in `Ankole.Principals` and `Ankole.AuthZ`.

The decisive property, stated up front: authorization is a runtime fact, enforced at the boundary, not a convention asked of the model. A Principal is a durable, accountable subject; its grants live in PostgreSQL; and every checked action is evaluated against an explicit snapshot by the kernel, with a decision the caller must honor.

## The Principal: one accountable subject

A Principal is the durable accountable subject for humans, Agents, and system services. Each Principal belongs to exactly one tenant and has a globally unique opaque `uid`. The `principals` row has a `type` of `:human`, `:agent`, or `:system`, a `status` of `:active` or `:disabled`, and a `membership` of `:member` or `:guest` for `:human` (`nil` for `:agent` and `:system`).

A human Principal has one `HumanUser` row, zero or more site-scoped `SiteCredential` rows (`principal_site_credentials`, such as verified Email OTP addresses), and zero or more tenant-scoped `ExternalIdentity` rows (`principal_external_identities`, federated from Identity Providers). An agent Principal has one `Agent` row. Routing all subjects through one table gives accountability one shape: every audit row, grant, and group membership points at a stable Principal `uid`.

Human `membership` controls tenant collaboration. Internal `member` humans join the computed `all_humans` group; external `guest` humans require explicit Pod page shares or Agent grants, cannot join built-in administrator groups (`siteadmin` or `pod_admin`), cannot use Private space, and do not receive the Brain `world` scope.

A disabled Principal is not partially usable. The kernel's decision returns `principal_disabled` for a disabled subject, so disabling a Principal removes its authority across the instance without chasing down every grant.

## The grant: who may do what

Each row in `permission_grants` has exactly one grantee owner (`num_nonnulls(principal_uid, group_id, source_page_id) = 1`), enforced by `Ankole.AuthZ.Validations.GrantShape` and PostgreSQL check constraints:

- a Principal (`principal_uid`),
- a Principal group (`group_id`), or
- a **Pod Page Userset** (`source_page_id` paired with an exact `source_action` in `page_view`, `page_write_records`, `page_edit`, or `page_manage`).

Pod ACL grants also store `target_page_id` and `target_scope` (`container` for subtree inheritance, or `self` for the target page alone). Every grant carries:

- a `resource_pattern` — validated by `Input.validate_resource_pattern_syntax` across unified colon-separated namespaces: `site_console:**` (Site Console), `tenant_console:**` (Pod administration), `agent:<uid>` and `agent:<uid>:tool:<fn>` (runtime Agent and tool invocation), and `pod:**` (`pod:space:**`, `pod:private:<uid>:**`, `pod:**:<page-id>:**`, `pod:**:<page-id>:page`). A bare `"**"` pattern is invalid;
- an `action` — an exact string with no colon allowed;
- a `condition` — a CEL boolean expression, default `"true"`, validated by `Input.validate_condition_syntax`;
- a `description` and `metadata` for operator readability.

Separate partial unique indexes enforce natural-key uniqueness (`owner + resource_pattern + action + condition`) for Principal, group, and Userset grants. Creating, upserting, and updating grants are control-plane operations; the database rejects invalid owner shapes or malformed rules.

## Groups: static and computed membership

A Principal group is a named collection through which Principals receive grants. A group has a `domain` (`:operator`, `:directory`, `:im_group`, or `:signal_source`), a `kind` (`:static` or `:computed`), and an optional CEL `computed_condition` for computed groups.

Every tenant has the built-in computed `all_humans` group with condition `principal.type == "human" && principal.membership == "member" && principal.status == "active"`, and the built-in static `pod_admin` group (`tenant_console:**` operations in that Pod). The privileged site tenant also has the built-in static `siteadmin` group (`site_console:**` and `tenant_console:**`). Only active Human `member` principals can join `siteadmin` or `pod_admin`. Selecting another data tenant in the Site Console does not change the operator's identity or `siteadmin` lookup. Static membership lives in `principal_group_memberships`; computed membership is evaluated against the authorization snapshot. External directories and IM channels synchronize groups through `principal_group_external_bindings`.

## How a decision is made

The control plane and the kernel split the work deliberately, and the split is the reason AuthZ is enforceable rather than advisory:

- **The control plane owns state, Ash enforcement, and snapshot assembly.** Protected Ash actions declare rules through `Ankole.AuthZ.Extension` and enforce them at runtime through `Ankole.AuthZ.Authorizer` using `%Ankole.AuthZ.Actor{principal, interactive_principal, turn_authority, authn, interactive_authn}`. Verified browser, OIDC, and Worker authentication facts populate `context.request.authn` for CEL conditions. When `interactive_principal` is present (such as human-driven Agent turns), both the Agent and the Human must pass (`Human ∩ Agent`).
- **The kernel and PostgreSQL evaluate deterministic rules.** For standard checks, `Ankole.AuthZ.Snapshot` loads the Principal, group memberships, and candidate grants in one SQL statement, and the Rust kernel evaluates resource patterns, computed groups, and CEL conditions. For Pod pages, a 4-bit ACL anchor graph (`page_view=1`, `page_write_records=2`, `page_edit=4`, `page_manage=8`; roles `view=1`, `contribute=3`, `edit=7`, `manage=15`) evaluates request-dependent CEL conditions once in the Rust kernel and resolves direct grants, groups, container inheritance, and Userset edges in PostgreSQL with `WITH RECURSIVE` (`UNION` least fixed point).

The public entrypoints on `Ankole.AuthZ` are `authorize(subject, resource, action, context)`, `allowed?/4` for a boolean, `authorize_decision/4` for one action's full decision map, `authorize_all_decision/4` for a batch of actions on one resource, `authorize_checks/3` for independent resource/action checks over one snapshot, and `evaluate_pod_context/2` for Pod context evaluation. None of them trusts a caller's claim about what a Principal can do.

## Decision statuses

A decision comes back in one of four statuses, and each maps to a caller obligation:

- **`allow`** — the action is permitted; proceed.
- **`deny`** — the action is forbidden, with the `deniedAction` named. The caller must not perform it.
- **`principal_disabled`** — the subject is disabled. Treated as a denial with a specific cause.
- **`invalid_request`** — the request itself was malformed. The caller fixes the request rather than retrying blindly.

Diagnostics are emitted on each decision, so a denial is observable. `Ankole.AuthZ.Decision.result/1` turns a decision map into `:ok | {:error, reason}`, which is the shape callers branch on.

## Where enforcement actually bites

AuthZ is not a layer the agent can talk around, because the runtime consults it at the boundaries that matter:

- AIGateway resolves every call's subject from a verified token, and the subject's grants decide which model selectors and providers it can reach.
- Tool preparation and dispatch evaluate `agent:<uid>:tool:<fn>` (`invoke` with normalized `context.request.args`), and Pod operations intersect `Human ∩ Agent` permissions on human-derived turns.
- The Session Driver checks its persisted fence before it commits. Worker Job operations check the durable Job attempt fence and the authenticated connection identity.
- Site Console (`/api/v2`) and Pod administration (`/api/v2/pod/admin`) operations require verified browser proofs, CSRF protection, and current `site_console:**` or `tenant_console:**` grants.

The model never gets to assert "I am allowed." The boundary checks the Principal and the grant, and acts on the decision.

## The operator surface

Site Console JSON:API routes under `/api/v2` expose Principals, groups, and grants (`site_console:**`), while Pod administrators manage tenant members, invitations, settings, and Identity Providers under `/api/v2/pod/admin/*` (`tenant_console:**`):

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

Managing grants and memberships runs through `Ankole.AuthZ`, which validates owner shape, resource-pattern syntax, and CEL condition syntax before writing rows. PostgreSQL check constraints and partial unique indexes enforce the same invariants in storage.

## What Principal and AuthZ are not

AuthZ is not a prompt instruction and not a hope. It does not ask the model to be responsible; it checks the Principal and enforces the answer. A Principal does not divide one instance into separate enterprise boundaries, and it is not a per-request role. It is a stable, accountable subject whose authority is granted, grouped, and evaluated. The kernel is not a second policy engine for the operator to configure. It deterministically evaluates the snapshot assembled by the control plane, and the caller must honor that decision.

## Next steps

- For how a verified token resolves to a Principal at the AIGateway edge, read the [AIGateway API](../ai-gateway/).
- For how the agent Principal's Driver fence fences a turn, read the [Sessions](../sessions/).
