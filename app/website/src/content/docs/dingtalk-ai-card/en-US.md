---
title: DingTalk AI card replies
description: Build the DingTalk AI card template that carries streaming Agent replies, and verify it before you rely on it.
section: User guide
order: 15
---

On DingTalk, an Agent reply can arrive as a plain Markdown message or as a streaming **AI card**. The card shows the answer as it is written, keeps a folded thinking area, and carries the buttons an Agent uses to ask a question. DingTalk cards are template-hosted: the layout lives on the DingTalk card platform, and Ankole only writes values into a fixed set of variables.

You therefore build one template per DingTalk organization, paste its id into the signal routing rule, and every Agent bound to that rule replies with cards. Leave the id empty and replies stay plain Markdown. Nothing else changes.

Budget about twenty minutes for the first template. The [verification](#verify-the-card) section tells you whether it worked, and the [troubleshooting](#troubleshooting) table maps each broken appearance to its cause.

## Before you start

You need:

1. A published enterprise-internal DingTalk app with the robot capability, already working as a chat channel. Follow [Signal routing rules](../signal-bindings/) first and confirm the Agent replies with plain text.
2. Permission to open 卡片平台 (Card Platform) in the DingTalk developer console and publish a template for that app.
3. These app permissions: interactive card instance write, and AI card streaming update.

If the Agent does not yet reply at all, fix that first. A card template cannot repair a channel that never delivers.

## Build the template

Open the DingTalk developer console → 卡片平台 → 新建模板 and choose the **AI 卡片** category. Only this category has the AI card container, which draws the writing indicator and the finished and failed states.

### 1. Add the variables

Add each variable below as a template variable, using exactly the name in the first column. A name that does not match leaves its area empty on every reply.

| Variable | Type | What Ankole writes |
|---|---|---|
| `flowStatus` | text | The card state: `2` while writing, `3` when done, `5` when failed |
| `state` | text | One status line, such as the running tool label, `已完成`, or `出错` |
| `answer` | Markdown, streaming | The reply body, rewritten in full on every frame |
| `thought` | Markdown | The transient thinking draft, blanked when the reply ends |
| `plan` | text | `执行计划 · 1/3` and one line per task |
| `activity` | text | One line per running tool call, blanked when the reply ends |
| `results` | text | One line per structured result |
| `receipts` | text | One line per recorded side effect |
| `actions` | text | A JSON list of buttons, empty when the Agent asks nothing |
| `meta` | text | Curated metadata: trigger, card number, counts, elapsed time |

### 2. Lay out the card

Put the components in this order inside the AI card container:

1. `meta` and `state` as small text lines at the top.
2. `plan` as text.
3. `thought` in a folded area, then `activity` in a second folded area. Both hold transient content and must not stay open after the reply ends.
4. `answer` as the main Markdown block. Set its content variable type to Markdown and enable streaming on this block. This is the only block Ankole updates at streaming speed.
5. `results` and `receipts` as text.
6. `actions` bound to the action area.

### 3. Bind the card state

Select the AI card container and bind its flow-status variable (`flowStatusVar`) to `flowStatus`. Keep the writing and failed states enabled.

This binding is what makes the card display anything at all. The container reads `flowStatus` to choose which state to draw, so a container whose status variable is unbound stays in its initial state forever, and often renders an empty body. Closing the reply stream does not move it; Ankole writes the value.

### 4. Publish and connect

Associate the template with the enterprise-internal app that owns the robot, publish it, and copy the template id. In the Console, open the DingTalk signal routing rule and paste the id into **AI card template id** (`cardTemplateId`). Save the rule.

The change applies to the next reply. There is nothing to restart.

## How a reply uses the card

One reply is a chain of cards, and each card is one DingTalk message:

1. Ankole creates and delivers a card, then streams `answer` into it as the Agent writes.
2. Past about 2.5 KB of source text the card is sealed, its state line becomes `回答继续于下一张卡片`, and the answer continues on a new card. A sealed card is never written again.
3. When the reply ends, the last card is sealed too: the thinking and activity areas are blanked, the final structure is written, and `flowStatus` becomes `3`, or `5` when the turn failed.
4. When the Agent asks a question, the last card stays in the writing state so its buttons remain live. A button press returns over the same Stream connection that carries messages.

Ankole re-verifies the operator's permission on every button press. A button that no longer answers a pending question is accepted and ignored.

## Verify the card

Send the Agent a message that produces several sentences, and watch one reply from start to finish:

1. **A card appears** instead of a text message. If a plain Markdown message arrives, the template id is empty or Ankole rejected the card — see the table below.
2. **The answer grows** while the Agent writes, and the card shows a writing indicator.
3. **The indicator stops** when the reply ends, and the answer is complete and readable.
4. **The thinking and activity areas are empty or gone** on the finished card.

Then ask something that needs a decision, so the Agent asks you back. A button must appear, and pressing it must continue the turn.

If a reply is long enough to span two cards, check that the first card ends with `回答继续于下一张卡片` and shows no writing indicator.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| The card is blank, or keeps a writing indicator after the reply ends | The AI card container's status variable is not bound to `flowStatus` | Bind it in step 3 and publish the template again |
| The card renders, but one area is always empty | That variable's name does not match, or the component is not bound to it | Compare the name against the table in step 1 |
| The answer appears only at the end, or not at all | The `answer` block is not a Markdown streaming block | Set its content variable type to Markdown and enable streaming |
| Replies are plain Markdown messages | The template id is empty, the template is not published to this app, or DingTalk rejected the card content | Check the id in the routing rule, then the control-plane logs for `param.contentUnsafe` or `param.cardNotExist` |
| Buttons appear but pressing one does nothing | The action area does not pass each button's `value` map through unchanged | Fix the action-area binding in the template |
| The reply arrives once as a card and later as plain text | A permanent rejection degraded this turn | This is intended. The reply is still delivered; check the logs for the rejection reason |

When a card path fails permanently, Ankole falls back to plain Markdown once for that reply and does not switch back and forth. The reply is always delivered.

## What DingTalk cannot do

DingTalk's card model is narrower than the Feishu and Lark card model, and Ankole does not pretend otherwise:

- The layout is a fixed variable set, not free-form card JSON. A rich result such as a table renders as text, not as a native table component.
- A single card holds about 3 KB, so a long answer becomes a chain of cards instead of one growing card.
- A card is always a new message in the conversation. DingTalk has no anchored reply, so a card cannot attach to the message that triggered it.
- Only the answer and the thinking draft move while the turn runs. The plan, activity, and metadata areas are written when a card is created and again when it is sealed.

DingTalk also delivers only direct messages and group messages that @-mention the robot. That limit belongs to the channel, not to the card.
