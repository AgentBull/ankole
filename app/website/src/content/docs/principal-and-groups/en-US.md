---
title: Principals and groups
description: The operator's task-oriented view of AuthZ — list Principals, manage groups, assign members, create and review permission grants.
section: User guide
order: 49
---

Principals are who can act in Ankole; groups are how you scope their authority; grants are what they can do. This page is the operator's task-oriented view of the permission surface — the routes for managing Principals, groups, members, and grants, with worked examples. It complements the [Principal and AuthZ](../principal-authz/) concept page with concrete operations.

The decisive property, stated up front: grants are owned by exactly one Principal or one group — never both, never neither. A grant on a group reaches every member of that group; a grant on a Principal reaches only that Principal. Use groups when authority scales by team membership; use direct Principal grants when one Principal needs something unique.

## List Principals

```bash
curl https://ankole.example.com/api/v1/principals \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /principals` lists every Principal — humans, agents, and system services. Read one with `GET /principals/:uid`, including its type (`human`/`agent`/`system`) and status (`active`/`disabled`). A disabled Principal loses authority across the installation immediately — use it to revoke access without deleting the Principal.

## List a Principal's groups and grants

```bash
curl https://ankole.example.com/api/v1/principals/<uid>/groups -H "Authorization: Bearer $CONSOLE_TOKEN"
curl https://ankole.example.com/api/v1/principals/<uid>/grants -H "Authorization: Bearer $CONSOLE_TOKEN"
```

The groups list shows which AuthZ groups the Principal belongs to (static membership, computed membership, and synced directory groups). The grants list shows every permission grant owned directly by this Principal — not grants inherited through group membership.

## Manage groups

```bash
# List groups
curl https://ankole.example.com/api/v1/principal-groups -H "Authorization: Bearer $CONSOLE_TOKEN"

# Create a group
curl -X POST https://ankole.example.com/api/v1/principal-groups \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "name": "on-call", "domain": "operator" }'

# Read a group
curl https://ankole.example.com/api/v1/principal-groups/on-call -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Groups carry a `domain` — `operator` (managed by you), `directory` (synced from an IdP), or `im_group` (from a chat platform). Operator-domain groups are the ones you manage directly; directory groups are managed by the IdP sync.

## Manage group members

```bash
# Add a member
curl -X PUT https://ankole.example.com/api/v1/principal-groups/on-call/members/<principal_uid> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

# Remove a member
curl -X DELETE https://ankole.example.com/api/v1/principal-groups/on-call/members/<principal_uid> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Adding a member to a group immediately grants them every permission the group's grants allow. Removing them revokes it. For directory-synced groups, manage membership in the source directory — the sync propagates the change.

## Manage permission grants

```bash
# Create a grant on a group
curl -X POST https://ankole.example.com/api/v1/permission-grants \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "group_id": "<group-uuid>",
    "resource_pattern": "agent:agent-1",
    "action": "read"
  }'

# Read a grant
curl https://ankole.example.com/api/v1/permission-grants/<id> -H "Authorization: Bearer $CONSOLE_TOKEN"

# Update a grant
curl -X PATCH https://ankole.example.com/api/v1/permission-grants/<id> \
  -H "..." -d '{ "condition": "true" }'

# Delete a grant
curl -X DELETE https://ankole.example.com/api/v1/permission-grants/<id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

A grant carries a `resource_pattern` (what it applies to), an `action` (what it permits), and a `condition` (a CEL boolean, default `true`). The `resource_pattern` uses a pattern syntax; the `action` must not contain a colon (the colon separates resource from action in the kernel). Set the owner to a group (`group_id`) or to a Principal (`principal_uid`) — never both.

## A worked example

Give the on-call team read access to a specific agent:

1. Create the group `on-call` (domain: `operator`).
2. Add the on-call humans as members (`PUT .../members/<uid>`).
3. Create a grant on the group: `resource_pattern: "agent:agent-1"`, `action: "read"`.
4. Every member of `on-call` can now read that agent — verify through `GET /principals/<uid>/groups`.

## What this guide is not

It is not the concept page — for the Principal/AuthZ model, decision statuses, and the kernel evaluation, read [Principal and AuthZ](../principal-authz/). It is not a directory-sync guide — see [Identity providers](../identity-providers/) for how directory groups arrive. And it is not a security-hardening guide — see [Security hardening](../security-hardening/) for the least-authority posture.

## Next steps

- For the concept page, read [Principal and AuthZ](../principal-authz/).
- For directory-synced groups, read [Identity providers](../identity-providers/).
- For the least-authority posture, read [Security hardening](../security-hardening/).
- For the Console routes, read the [Console API reference](../console-api/).
