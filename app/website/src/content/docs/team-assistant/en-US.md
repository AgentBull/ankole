---
title: A team assistant that watches the channel
description: Turn an addressed-only bot into a team assistant — let it observe the channel, sync directory members into AuthZ, and decide when to speak up versus stay quiet.
section: Guides
order: 306
---

The first-bot guides end with an agent that only wakes when @-mentioned. This guide takes the next step: an agent that **watches** a shared channel — reads what is said, notices who is in it, and decides for itself when to help. That is the shape of a customer-success assistant, an on-call helper, or a team knowledge steward.

The flow, in one line: **start from a working addressed-only bot → widen the group-message policy → sync directory members into AuthZ → set the assistant's judgment in its persona → tune the threshold by watching it.**

The difference from [Your first Lark bot](../lark-first-bot/) is one field plus one load of judgment. The field widens what the agent sees; the judgment, written into the persona, decides what it does with what it sees.

## What you are building

A team assistant that behaves like this:

1. **Every message in the channel** becomes a mirrored entry the agent can see.
2. **Directory members** sync into AuthZ groups, so the agent knows who is in the team and what they are allowed to do.
3. **The agent reads each message** and, per its persona, decides whether to reply now, record what it saw for later, or stay quiet.
4. **A human can @-mention it** to force a reply when the agent's judgment was too quiet.

The lever is not a switch that makes the agent chatty. It is a policy plus a persona that tells the agent when chatty is the wrong call.

## Prerequisites

- A working Ankole installation with one agent and one chat binding, following [Your first Lark bot](../lark-first-bot/) (or the Slack/DingTalk/Teams equivalents).
- The agent bound to a **group** channel, not a direct message — observation only makes sense where a conversation is happening.
- An identity provider configured for the same platform (Lark, Entra ID, Google Workspace, or Slack), so directory sync has a source to sync from.

## Step 1: Widen the group-message policy

The binding's `unaddressed_group_message_policy` has three values, and they are the whole knob:

| Policy | What the agent does with a non-mention group message |
|---|---|
| `ignore` | does not even mirror the message — sees nothing |
| `record_only` *(default)* | mirrors the message but does not wake; the agent can recall it later, but does not act on it now |
| `may_intervene` | mirrors the message **and** produces a `may_intervene` event, so the agent wakes and can decide whether to speak |

Move the binding from `addressed_only` to `may_intervene`:

```bash
curl -X PATCH https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "unaddressed_group_message_policy": "may_intervene" }'
```

`may_intervene` does **not** mean "reply to everything." It means "wake up and decide." Whether the agent actually replies is the persona's call, which is why Step 3 matters as much as this one. On Lark and DingTalk, widening the policy also needs the platform-side permission to read non-mention group messages (`im:message.group_msg` on Lark) — grant it in the app configuration.

`record_only` is worth knowing as a middle ground: it lets the agent build a memory of the channel without ever interrupting. Use it when you want the assistant observant but silent unless explicitly asked.

## Step 2: Sync directory members into AuthZ

A team assistant that does not know who is on the team is guessing. Sync the platform's directory into AuthZ groups so the agent's permission scope reflects the real team.

Configure directory sync through the identity-provider surface — the same one you configured for admin sign-in. For Lark and DingTalk it pulls IM groups and org structure; for Entra ID and Google Workspace it pulls directory groups; for Slack it pulls workspace membership. Trigger a sync:

```bash
curl -X POST https://ankole.example.com/api/v1/identity-providers/<provider_id>/sync-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Once synced, the platform's groups exist as Ankole AuthZ groups, and you can assign grants to them through [Principal and AuthZ](../principal-authz/). The assistant, as a Principal, can be granted the capabilities those groups scope — or not. This is the lever that keeps an observing assistant from overreaching: it sees the channel, but what it is allowed to *do* is still fenced by AuthZ.

## Step 3: Write the assistant's judgment into the persona

The policy lets the agent wake; the persona decides what it does when it wakes. This is where a team assistant is won or lost. Author a `MISSION.md` that names the judgment:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "You are the team assistant in this channel.\n\nSpeak up when: someone asks a question no one answers in a few minutes; someone asks for a fact you know or can look up; a decision is being made and you have relevant context.\n\nStay quiet when: the channel is just chatting; someone is already answering; your reply would be noise. Silence is allowed and usually correct.\n\nWhen unsure, prefer quiet. A human can @-mention you to force a reply." }'
```

The judgment is specific to your team — what "noise" means, what "relevant context" means, when "a few minutes" is. Write the real answers, not generic advice. The persona is the place a team assistant is tuned, over a few days of watching what the agent actually does.

## Step 4: Watch the threshold and tune

Let the assistant run for a day. Two failure modes tell you which way to tune:

- **It is too loud** — replies to things it should have left alone. Tighten the persona (more cases where quiet is correct), or drop the policy back to `record_only` while you rewrite the judgment. A loud assistant erodes trust faster than a quiet one.
- **It is too quiet** — never speaks even when it should. Loosen the persona, or confirm the binding is actually `may_intervene` and the platform-side group-message permission is granted.

The right answer is rarely "always speak" or "never speak." It is a judgment the persona encodes, and you refine it by watching.

## Step 5: Let it remember across days

A team assistant improves when it remembers what the team cares about. Two moves, both optional:

- **Brain curated knowledge** — through the [Brain](../brain/) surface, curate durable facts (who owns what, which decisions are settled, which questions come up often). Recall reads these during the turn, so the assistant's answers are anchored to what the team has decided, not just what the model guesses.
- **`record_only` as a memory floor** — even when the policy is `may_intervene`, the mirroring that `record_only` does is still happening. The agent has access to the channel's recent context, which is what lets it notice "someone asked this yesterday."

## Operate it

- **Quiet it without disabling it** — `PATCH` the policy back to `record_only`. The agent keeps observing but stops deciding to speak.
- **Scope what it can do** — even with `may_intervene`, the agent only does what its AuthZ grants allow. Tighten the grants when the assistant has capabilities it should not use in the channel.
- **Rotate the persona** — the judgment is a document, not code. Edit it, watch a day, edit again.

## What this guide is not

It is not a license to let an agent talk whenever it wants. `may_intervene` is a policy that lets the agent wake; the persona is what stops it from being noise. And it is not a replacement for AuthZ — the agent sees the channel, but what it is allowed to do is still fenced by its Principal grants. The team assistant pattern is policy + persona + permission, set together.

## Next steps

- For the policy field and the binding model, read [Signal bindings](../signal-bindings/).
- For the permission model that fences what the assistant can do, read [Principal and AuthZ](../principal-authz/).
- For the memory it can draw on, read [Brain](../brain/).
