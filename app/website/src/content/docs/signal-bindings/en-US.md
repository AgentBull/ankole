---
title: Signal routing rules
description: Connect a chat application to an Agent and select how it handles group messages.
section: User guide
order: 14
---

A signal routing rule determines which Agent receives an incoming chat message or external event. Each chat rule connects one chat application to one Agent, and a single Agent can have multiple rules connecting it to different chat platforms.

When a message arrives, the chat adapter records it in a Conversation and admits Signals for the target Agent. You can also expose CloudEvents webhook endpoints to ingest events from external systems and route them as Signals.

If you have not yet created an application in Slack, Microsoft Teams, Lark, Feishu, or DingTalk, complete the Channel Provider setup in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) first.

## Create a routing rule

1. Open **Signal Routing** in the Console and select **New routing rule**.
2. Select the target Agent and the Channel Provider adapter.
3. Enter a descriptive rule name, such as `support-slack`.
4. Choose how the Agent should handle group messages.
5. Enter the chat application's credentials and connection settings, then save the rule.
6. Send a test message to the bot in that chat platform and confirm that the Agent replies.

Give every bot account its own dedicated chat application and routing rule—if multiple Agents need distinct bot personas, register a separate chat application for each bot so their identities, message streams, and credential rotations stay independent.

## Select a group-message mode

The Console displays only the group-message modes supported by the selected Channel Provider:

| Mode | What happens to a group message that does not address the Agent |
|---|---|
| **Addressed messages only** | The Agent neither sees the message nor replies to it. |
| **Observe unaddressed messages** | Ankole records the message in the conversation context without waking the Agent, so the Agent can reference it once someone addresses it later. |
| **May intervene** | Ankole wakes the Agent to evaluate whether stepping in would be helpful, and the Agent replies only when it chooses to speak. |

Slack, Microsoft Teams, Lark, and Feishu support all three modes. Because DingTalk and WeCom deliver only group messages that explicitly @-mention the bot, the Console offers only **Addressed messages only** for those platforms. WeCom imposes several additional platform restrictions—no message recall, no group file attachments, and no bot-initiated conversations—so we do not recommend it as your first channel; see the WeCom tab in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule).

Selecting **May intervene** does not cause the Agent to reply to every message; instead, Ankole evaluates each batch of new chatter once so the Agent can decide whether to chime in. To set clear boundaries for a specific room, give the Agent a standing order for that channel directly in chat (for example, "only speak when CI turns red"). If the Agent still chimes in too often, tighten that standing order or refine its `SOUL.md` / `MISSION.md` instructions; see [Ambient intervention](../ambient-intervention/) for details.

Choose **Addressed messages only** whenever a group wants strictly on-demand question-and-answer behavior.

## Choose what happens to unknown senders

Ankole maps each chat sender to a known Principal automatically whenever possible: accounts imported via directory sync or SSO match by platform user ID, and new chat accounts match when the platform reports a verified email address or mobile number already owned by an existing account. Because that lookup is best effort, someone outside your company directory—or an Email OTP (`SiteCredential`) user whose chat handle is not linked—will not match automatically.

Use **When account auto-mapping fails** to control how Ankole handles unmapped senders:

| Option | Behavior |
|---|---|
| **Manual review** (default) | Ankole queues the sender under **Identity → Pending mappings** in the Console. Until an administrator links the sender there, messages that address the Agent receive a single standard reply asking the sender to contact an administrator, and nothing enters conversation context or Brain learning. |
| **Create a standalone account** | Ankole provisions a standalone account immediately and lets the sender talk to the Agent—useful for public or community channels. However, if the sender's platform identifier already matches an existing account (such as an Email OTP `SiteCredential` address or a verified Pod `email` identity), Ankole withholds automatic creation and routes the sender to manual review so an administrator can confirm whether they are the same person. |

Ankole always ignores unaddressed group chatter from unmapped senders.

On consumer chat platforms such as Telegram, Discord, and LINE, every new sender starts out unmapped because those platforms have no enterprise directory and do not expose verified emails or phone numbers—keep **Manual review** enabled and bind each person's account once. WhatsApp provides the sender's verified phone number, so anyone whose Ankole account already owns that mobile number maps automatically. Conversely, Ankole never matches inbound email senders against unlinked profile emails or `SiteCredential` login addresses alone, because an unauthenticated `From` header proves nothing; only an explicit Pod `email` identity binding (populated by directory sync for employees, or added here by an administrator for external contacts) admits an email sender. On Lark and Feishu, external cross-tenant group members carry no internal employee ID, so they also go through manual binding or standalone account creation. Administrators can pre-link accounts on this Console page before a user ever sends a message—for example, to bind an Email OTP (`SiteCredential`) user to their chat account ahead of time.

## How chat conversations become Brain knowledge

A signal routing rule governs message delivery, whereas Brain derives knowledge visibility from the conversation type and verified participant identities:

- **Group chat:** Members and Agents belonging to the channel's synchronized member group can recall knowledge learned from that room; Brain skips learning altogether for groups that have no member group.
- **Direct message:** Only the human participant and the Agent bound to that routing rule can recall knowledge from the conversation by default.

Broad company facts can still be promoted to tenant-wide knowledge, while explicitly confidential statements can be restricted to the speaker alone; everything else retains the group-chat or direct-message audience above. See [Brain](../brain/) for retrieval and disclosure rules.

## Edit, disable, or enable a rule

By default, the Signal Routing page lists only active rules; toggle **Show disabled** to inspect or re-enable a paused rule.

Select **Edit** to update non-secret fields—such as the target Agent, group-message mode, or rotated credentials. Pointing a rule at a different Agent routes subsequent incoming messages to the newly selected Agent.

For security, the control plane never sends stored tokens or secrets back to the browser: leave secret fields blank when editing to preserve their existing encrypted values, and enter a value only when replacing a credential.

Select **Disable** to pause new message admission while preserving the rule configuration, external app binding, and conversation history. Later, toggle **Show disabled** and click **Enable** to resume delivery without recreating the rule.

## If the Agent does not reply

- **The Channel Provider does not appear:** Control Plane Plugins are strictly site-scoped (`/api/v2/site/control-plane-plugins`), so they appear only under **Global defaults** in the Site Admin Console rather than inside the **Agent Library** view for an individual tenant or Agent. Open the Site Admin Console (`/site-admin-console`), navigate to **Agent Library** with scope set to **Global defaults**, open the **Control Plane Plugins** tab, enable the channel plugin, and restart the control plane.
- **No group messages arrive:** Verify the external app's event subscriptions, scopes, and published release status, and remember that DingTalk and WeCom deliver group messages only when users @-mention the bot.
- **WeCom behaves unexpectedly:** Check the WeCom tab in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)—common pitfalls include bots not created by a super administrator, missing trusted-IP allowlist entries, or conversations that the user has not activated yet.
- **The rule is saved, but the Agent stays silent:** Confirm that the target Agent is enabled, its required model profiles resolve cleanly, and the routing rule itself is enabled.
- **Direct messages work, but group messages do not:** Check the rule's group-message mode and confirm that the bot has been added to the group channel.

Refer to [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) for each platform's required scopes, webhook events, and credentials. If you use DingTalk with streaming card replies, follow the advanced section of the DingTalk tab in [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) to create the required AI card template.
