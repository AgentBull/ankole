---
title: Principals and permission groups
description: Sync people and the organization directory, then assign access with directory, static, or computed groups.
section: User guide
order: 49
---

Ankole represents people, Agents, and internal system services as Principals. Permission groups let you manage Principals collectively, while permission grants define which resources a Principal or group may access.

Connecting an Identity Provider synchronizes employees and organizational structure automatically so you do not have to maintain department memberships by hand. People can also join through passwordless Email OTP (`SiteCredential`), Pod invitations (`/join/:token`), or administrator pre-creation.

## How an Identity Provider synchronizes the organization

When you enable directory sync on an Identity Provider, Ankole maps its external directory into two kinds of records:

- **Employees** become human Principals, with profile attributes such as display names and avatars kept up to date by sync.
- **Departments, user groups, and organizational units** become directory permission groups whose memberships update on each sync.

When the external directory defines nested departments, a member of a child department is also added to every ancestor department group, so a single grant on a parent department covers all of its sub-departments.

Ankole runs an initial full sync as soon as you save the Identity Provider and repeats a full sync every six hours by default. Providers that support incremental sync also push user and department changes between full syncs.

To trigger an immediate refresh, open **Console → Identity Providers**, select the Provider, and choose **Run full sync**. When it finishes, verify the updated records under **Access → Principals** and **Access → Permission groups**.

Because your external identity system remains the source of truth for directory groups, always update department structure and group membership in the company directory rather than trying to edit directory groups manually in Ankole.

If an expected person or department is missing after sync, check the external application's directory read scopes and visibility rules—granting API credentials does not automatically expose the entire organization tree.

