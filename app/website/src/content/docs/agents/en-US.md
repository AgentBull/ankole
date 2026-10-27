---
title: Agents
description: Create an Agent in the Console, then configure its owner, durable behavior, models, capabilities, and environment variables.
section: User guide
order: 13
---

An Agent is a durable working identity inside the Ankole Agent Harness, complete with its own mission, owner, permissions, tools, model profiles, and file storage. Each Agent accesses Company Brain strictly within its authorized knowledge boundary and receives messages or external events through signal routing rules.

## Create an Agent

1. Open **Console → Agents** and select **New Agent**.
2. Enter the display name and review the generated handle. You can change the handle later; Ankole assigns a permanent, globally unique opaque UID when saving the Agent.
3. Enter the role, optional avatar URL, and Worker provider.
4. Select the human Principal who owns the Agent, then select the disclosure mode for group memory.
5. Save the Agent to unlock its durable instructions, model profiles, and Agent-specific environment variables on the detail page.

The role provides a short summary of the Agent's work—such as “Research Analyst” or “Customer Support”—while the four durable documents below govern its responsibilities, behavior, visual design, and confidentiality rules.

The Worker provider assigns the Agent to a [Worker pool](../worker-management/). If an API request omits the provider, Ankole uses the site default—or rejects creation when no site default exists—and once saved, the Worker provider binding cannot be changed. Even when multiple Agents share a pool, each Agent gets a separate Worker instance and its own persistent Home directory. Saving a new Agent does not start an instance right away; the control plane boots the Worker on demand when a turn requires computer work.

## Set ownership and group disclosure

Every Agent has a human owner who can inspect knowledge that the Agent authored or holds, as well as knowledge addressed directly to that Agent. Ownership alone does not grant access to a Group's knowledge unless the owner is also a member of that Group.

The disclosure mode for group memory controls what knowledge the Agent may draw on when multiple people can read its reply:

- **Strict** requires every participant in the group conversation to satisfy a memory item's audience scope.
- **Relaxed** checks only the person who asked the question, without narrowing results based on other participants in the conversation.

In one-on-one direct messages, both modes behave identically. Use **Strict** unless the group explicitly accepts broader disclosure. See [Brain](../brain/) for the full knowledge and disclosure model.

## Set the durable documents

Open **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY** on the Agent page:

| Document | What to write |
|---|---|
| `MISSION.md` | Why the Agent exists, what work it owns, and what a complete result means |
| `SOUL.md` | How it communicates, how it makes decisions, and how it handles uncertainty |
| `DESIGN.md` | The design system for web pages, slides, documents, charts, and other visual artifacts |
| `ConfidentialityPolicy.md` | How the Agent chooses an audience scope when it writes knowledge to Brain |

`DESIGN.md` follows the <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md format</a>: YAML frontmatter defines design tokens such as colors, typography, spacing, border corners, and components, while the Markdown body explains the visual principles and how to apply them. Ankole ships a ready-to-use default design system that you can replace with your organization's brand under **Console → Agents → DESIGN**.

Keep workflows, permission boundaries, and behavioral rules out of `DESIGN.md`—place them in `MISSION.md`, `SOUL.md`, `ConfidentialityPolicy.md`, or a dedicated Skill instead. Note that `ConfidentialityPolicy.md` guides explicit Brain writes initiated by the Agent, whereas automatic memory extraction from chat uses the conversation's participant audience. Start with concise documents, and add rules only when real work shows that they are needed.

Saved edits apply to subsequent turns; work that is already running continues with the document snapshot that it loaded when the turn started.

## Configure models

On the same page, configure at least the `primary`, `light`, and `heavy` model profiles, which handle everyday conversation, lightweight tasks, and complex reasoning, respectively. For your initial setup, all three profiles can point to the same verified model.

Configure optional profiles only when the Agent needs them:

