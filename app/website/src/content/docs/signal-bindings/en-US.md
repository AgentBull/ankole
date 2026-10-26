---
title: Signal routing rules
description: Connect a chat application to an Agent and select how it handles group messages.
section: User guide
order: 14
---

A signal routing rule decides which Agent receives an incoming message or event. Each chat rule connects one chat application to one Agent. An Agent can use several rules to connect to several chat applications.

A chat adapter records messages in a Conversation and creates Signals for the target Agent. A CloudEvents webhook endpoint can also receive events from external systems and deliver them as Signals.

If you have not prepared a Slack, Microsoft Teams, Lark, Feishu, or DingTalk application, complete the Channel Provider steps in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) first.

## Create a routing rule

1. Open **Signal Routing** in the Console and select **New routing rule**.
2. Select the Agent that will receive messages and the Channel Provider adapter.
3. Enter a clear rule name, such as `support-slack`.
4. Select the group-message mode.
5. Enter the credentials and connection details for the chat application, and save the rule.
6. Send a message to the bot in that chat application. Confirm that the selected Agent replies.

Give each bot account its own chat application and routing rule. If several Agents must use different bot accounts, create a separate application for each bot and then create each rule.

This keeps Agent identities and messages separate and lets you rotate each credential by itself.

## Select a group-message mode

The Console shows only the modes that the selected Channel Provider supports:

| Mode | What happens to a group message that does not address the Agent |
|---|---|
| **Addressed messages only** | The Agent does not see the message and does not reply. |
| **Observe unaddressed messages** | The message enters the conversation context but does not wake the Agent. The Agent can use it as context after someone addresses it. |
| **May intervene** | The Agent first decides whether joining the conversation will help. It replies only when it decides to speak. |

Slack, Microsoft Teams, Lark, and Feishu support all three modes. DingTalk and WeCom can receive only group messages that explicitly address the bot, so the Console offers only the first mode for them. WeCom has many more limits than this one (no recall, no files in groups, the Agent cannot start a conversation), so we do not recommend it as your first channel. See the WeCom tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule).

**May intervene** does not make the Agent reply to every message. It lets the Agent decide when to speak, and each batch of new messages is evaluated once. To tell the Agent when to speak in one group, give it a channel standing order right in that group (for example "only speak when CI turns red"). If it still speaks too often, first tighten the standing orders or its role instructions. See [Ambient intervention](../ambient-intervention/) for the judgment behavior and standing orders.

Use **Addressed messages only** for a group that needs question-and-answer behavior only.

## Choose what happens to unknown senders

Ankole maps each sender to a known account automatically: an account that
directory sync or login imported matches by its platform ID, and a new
platform account matches when the platform reports an email or mobile number
that an existing account owns. This mapping is best effort: a sender outside
your directory, or an Email OTP (`SiteCredential`) user whose chat account is
not linked, does not match automatically.

**When account auto-mapping fails** selects what the rule does with such a
sender:

| Option | Behavior |
|---|---|
| **Manual review** (default) | The sender appears under **Identity → Pending mappings** in the Console. Until an administrator binds the account there, a message that addresses the Agent gets one fixed reply that asks the sender to contact an administrator, and nothing else happens — the message does not enter context or Brain learning. |
| **Create a standalone account** | Ankole creates a standalone account for the sender and serves them at once. Use this for open channels where anyone may talk to the Agent. When the sender's platform ID is already the identifier of an existing account, such as an Email OTP (`SiteCredential`) account or a verified Pod `email` identity whose identifier is that email address, Ankole creates nothing and holds the sender for manual review, because only an administrator can decide that they are the same person. |

Unaddressed group chatter from an unmapped sender is always ignored.

On Telegram, Discord, and LINE, every sender is unknown at first: these consumer chat platforms have no company directory, and the platform reports no email or mobile number. Keep **Manual review** and map each person to their account once. WhatsApp reports the sender's verified phone number, so a person whose account owns that mobile number is mapped at once. An email sender is never matched by an unlinked profile email or a `SiteCredential` login email alone, because an unauthenticated `From` address proves nothing: only an explicit Pod `email` identity binding admits the sender. Directory sync creates that binding for employees, and an administrator creates it here for external contacts. On Lark and Feishu, this page also covers external groups: members from another
tenant have no employee ID, so they need manual binding or the
standalone option. An administrator can also map an account before the person sends a message,
for example to link an Email OTP (`SiteCredential`) user to their chat account, from this
Console page.

## How chat conversations become Brain knowledge

A routing rule controls message delivery, not knowledge scope. When Brain learns from a chat conversation, it uses the conversation kind and known identities to set access:

- **Group chat:** members and Agents in the channel's current member group can use the learned knowledge. Brain does not learn from a group that has no member group.
- **Direct message:** the human counterpart and the Agent bound to the rule can use the learned knowledge. Other Agents cannot use it by default.

Public facts can become knowledge shared within the tenant. Content with an explicit confidentiality requirement can be limited to the relevant speaker. All other learned content keeps the group-chat or direct-message access above. See [Brain](../brain/) for model requirements and retrieval behavior.

## Edit, disable, or enable a rule

The list shows enabled rules by default. Turn on **Show disabled** when you must inspect or restore an older rule.

Select **Edit** to view the current non-secret settings. You can change the target Agent, group-message mode, or chat credentials. If you select another Agent, new messages go to that Agent.

The server does not return stored tokens or secrets to the browser. Leave a credential field empty to keep its encrypted value. Enter a new value only when you want to replace it.

Select **Disable** to stop new message delivery while keeping the rule, chat-application link, and history chain. To restore it, find the rule under **Show disabled** and select **Enable**. You do not have to create the rule again.

## If the Agent does not reply

- **The Channel Provider is missing:** Control Plane Plugins are strictly site-scoped (`/api/v2/site/control-plane-plugins`), so they appear only in site/global scope in the Site Admin Console rather than inside a tenant's or Agent's Agent Library scope. Open the Site Admin Console (`/site-admin-console`), go to **Agent Library** with scope set to **Global defaults**, open the **Control Plane Plugins** tab, enable the plugin, and restart the control plane when prompted.
- **The bot receives no group messages:** check the provider event subscriptions, permissions, and application release state. DingTalk and WeCom group messages must explicitly @-mention the bot.
- **WeCom behaves unexpectedly:** compare the behavior with the WeCom tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) first — the usual causes are a bot not created by a super administrator, a missing trusted-IP entry, or a conversation the user has not activated yet.
- **The rule is saved but there is no reply:** confirm that the target Agent is enabled, its model configuration works, and the rule is available in the rule list.
- **Direct messages work but group messages do not:** check the group-message mode and confirm that the bot belongs to the target group.

Use the provider-specific permissions, events, and credentials in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule).

For a DingTalk rule, streaming card replies need one AI card template on the DingTalk card platform. The advanced section of the DingTalk tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) shows how to build it.
