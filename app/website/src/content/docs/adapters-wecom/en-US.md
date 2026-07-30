---
title: WeCom adapter limits
description: Platform limits and prerequisites of the WeCom AI-bot channel, and why we do not recommend it as your first chat channel.
section: User guide
order: 16
---

Ankole can connect a WeCom (企业微信) AI bot as a chat channel and a WeCom self-built app as a login and directory provider. **If you can select a channel, we do not recommend WeCom as your first choice**: among the chat platforms Ankole supports, WeCom exposes the smallest bot capability set. Every limit below comes from the platform itself and Ankole cannot work around it. Lark, Feishu, DingTalk, Slack, and Microsoft Teams all give a more complete experience.

Select WeCom only when your organization already lives in it and accepts all limits on this page.

## Platform limits Ankole cannot remove

**Receiving messages**

- In a group, the Agent receives only messages that explicitly @-mention the bot. It never sees other group messages, so the **Observe unaddressed messages** and **May intervene** modes are unavailable. The Console offers only **Addressed messages only**.
- Images, voice, files, and video arrive in direct messages only. Group @-messages carry only text and mixed text-image content.
- A voice message arrives as the platform transcript only. The Agent never receives the audio.
- The bot gets no event when a user recalls or edits a message, so the Agent's view of history can go stale.

**Sending messages**

- Sent messages **cannot be recalled** (the platform has no recall API) and cannot be edited.
- No emoji reactions and no reply that targets one specific message.
- Proactive messages (for example scheduled-job results) have a precondition: **the user must message the bot in that conversation first**. The Agent cannot start a fresh conversation.
- The reply window after an inbound message is 24 hours; after that only the proactive path remains.
- Streaming replies (the typewriter effect) work only when replying to a user message; proactive sends deliver one complete Markdown message. A streaming message must also finish within the platform's 10-minute window, so long answers split into several messages.
- Send rate limits are about 30 messages per minute and 1000 per hour per conversation.

**Interaction and identity**

- After a user clicks a card button, the card can change only within a 5-second window. After that the card is frozen forever.
- **The bot must be created by a corp super administrator.** Otherwise the user ids in messages are encrypted and can never join the directory or sign-in identities.
- Directory sync requires the dedicated secret from Management tools → Contacts sync: since June 2022 the ordinary app credential no longer returns member names and other profile fields.
- There are no realtime directory-change events; changes converge through periodic full sync.

**Deployment requirements**

- Login and directory API calls require a **fixed egress IP** registered in the WeCom console trusted-IP lists (the self-built app and Contacts sync each have their own). A missing entry fails with error 60020.
- The login redirect domain must be a trusted domain of the self-built app.
- The platform allows exactly one long connection per bot. If another program connects with the same Bot ID, each connection kicks the other. When Ankole gets kicked, it parks and waits instead of fighting for the line.

## Comparison with other channels

| Capability | Lark / Feishu | DingTalk | Slack / Teams | WeCom |
|---|---|---|---|---|
| Read unaddressed group messages | ✅ | ❌ | ✅ | ❌ |
| Recall own sent messages | ✅ | ✅ | ✅ | ❌ |
| Receive images / files in groups | ✅ | partial | ✅ | ❌ |
| Agent starts a conversation | ✅ | ✅ | ✅ | ❌ (user must speak first) |
| Streaming replies | ✅ | ✅ | ✅ | reply-only |
| Realtime directory sync | ✅ | ✅ | ✅ | ❌ (periodic full) |

## If you still select WeCom

1. Create the AI bot in **API mode** with a **corp super administrator** account and record the Bot ID and Secret.
2. Create a self-built app (for sign-in), configure its trusted domain and trusted IP. For directory sync, enable API sync under Management tools → Contacts sync and record that secret and its trusted IP.
3. Give the Ankole deployment a fixed egress IP.
4. Create the WeCom rule in the Console under [Signal routing](../signal-bindings/) and configure the identity provider for sign-in and directory.
5. Have each user send the bot one message first to unlock proactive delivery for that conversation.
