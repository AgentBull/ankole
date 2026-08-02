---
title: Signal routing rules
description: Connect a chat application to an Agent and select how it handles group messages and memory.
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
4. Select the group-message mode and memory scope.
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

## Select the memory scope

**Shared** lets group messages enter the shared memory scope for this instance. Use it for work groups where the Agent must keep knowledge across conversations.

**Channel only** keeps group messages in memory that only this channel can read. Use it for customer data, confidential projects, or teams that must stay separate.

## Reconfigure or remove a rule

You can change the target Agent, group-message mode, memory scope, or chat credentials. If you select another Agent, new messages go to that Agent. Existing conversations and memory do not move automatically.

Removing a rule stops new message delivery but does not delete the chat application. You can create a new rule later with the same application.

## If the Agent does not reply

- **The Channel Provider is missing:** open **Agent Library → Control Plane Plugins**, enable its plugin, and restart the control plane when the page tells you to.
- **The bot receives no group messages:** check the provider event subscriptions, permissions, and application release state. DingTalk and WeCom group messages must explicitly @-mention the bot.
- **WeCom behaves unexpectedly:** compare the behavior with the WeCom tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) first — the usual causes are a bot not created by a super administrator, a missing trusted-IP entry, or a conversation the user has not activated yet.
- **The rule is saved but there is no reply:** confirm that the target Agent is enabled, its model configuration works, and the rule is available in the rule list.
- **Direct messages work but group messages do not:** check the group-message mode and confirm that the bot belongs to the target group.

Use the provider-specific permissions, events, and credentials in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule).

For a DingTalk rule, streaming card replies need one AI card template on the DingTalk card platform. The advanced section of the DingTalk tab in the [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) shows how to build it.