See [Quick start](../quickstart/#2-set-up-the-identity-provider-first) for instructions on connecting your first Identity Provider.

## View principals

Open **Console → Access → Principals** to inspect each Principal's display name, UID, type, membership tier, and status:

- **Human** Principals originate from Identity Provider sign-in or directory sync, passwordless Email OTP (`SiteCredential`), Pod invitations (`/join/:token`), or administrator pre-creation. Every human Principal has a tenant `membership` of either `member` or `guest`. Internal `member` humans automatically match the built-in computed `all_humans` group. External `guest` humans require explicit Pod page shares or Agent grants, cannot join built-in administrator groups (`siteadmin` or `pod_admin`), cannot access Private space, and do not receive the Brain `world` scope (`pod.allow_external_guests` governs guest admission and Pod access).
- **Agent** Principals are created automatically whenever you create an Agent.
- **System** Principals are created by Ankole for internal service operations.

Select a Principal's name or **View details** to inspect both its group memberships and its direct grants. The Principal's UID and type are assigned by the identity or runtime subsystem and are read-only. When auditing access, always check both group memberships and direct grants, since a Principal often receives permissions exclusively through groups.

## Select the correct permission group

Each kind of permission group has a single membership owner:

| Permission group | Use it when | Membership owner |
| --- | --- | --- |
| **Directory group** | The department or user group already exists in your company directory | Identity Provider sync |
| **IM group** | Access should track membership in a chat channel or group | Chat-channel sync |
| **Signal source group** | Access should include everyone who has interacted through a specific routing rule | Signals admission |
| **Provider members group** | Access should cover everyone that a single Identity Provider imported (`<provider>:members:all`) | Identity Provider sync |
| **Static group** | The team exists only in Ankole, or has a small, rarely changing roster | An administrator |
| **Computed group** | Members can be selected deterministically from Principal attributes | A CEL expression evaluated by Ankole |

Directory and IM groups appear automatically in the permission-group list, and their memberships are read-only in the Console because they mirror external systems. Administrators create and maintain static and computed groups directly in Ankole. Every tenant also includes two built-in groups: the static `pod_admin` group (`tenant_console:**` operations in that Pod) and the computed `all_humans` group (all active internal Human members). In addition, the privileged site tenant includes the static `siteadmin` group (`site_console:**` and `tenant_console:**`). Only active Human `member` Principals can belong to `siteadmin` or `pod_admin`.

Prefer a directory group whenever your company directory already models the team—when someone changes departments or leaves the organization, the next incremental or full sync updates their access automatically.

## Create a static group

1. Open **Console → Access → Permission groups** and select **New group**.
2. Enter a stable lowercase identifier, a display name, and a description.
3. Select **Static**, then save the group.
4. Open the saved group and select **Add member** under **Members**.

Adding a member immediately grants them every permission attached to the group, and removing them revokes that access just as quickly.

## Create a computed group

A computed group stores no explicit member list and accepts no manual additions. Instead, whenever Ankole evaluates permissions, it runs a single CEL boolean expression against `principal` to determine whether the subject belongs to the group.

To create one, choose **Computed** and enter a boolean CEL expression under **Membership condition**. Your expression can inspect the following `principal` fields:

| Field | Meaning | Typical value |
| --- | --- | --- |
| `principal.uid` | Stable Principal UID | `01958f1a-...` |
| `principal.type` | Principal type | `human`, `agent`, or `system` |
| `principal.membership` | Human tenant membership | `member` or `guest` for `human`; `null` for `agent` and `system` |
| `principal.status` | Principal status | `active` or `disabled` |
| `principal.displayName` | Display name (may be empty) | `Alex Smith` |
| `principal.avatarURL` | Avatar URL (may be empty) | A URL from the Provider |

For example, this expression matches all active internal human members (the same rule used by the built-in `all_humans` group):

```text
principal.type == "human" && principal.membership == "member" && principal.status == "active"
```

If you omit `principal.membership == "member"`, the rule also matches active external `guest` humans.

Similarly, this expression matches all active Agents:

```text
principal.type == "agent" && principal.status == "active"
```

As you type the expression, the Console previews every matching active Principal. Review both the count and the matched names before saving so the expression does not match a broader audience than intended.

Once saved, a group's name and type cannot be changed. You can edit the membership condition of a custom computed group at any time—rechecking the live preview before saving—whereas Ankole locks the condition on built-in computed groups as read-only.

CEL expressions do not have access to employee email addresses, job titles, or department hierarchies. Always use a synchronized directory group for department-based access rather than matching against `principal.displayName`.

## Add a grant

Open a permission group or Principal, select **New grant** in the grants section, and fill in:

- **Resource pattern:** the resources covered by the grant;
- **Action:** the permitted operation, such as `read` or `update`;
- **Condition:** an optional CEL constraint (leave blank for unconditional access);
- **Description:** why this permission is needed.

Attach grants to permission groups whenever possible, reserving direct Principal grants for genuine one-off exceptions. Updating or deleting a grant takes effect immediately for its owner and all members of that group.

Because a grant's owner is immutable after creation, move a grant by creating the new grant on the target group or Principal first, verifying access, and then deleting the old grant.

## Assign access by organization structure

Suppose every employee in the research department needs read access to a specific Agent:

1. Confirm that your Identity Provider has synchronized the research department and its members.
2. Open the corresponding directory permission group in the Console.
3. Add a `read` grant for the target Agent on that group.
4. Sign in as a member of the research department and verify that they can open the target Agent, while resources outside the grant remain inaccessible.

Later, when someone joins or leaves the research department in your company directory, the next directory sync updates their access automatically without any grant edits in Ankole.

Never treat a saved form alone as proof of working access control—verify with a real member account to confirm that the resource pattern, action, and group sync all match your intent.

## Suspend or offboard a person

When someone takes leave or departs the organization, disable their Principal rather than attempting to delete it. Open the person under **Principals and permission groups**, enter a reason under **Account access**, and select the appropriate disposition:

- **Suspend (`suspended`)** revokes active Console sessions, OAuth sessions, and tokens on their next use across all devices and halts future work, while preserving the person's personal `SiteCredential`s, email aliases, and Pod contact email or phone bindings. If they return, you can restore the same Human Principal without re-binding credentials.
- **Offboard (`offboarded`)** revokes sessions and tokens, halts future work, and additionally releases unshared personal `SiteCredential`s, email aliases, and Pod contact email or phone bindings within that tenant. Ankole writes `released_identifiers` watermarks to the audit log so that if a future hire receives the same email address, they are assigned a fresh Human UID. Offboarding still releases those identifiers if the account was already suspended earlier.

Under both dispositions, the Principal UID, immutable enterprise subject records, historical work outputs, and audit trails remain intact.

An Identity Provider can also disable an account automatically: when directory sync observes a Feishu departure, freeze, or reviewed removal from the synchronized directory scope—or a DingTalk departure—Ankole disables the matching Human Principal. Conversely, Ankole never restores a disabled account from an Identity Provider event alone, and never mistakes a transient network error for an employee departure.

Disabling an account stops future work running under that person's authority: Ankole cancels or rejects scheduled runs, messages, Background Agent Jobs, Workflows, and automations before their next execution begins. Any execution attempt that was already admitted is allowed to finish normally and recorded as such rather than as a failed stop. Work items without a verified authority owner pause with `work_authorization_review_required` until an administrator classifies them under **Review work with unknown authority**—an audited decision that can be recorded only once.

On the Principal's detail page, you can inspect the current access state, disposition, identity source, disablement reasons and timestamps, acting operator or sync source, cleanup status for each affected work item, and back-channel logout status for each OIDC Client. If any work cleanup or OIDC logout notification fails, the Console surfaces the affected target with a retry action.

To run **Restore account**, an administrator must verify the person's identity and supply a reason. The Console walks you through clearing every active restriction, previews the group memberships, direct grants, and Pod Page Userset grants that will resume, and requires your explicit approval of those permissions. A restriction placed by an Identity Provider can be cleared only after a recent successful directory check confirms that the user is active upstream. After restoration, the user signs in again (and re-authorizes any personal Feishu connection); revoked sessions, released credentials, and cancelled work remain revoked.

If no active Human administrator remains in `siteadmin` or in a tenant's `pod_admin` group, an operator with shell access to the control plane can promote a verified active Human `member` through the audited recovery command (`Ankole.Release.recover_admin`):

```sh
# Recover site administration (siteadmin in the privileged tenant)
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified

# Recover Pod administration (pod_admin in the named tenant)
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

Ankole refuses to run this command if an active administrator already exists in the target group, or if the target Principal is disabled or a `guest`.

See [Principal and AuthZ](../principal-authz/) for the underlying runtime permission architecture.
