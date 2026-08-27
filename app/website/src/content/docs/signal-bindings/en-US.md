---
title: Signal routing rules
description: Connect a chat application to an Agent and select how it handles group messages.
section: User guide
order: 14
---

A signal routing rule decides which Agent receives a message. One rule currently connects one chat application directly to one Agent. An Agent can use several rules to connect to several chat applications.

The term “signal” leaves room for more than chat. Future rules can use routing expressions to select an Agent by channel, conversation, or other conditions. They can also deliver events from systems such as Salesforce.

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

**May intervene** does not make the Agent reply to every message. It lets the Agent decide when to speak, and each message is judged once. To tell the Agent when to speak in one group, give it a channel standing order right in that group (for example "only speak when CI turns red"). If it still speaks too often, first tighten the standing orders or its role instructions. See [Ambient intervention](../ambient-intervention/) for the judgment behavior and standing orders.

Use **Addressed messages only** for a group that needs question-and-answer behavior only.

## Choose what happens to unknown senders

Ankole maps each sender to a known account automatically: an account that
directory sync or login already imported matches by its platform id, and a new
platform account matches when the platform reports an email or mobile number
that an existing account owns. This mapping is best effort — a sender from
outside your directory, or a user of a local-login account who has never been
linked, maps to nothing.

**When account auto-mapping fails** selects what the rule does with such a
sender:

| Option | Behavior |
|---|---|
| **Manual review** (default) | The sender appears under **Identity → Pending mappings** in the Console. Until an administrator binds the account there, a message that addresses the Agent gets one fixed reply that asks the sender to contact an administrator, and nothing else happens — the message does not enter context or Brain learning. |
| **Create a standalone account** | Ankole creates a standalone account for the sender and serves them at once. Use this for open channels where anyone may talk to the Agent. |

Unaddressed group chatter from an unmapped sender is always ignored.

On Lark and Feishu this also covers external groups: members from another
tenant have no employee id, so they always need manual binding or the
standalone option. You can also map an account before the person ever writes,
for example to link a local-login user to their chat account, from the same
Console page.

## How chat conversations become Brain knowledge

A routing rule controls message delivery, not knowledge scope. When Brain learns from a chat conversation, it uses the conversation kind and known identities to set access:

- **Group chat:** members and Agents in the channel's current member group can use the learned knowledge. Brain does not learn from a group that has no member group.
- **Direct message:** the human counterpart and the Agent bound to the rule can use the learned knowledge. Other Agents cannot use it by default.

Public facts can become instance-wide knowledge. Content with an explicit confidentiality requirement can be limited to the relevant speaker. All other learned content keeps the group-chat or direct-message access above. See [Brain](../brain/) for model requirements and retrieval behavior.

## Edit, disable, or enable a rule

The list shows enabled rules by default. Turn on **Show disabled** when you must inspect or restore an older rule.

Select **Edit** to view the current non-secret settings. You can change the target Agent, group-message mode, or chat credentials. If you select another Agent, new messages go to that Agent.

The server does not return stored tokens or secrets to the browser. Leave a credential field empty to keep its encrypted value. Enter a new value only when you want to replace it.

Select **Disable** to stop new message delivery while keeping the rule, chat-application link, and history chain. To restore it, find the rule under **Show disabled** and select **Enable**. You do not have to create the rule again.

## If the Agent does not reply

- **The Channel Provider is missing:** open **Agent Library → Control Plane Plugins**, enable its plugin, and restart the control plane when the page tells you to.
- **The bot receives no group messages:** check the provider event subscriptions, permissions, and application release state. DingTalk and WeCom group messages must explicitly @-mention the bot.
- **WeCom behaves unexpectedly:** compare the behavior with the WeCom tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) first — the usual causes are a bot not created by a super administrator, a missing trusted-IP entry, or a conversation the user has not activated yet.
- **The rule is saved but there is no reply:** confirm that the target Agent is enabled, its model configuration works, and the rule is available in the rule list.
- **Direct messages work but group messages do not:** check the group-message mode and confirm that the bot belongs to the target group.

Use the provider-specific permissions, events, and credentials in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule).

For a DingTalk rule, streaming card replies need one AI card template on the DingTalk card platform. The advanced section of the DingTalk tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) shows how to build it.
