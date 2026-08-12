---
title: Principals and permission groups
description: Sync people and the organization directory, then assign access with directory, static, or computed groups.
section: User guide
order: 49
---

Ankole represents people, Agents, and system services as principals. A permission group manages several principals together. A permission grant defines which resources a principal or group can use.

An Identity Provider usually synchronizes employees and the organization directory automatically. You do not have to create each employee or maintain department membership again in Ankole.

## How an Identity Provider synchronizes the organization

When you enable directory sync for an Identity Provider, Ankole converts its external directory into two types of data:

- Employees become human principals. Directory sync updates profile data such as names and avatars.
- Departments, user groups, and similar organization units become directory permission groups. Sync also updates their memberships.

If the external directory has a department hierarchy, a person in a child department also becomes a member of its parent department groups. A grant on a parent department can therefore cover people in its child departments.

Ankole starts the first full sync after you save the Identity Provider. It runs another full sync every six hours by default. Providers that support incremental sync can also send people and organization changes before the next full sync.

To refresh the directory immediately, open **Console → Identity Providers**, select the Provider, and select **Run full sync**. Check **Access → Principals** and **Access → Permission groups** when the sync completes.

The external identity system remains the source of truth for a directory group. Change departments and memberships in the company directory. Do not try to maintain these groups by hand in Ankole.

If the result does not contain an expected person or department, check the external application's directory permissions and availability scope. API access does not always give the application access to the complete organization.

See [Quick start](../quickstart/#2-set-up-the-identity-provider-first) to connect the first Identity Provider.

## View principals

Open **Console → Access → Principals**. The list shows the name, UID, type, and state:

- **Human** principals come from the company directory that an Identity Provider synchronizes.
- **Agent** principals appear when you create Agents.
- **System** principals are created by Ankole for internal service work.

Select the principal name or the trailing **View details** action to see its groups and direct grants. The principal UID, type, and state come from the identity or runtime owner and are read-only on this page. Check both groups and direct grants when you investigate access. A principal can have no direct grant but still get access through a group.

## Select the correct permission group

Each group source has a different membership owner:

| Permission group | Use it when | Membership owner |
| --- | --- | --- |
| **Directory group** | The department or user group already exists in the company directory | Identity Provider sync |
| **IM group** | Access must follow chat-group membership | Chat-channel sync |
| **Static group** | The team exists only in Ankole, or its small membership changes infrequently | An administrator |
| **Computed group** | Principal attributes can identify the members reliably | A CEL expression that Ankole evaluates |

Directory and IM groups appear automatically in the permission-group list. Their memberships come from the external system and are read-only in the Console. Administrators create and maintain static and computed groups in Ankole.

Use a directory group when the company directory already represents the target team. When a person changes teams or leaves, the next incremental or full directory sync adjusts access.

## Create a static group

1. Open **Console → Access → Permission groups** and select **New group**.
2. Enter a stable lowercase name, display name, and description.
3. Select **Static**, and then save the group.
4. Open the new group and select **Add member** in the Members section.

A new member immediately gets all grants on the group. Removing the member removes that access.

## Create a computed group

A computed group does not store a membership list and does not accept manual members. When Ankole checks access, it evaluates one CEL expression to decide if the principal belongs to the group.

Select **Computed** when you create the group. Enter a CEL expression in **Membership condition**. The expression must return `true` or `false` and reads the current principal through `principal`.

A computed group can currently use these fields:

| Field | Meaning | Typical value |
| --- | --- | --- |
| `principal.uid` | Stable principal UID | `research-agent` |
| `principal.type` | Principal type | `human`, `agent`, or `system` |
| `principal.status` | Principal state | `active` or `disabled` |
| `principal.displayName` | Display name, which can be empty | `Alex Smith` |
| `principal.avatarURL` | Avatar URL, which can be empty | A URL from the Provider |

This expression matches all active humans:

```text
principal.type == "human" && principal.status == "active"
```

This expression matches Agents whose UID starts with `research-`:

```text
principal.type == "agent" && principal.uid.startsWith("research-")
```

The Console previews all matching active principals while you enter the expression. Confirm the count and names before you save so that the group does not give access to more principals than you intended.

You cannot change the group name or type after you save it. You can edit the membership condition of a normal computed group. Check the live preview again before you save. Ankole owns the condition of a built-in computed group, so it is read-only in the Console.

CEL cannot currently read an employee's email address, job title, or department memberships. Use a synchronized directory group for department access. Do not infer organization membership from a display name.

## Add a grant

Open a permission group or principal and select **New grant** in the grants section. Then enter:

- **Resource pattern:** which resources the grant covers;
- **Action:** the allowed operation, such as `read` or `update`;
- **Condition:** an optional advanced limit; leave it empty for no extra condition;
- **Description:** why this access is necessary.

Prefer grants on permission groups. Use a direct principal grant only for an exception. A changed or deleted grant immediately affects its owner and related group members.

The grant owner is read-only after creation. To move a grant to another principal or group, create it under the new owner, verify the access result, and then delete the old grant.

## Assign access by organization structure

Suppose every employee in the research department must view one Agent:

1. Confirm that the Identity Provider synchronized the research department and its members.
2. Open the matching directory permission group.
3. Add a `read` grant for the target Agent to the group.
4. Sign in as one department member. Confirm that the member can open the target Agent but cannot open resources outside the grant.

Change research-department membership in the company directory. After the next sync, Ankole updates the group membership. You do not have to change the grants on the group.

A successful save is not enough evidence. Verify the result with a real member account so that you know the resource pattern, action, and membership source are correct.

See [Principal and AuthZ](../principal-authz/) for the full permission model.
