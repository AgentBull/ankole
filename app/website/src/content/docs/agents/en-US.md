---
title: Agents
description: Create an Agent in the Console, then configure its owner, durable behavior, models, capabilities, and environment variables.
section: User guide
order: 13
---

An Agent is a durable working identity inside the Ankole Agent Harness, complete with its own mission, owner, permissions, tools, Model Profiles, and persistent file storage. Each Agent accesses Company Brain strictly within its authorized knowledge boundary and collaborates in **Pod** or across external channels through signal routing rules.

## Personal Assistants and AI Colleagues

Ankole models two Agent subtypes under `Ankole.Principals`:

- **Personal Assistant (`personal_assistant`)** — provisioned automatically 1:1 on first use for each active internal Human `member` (with initial UID `<owner_uid>_assistant`). A Personal Assistant acts with its Human owner's collaboration permissions across Unified Drive, Pod Docs and Bases, and groups such as `all_humans` (excluding `site_console:**` and `tenant_console:**` admin scopes), enforces `strict` group memory disclosure, and keeps an immutable owner. Only the owner can view or edit their Personal Assistant's contracts and Skill bindings; suspending, offboarding, or demoting the owner to `guest` disables the assistant automatically.
- **AI Colleague (`ai_colleague`)** — created by operators for shared specialist roles across a team. An AI Colleague operates strictly under its own Principal grants across Drive, Pod, Workflows, schedules, and Background Agent Jobs, posts interactive approval cards via `propose_action_card` when human sign-off is required, and delegates focused tasks to peer Agents in isolated `agent_peer` conversations via `send_to_agent`.

## Create an AI Colleague

1. Open **Console → Agents** (or Pod workspace settings) and select **New Agent**.
2. Enter the display name and choose a meaningful lowercase tenant-scoped `uid` (`^[a-z0-9][a-z0-9._@+-]{0,95}$`, such as `research-analyst`), which identifies the Agent as `(tenant_id, uid)` within the tenant.
3. Enter the role, optional avatar URL, and `WorkerProvider`.
4. Select the human Principal who owns the Agent, then select the disclosure mode for group memory.
5. Save the Agent to configure its contracts, Model Profile overrides, and Agent-specific environment variables.

The role provides a short summary of the Agent's work—such as “Research Analyst” or “Customer Support”—while two composable contracts in **Meta Ankole → Agents** (`AGENTS.md` and `DESIGN.md`) govern its behavior, responsibilities, and visual design system.

The `WorkerProvider` assigns the Agent to a [WorkerProvider](../worker-providers/) target. If an API request omits the provider, Ankole uses the site default—or rejects creation when no site default exists—and once saved, the `WorkerProvider` binding cannot be changed. Even when multiple Agents share a provider, each Agent gets a separate Worker instance, `/drive` FUSE workspace mounts, and its own persistent `/workspace` Home directory. Saving a new Agent does not start an instance right away; the control plane boots the Worker on demand when a turn requires computer work.

## Set ownership and group disclosure

Every Agent has a human owner who can inspect knowledge that the Agent authored or holds, as well as knowledge addressed directly to that Agent. Ownership alone does not grant access to a Group's knowledge unless the owner is also a member of that Group.

The disclosure mode for group memory controls what knowledge the Agent may draw on when multiple people can read its reply:

- **Strict** requires every participant in the group conversation to satisfy a memory item's audience scope.
- **Relaxed** checks only the person who asked the question, without narrowing results based on other participants in the conversation.

In one-on-one direct messages, both modes behave identically. Use **Strict** unless the group explicitly accepts broader disclosure. See [Brain](../brain/) for the full knowledge and disclosure model.

## Set Agent contracts

Open **Meta Ankole → Agents** to edit the global baseline or an Agent’s `AGENTS.md` and `DESIGN.md`. `AGENTS.md` defines behavior and responsibilities; `DESIGN.md` holds visual rules for web pages, slides, documents and charts.

Each Agent contract can inherit the global baseline, append to it or override it. DESIGN metadata holds design tokens and its body explains their use. Only the owner can view or edit a personal assistant’s configuration. See [Agent Library](../agent-library/).

Saved edits take effect on the next turn, including a resumed Codex Job. The current turn uses the complete contract it loaded at startup.

## Configure models

Agents resolve Model Profiles through 3-tier sparse inheritance (`Agent -> Pod -> Site`) configured in **Console → Model Profiles**, with cross-slot fallbacks `coding -> heavy -> primary` and `light -> primary`. Whenever your Site or Pod already defines a `primary` profile, a new Agent is ready to run immediately without per-Agent overrides; configure overrides on the Agent only when its role needs a distinct provider, model tier, or custom language-model alias:

- Override `primary`, `light`, or `heavy` when this Agent needs a larger or more specialized model than the Pod default.
- Configure `vision_fallback` when `primary` lacks native image input and the Agent must read images.
- Configure `web_search` and `web_fetch` when this Agent needs web access that differs from the Pod default.
- Configure `image_generate` when the Agent must create images through a dedicated image provider.
- Configure **Background Agent Jobs** (`coding`) when Jobs need a separate provider or model (unset `coding` falls back through `heavy -> primary`). To run Jobs through a ChatGPT subscription, select its [ChatGPT subscription provider](../chatgpt-subscription-provider/) here.

