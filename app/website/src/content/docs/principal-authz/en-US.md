---
title: Principal and AuthZ
description: The permission boundary of an Ankole deployment instance — Principals as accountable subjects, permission grants, group membership, and runtime enforcement rather than prompt convention.
section: Developer guide
order: 106
---

Every action in Ankole — a human signing in, an agent running a turn, a job waking its owner, a Brain write — is done by a Principal, and what that Principal may do is decided by AuthZ at the moment of the action. This page maps that boundary against the real code in `Ankole.Principals` and `Ankole.AuthZ`.

The decisive property, stated up front: authorization is a runtime fact, enforced at the boundary, not a convention asked of the model. A Principal is a durable, accountable subject; its grants live in PostgreSQL; and every checked action is evaluated against an explicit snapshot by the kernel, with a decision the caller must honor.

## The Principal: one accountable subject

A Principal is the durable accountable subject shared by humans, agents, and system services. The `principals` table is keyed by a `uid` (a typed `PrincipalKey`, forced lowercase and present by check constraints), and each row carries a `type` — `:human`, `:agent`, or `:system` — and a `status` of `:active` or `:disabled`.

A human Principal has one `HumanUser` and any number of `ExternalIdentity` rows (the identities an operator federated in). An agent Principal has one `Agent` row. The point of routing both through one table is that accountability has one shape: whoever did the thing, there is a Principal row that did it, and it has a stable uid that every audit row, grant, and group membership points at.

A disabled Principal is not partially usable. The kernel's decision returns `principal_disabled` for a disabled subject, so disabling a Principal removes its authority across the instance without chasing down every grant.

## The grant: who may do what

A permission grant is owned by exactly one Principal or exactly one Principal group — never both, never neither, enforced by `validate_owner_shape` and a database check constraint. A grant carries:

- a `resource_pattern` — what the grant is over, with syntax validated by `Input.validate_resource_pattern_syntax`;
- an `action` — what the grant permits, with no colon allowed (the colon is reserved for the resource/action split);
- a `condition` — a boolean expression, default `"true"`, validated by `Input.validate_condition_syntax`;
- a `description` and `metadata` for operator readability.

Grants are append-only in spirit and natural-key unique per owner (one grant per Principal, one per group, on the natural index). Creating, upserting, and updating grants are control-plane operations; the caller cannot construct a grant that points at an owner shape the database would reject.

## Groups: static and computed membership

A Principal group is a named collection Principals can be granted through, so authority scales without per-Principal rows. A group has a `domain` — `:operator`, `:directory`, or `:im_group` — a `kind` of `:static` or `:computed`, and an optional `computed_condition` for computed groups.

Two built-in groups seed the deployment instance. The `admin` group is the operator authority surface. The `all_humans` group has the computed condition `principal.type == "human" && principal.status == "active"`, so every active human is a member without anyone maintaining the list by hand. Static membership lives in `principal_group_memberships`; computed membership is evaluated against the snapshot. External directories (an IdP, an IM platform) can be synced into groups through external bindings, so an operator can point AuthZ at a directory it already trusts.

## How a decision is made

The control plane and the kernel split the work deliberately, and the split is the reason AuthZ is enforceable rather than advisory:

- **The control plane owns state and snapshot assembly.** For a checked action, it loads the Principal, its grants, its group memberships, and the relevant resource context, and assembles an explicit authorization snapshot.
- **The kernel owns deterministic rule evaluation.** It evaluates the snapshot's grants and conditions and returns a decision. Because the input is an explicit snapshot and the rules are deterministic, the same snapshot gives the same answer every time, and no in-memory cache can drift.

The public entrypoints are `AuthZ.authorize(principal_uid, resource, action, context)`, `allowed?/4` for a boolean, `authorize_all` for a batch of actions on one resource, and their `_decision` variants that return the full decision map. Every one of them builds a snapshot and hands it to the kernel; none of them trusts the caller's claim about what the Principal may do.

## Decision statuses

A decision comes back in one of four statuses, and each maps to a caller obligation:

- **`allow`** — the action is permitted; proceed.
- **`deny`** — the action is forbidden, with the `deniedAction` named. The caller must not perform it.
- **`principal_disabled`** — the subject is disabled. Treated as a denial with a specific cause.
- **`invalid_request`** — the request itself was malformed. The caller fixes the request rather than retrying blindly.

Diagnostics are emitted on each decision, so a denial is observable. `AuthZ.result/1` turns a decision into `:ok | {:error, reason}`, which is the shape callers branch on.

## Where enforcement actually bites

AuthZ is not a layer the agent can talk around, because the runtime consults it at the boundaries that matter:

- AIGateway resolves every call's subject from a verified token, and the subject's grants decide which model selectors and providers it can reach.
- The Actor Runtime fences every turn with an activation owned by the agent Principal; a reply from any other subject fails the fence.
- Brain scopes every read and write through the conversation declaration and the owner Principal; a write's authority mode is derived from the actor, not from the payload.
- Console operations run through a verified admin token, and the admin Principal's group membership decides what it may change.

The model never gets to assert "I am allowed." The boundary checks the Principal and the grant, and acts on the decision.

## The operator surface

Console-scoped routes expose the AuthZ model for inspection and management:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/principals` | List Principals |
| `GET` | `/principals/:uid` | Read one Principal |
| `GET` | `/principals/:uid/groups` | List a Principal's groups |
| `GET` | `/principals/:uid/grants` | List a Principal's grants |
| `GET` | `/principal-groups` | List groups |
| `POST` | `/principal-groups` | Create a group |
| `GET` | `/principal-groups/:name` | Read a group |
| `PATCH` | `/principal-groups/:name` | Update a group |
| `POST` | `/principal-groups/computed-member-previews` | Preview a computed group's members |

Managing grants and memberships goes through the AuthZ facade, which validates owner shape, resource-pattern syntax, and condition syntax before any row is written. The database check constraints are the backstop: a row that violates the owner-shape or no-colon rules cannot exist.

## What Principal and AuthZ are not

AuthZ is not a prompt instruction and not a hope. It does not ask the model to be responsible; it checks the Principal and enforces the answer. A Principal does not divide one instance into separate enterprise boundaries, and it is not a per-request role. It is a stable, accountable subject whose authority is granted, grouped, and evaluated. The kernel is not a second policy engine for the operator to configure. It deterministically evaluates the snapshot assembled by the control plane, and the caller must honor that decision.

## Next steps

- For how a verified token resolves to a Principal at the AIGateway edge, read the [AIGateway API](../ai-gateway/).
- For how the agent Principal's activation fences a turn, read the [Actor Runtime](../actor-runtime/).
- For how Brain derives its write authority from the actor, read the [Brain](../brain/) page.