- Configure `vision_fallback` when the Agent must read images.
- Configure `web_search` and `web_fetch` when the Agent must search or read public web pages.
- Configure `image_generate` when the Agent must create images.
- Configure **Background Agent Jobs** when Jobs need a separate provider or model. To run Jobs through a ChatGPT subscription, select its [ChatGPT subscription provider](../chatgpt-subscription-provider/) here.

Select the Provider first to unlock the model selector and the context-length field; leave the context length empty to use the Provider and model default.

Under **Advanced settings**, the Console displays only options declared by the selected Provider. **Reasoning summary** applies only to the Responses API, **Answer detail** sets the default response verbosity, and **Service tier** overrides the request priority tier for this profile. Supported values depend on the Provider, account, and model—leave these fields blank to use the Provider defaults.

See [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent) for the first LLM Provider and model setup.

## Set a token quota

Next to the model profiles, **Token quota** limits how many tokens this Agent may consume within a repeating period. Specify the period length in days, the period start time, and the token limit; an Agent without a quota configured runs with no limit.

Once set, the panel displays consumed tokens as a progress bar alongside their share of the limit and the start and end timestamps of the active period. Ankole counts the input and output tokens that the provider reports across every model call that the Agent makes—including scheduled turns, Workflows, Background Agent Jobs, and any context compaction that those calls start. Brain model calls, embeddings, web tools, image generation, and requests that a person makes with their own personal token do not count toward the Agent's quota.

Once an Agent reaches its limit, Ankole replies to new chat messages with the consumed tokens, the limit, and the timestamp when the period resets instead of invoking the model, while any Background Agent Job belonging to that Agent fails immediately rather than waiting for the next period. Because Ankole checks the quota before each model call, the call that crosses the threshold completes and may finish slightly above the limit. Ankole does not replay blocked messages automatically, so users resend their message after the period ends.

Select **Reset period** to start a fresh period immediately so the Agent can resume work ahead of schedule, or select **Remove limit** to lift the quota altogether. Both actions retain historical usage records for auditing. See [Cost management](../cost-management/) for additional spend controls.

## Configure capabilities and environment variables

Each Agent inherits your tenant's default Agent Plugins and Skills. To customize them, open **Console → Agent Library** and update the tenant defaults or configure an override for this Agent; see [Agent Library](../skills/) for the full procedure.

Whenever a Skill, CLI tool, or MCP service requires an API key, add it under **Environment variables** on the Agent page. Values set here are exposed exclusively to this Agent and override the tenant value (or the site value when the tenant has no override). See [Environment variables](../worker-env/).

## Connect a chat channel

In **Pod Chat**, workspace members can send direct messages (`dm`) to an active Agent or invite it into a group conversation (`group`) right away without a Signal Binding.

Signal Bindings govern external IM channels and mailboxes. To connect Slack, Microsoft Teams, Lark, Feishu, DingTalk, WeCom, Telegram, Discord, LINE, WhatsApp, or a dedicated mailbox, open **Console → Signal routing** and bind the external chat application to the target Agent. A single chat application can feed multiple routing rules, or you can register dedicated bot applications for different Agents. See [Signal routing rules](../signal-bindings/).

## Change or disable an Agent

You can update an Agent's display name, role, durable instructions, models, and capabilities at any time, whereas its UID is permanent because other configurations reference it.

Disabling an Agent stops it from accepting new work while keeping it in the Agent list in a disabled state. From there, you can re-enable it at any time or delete it permanently—permanent deletion requires disabling the Agent first and removes the Agent together with all of its sessions, jobs, and historical records. If you only want to pause messages from one external chat entry point, disable that channel's signal routing rule instead of disabling the entire Agent.

## If the Agent does not reply

Check these items in order:

1. The Agent is enabled.
2. The `primary`, `light`, and `heavy` profiles are configured, and the LLM Provider is available.
3. A signal routing rule points to this Agent.
4. **Console → Workers** shows the Agent's Worker as ready, or starting without a failure reason.
5. **Console → Conversations** recorded the message—inspect any error attached to the turn.

For channel-specific checks, see [Quick start troubleshooting](../quickstart/#if-the-agent-does-not-reply).