For separate `web_search` or `image_generate` profiles, also turn off the corresponding provider-hosted switch. Binding a profile alone does not change that switch. Both switches default to enabled and inherit Site → Pod → Agent settings.

Select the Provider first to unlock the model selector and the context-length field; leave the context length empty to use the Provider and model default. Deleting an Agent slot override restores inheritance from the Pod and Site defaults.

Under **Advanced settings**, the Console displays only options declared by the selected Provider. **Reasoning summary** applies only to the Responses API, **Answer detail** sets the default response verbosity, and **Service tier** overrides the request priority tier for this profile. Supported values depend on the Provider, account, and model—leave these fields blank to use the Provider defaults.

See [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent) for the first LLM Provider and model setup.

## Set a token quota

Next to the model profiles, **Token quota** limits how many tokens this Agent may consume within a repeating period. Specify the period length in days, the period start time, and the token limit; an Agent without a quota configured runs with no limit.

Once set, the panel displays consumed tokens as a progress bar alongside their share of the limit and the start and end timestamps of the active period. Ankole counts the input and output tokens that the provider reports across every model call that the Agent makes—including scheduled turns, Workflows, Background Agent Jobs, and any context compaction that those calls start. Brain model calls, embeddings, web tools, image generation, and requests that a person makes with their own personal token do not count toward the Agent's quota.

Once an Agent reaches its limit, Ankole replies to new chat messages with the consumed tokens, the limit, and the timestamp when the period resets instead of invoking the model, while any Background Agent Job belonging to that Agent fails immediately rather than waiting for the next period. Because Ankole checks the quota before each model call, the call that crosses the threshold completes and may finish slightly above the limit. Ankole does not replay blocked messages automatically, so users resend their message after the period ends.

Select **Reset period** to start a fresh period immediately so the Agent can resume work ahead of schedule, or select **Remove limit** to lift the quota altogether. Both actions retain historical usage records for auditing. See [Cost management](../cost-management/) for additional spend controls.

## Configure capabilities, connections, and environment variables

Each Agent inherits your tenant's default Agent Plugins and Skills. Open **Meta Ankole → Skills** in Pod (or **Console → Agent Library**) to update tenant defaults or configure per-Agent Skill overrides; see [Skills](../skills/) and [Agent Library](../agent-library/) for the full procedure.

For external SaaS platforms, OAuth accounts, and MCP services (such as Lark/Feishu, GitHub, Linear, or Skill-declared remote MCP servers), configure shared application credentials and personal OAuth connections in **Pod → Connections** (`/connectors`) through `Ankole.Connectors`, which keeps secrets inside the control plane; see [Using MCP](../using-mcp/). Reserve **Environment variables** on the Agent page for custom CLI tools and scripts running inside the Agent Computer—values set there are exposed exclusively to this Agent and override the tenant or site value (see [Environment variables](../worker-env/)).

## Connect a chat channel

In **Pod Chat**, workspace members can send direct messages (`dm`) to their Personal Assistant or an active AI Colleague, or invite AI Colleagues into a group conversation (`group`), without a Signal Binding. Agents can also message peer Agents directly in isolated `agent_peer` conversations via `send_to_agent`.

Signal Bindings govern external IM channels and mailboxes. To connect Slack, Microsoft Teams, Lark, Feishu, DingTalk, WeCom, Telegram, Discord, LINE, WhatsApp, or a dedicated mailbox, open **Console → Signal routing** and bind the external chat application to the target Agent (reusing shared `Ankole.Connectors` credentials where supported). A single chat application can feed multiple routing rules, or you can register dedicated bot applications for different Agents. See [Signal routing rules](../signal-bindings/).

## Change, rename, or disable an Agent

You can update an Agent's display name, role, `AGENTS.md` and `DESIGN.md` contracts, Model Profile overrides, and capabilities at any time. To rename an AI Colleague's tenant-scoped `uid`, first disable the Agent and remove any running or paused Worker instance, then run the audited rename action (`POST /api/v2/agents/:uid/rename` or via workspace admin), which updates grants, group memberships, Brain paths and mentions, and Base references atomically within the tenant.

Disabling an Agent stops it from accepting new work while keeping it in the Agent list in a disabled state. From there, you can re-enable it at any time or delete it permanently—permanent deletion requires disabling the Agent first and removes the Agent together with all of its sessions, jobs, and historical records. If you only want to pause messages from one external chat entry point, disable that channel's signal routing rule instead of disabling the entire Agent.

## If the Agent does not reply

Check these items in order:

1. The Agent is enabled.
2. An effective `primary` Model Profile resolves for the Agent (via Site/Pod defaults or Agent overrides), and its LLM Provider is healthy.
3. For external channels, a signal routing rule points to this Agent.
4. If the turn needs computer work, **Console → Workers** shows the Agent's Worker as ready, or starting without a failure reason. Pure questions do not require a running Worker.
5. **Console → Conversations** recorded the message—inspect any error attached to the turn.

For channel-specific checks, see [Quick start troubleshooting](../quickstart/#if-the-agent-does-not-reply).
