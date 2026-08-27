---
title: Agents
description: Create an Agent in the Console, then configure its owner, durable behavior, models, capabilities, and environment variables.
section: User guide
order: 13
---

An Agent is a digital colleague that works over time. Each Agent has its own identity, owner, work instructions, models, capabilities, and file space. A signal routing rule connects the Agent to messages from a chat channel.

## Create an Agent

1. Open **Console → Agents** and select **New Agent**.
2. Enter the required display name. The Console generates a UID from English or Chinese text, such as `research-analyst` for `Research Analyst` and `yan-jiu-fen-xi-shi` for `研究分析师`. Mixed-language names also work.
3. Review or change the UID, then enter a role and an optional avatar URL. The UID is a stable identifier that is unique in this deployment instance, and you cannot change it after you save the Agent. You can change the display name later without breaking existing configuration.
4. Select the human Principal who owns the Agent, then select its group-memory disclosure mode.
5. Save the Agent. The page then shows its durable instructions, model profiles, and Agent-specific environment variables.

The role gives a short summary of the work, such as “Research Analyst” or “Customer Support.” The four durable documents below manage responsibilities, behavior, visual design, and confidentiality.

## Set ownership and group disclosure

Every Agent has an owner. The owner can inspect knowledge that the Agent authored or holds and knowledge addressed to that Agent. Ownership does not grant access to a Group's knowledge unless the owner is also a member of that Group.

The group-memory disclosure mode controls what the Agent can say when several people can see its reply:

- **Strict** requires every participant in the group conversation to satisfy a memory item's audience scope.
- **Relaxed** checks the person who asked the question. Other participants do not narrow the result.

Both modes behave the same way in a direct message. Use **Strict** unless the group accepts the wider disclosure rule. See [Brain](../brain/) for the full knowledge and disclosure model.

## Set the durable documents

Open **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY** on the Agent page:

| Document | What to write |
|---|---|
| `MISSION.md` | Why the Agent exists, what work it owns, and what a complete result means |
| `SOUL.md` | How it communicates, how it makes decisions, and how it handles uncertainty |
| `DESIGN.md` | The design system for web pages, slides, documents, charts, and other visual artifacts |
| `ConfidentialityPolicy.md` | How the Agent chooses an audience scope when it writes knowledge to Brain |

`DESIGN.md` uses the <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md format</a>. YAML frontmatter stores design tokens such as colors, type, spacing, corners, and components. The Markdown body explains the visual principles and how to apply them. Ankole includes a usable default design system. You can replace it with your company brand in **Console → Agents → DESIGN**.

Do not put workflows, permission boundaries, or behavior rules in `DESIGN.md`. Put them in `MISSION.md`, `SOUL.md`, `ConfidentialityPolicy.md`, or a specific Skill. `ConfidentialityPolicy.md` guides the Agent's own Brain writes; automatic learning from chat uses the conversation's audience. Start with a small set of clear documents, then add rules only when real work shows that they are necessary.

Saved changes apply to later conversations. Work that is already running continues with the version it read when it started.

## Configure models

On the same page, configure at least the `primary`, `light`, and `heavy` model profiles. They serve normal conversation, light work, and complex reasoning.

For the first setup, all three can use the same model that you have already verified.

Configure optional profiles only when the Agent needs them:

- Configure `vision_fallback` when the Agent must read images.
- Configure `web_search` and `web_fetch` when the Agent must search or read public web pages.
- Configure `image_generate` when the Agent must create images.
- Configure **Background Agent Jobs** when Jobs need a separate provider or model. A ChatGPT subscription uses the same provider selection through its [ChatGPT subscription provider](../chatgpt-subscription-provider/).

Select the Provider before you select or enter the model. The context-length field also becomes available after you select the Provider. Leave the context length empty to use the Provider and model default.

Advanced settings show only options that the selected Provider declares. **Reasoning summary** applies only to the Responses API. **Answer detail** sets the default response detail. **Service tier** overrides the request tier for this model profile. Available values depend on the Provider, account, and model. Leave these options empty to use the Provider defaults.

See [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent) for the first LLM Provider and model setup.

## Configure capabilities and environment variables

The Agent inherits the deployment instance defaults for Agent Plugins and Skills. To change them, open **Console → Agent Library** and edit the defaults or set an override for this Agent.

See [Agent Library](../skills/) for the full procedure.

If a Skill, command-line tool, or MCP service needs an API key, add it to **Environment variables** on the Agent page. An Agent-specific value is available only to this Agent.

It overrides a global value with the same name. See [Environment variables](../worker-env/).

## Connect a chat channel

The new Agent needs a signal routing rule before it can receive messages from Slack, Microsoft Teams, Lark, Feishu, or DingTalk.

Open **Console → Signal routing** and select the chat application and target Agent. One chat application can have multiple rules, and you can create separate bot applications for different Agents.

See [Signal routing rules](../signal-bindings/).

## Change or disable an Agent

You can change the display name, role, durable instructions, models, and capabilities at any time. You cannot change the UID because other configuration uses it to identify the Agent.

A disabled Agent does not accept new work. If you only want to stop one chat entry point, disable the related signal routing rule instead of disabling the full Agent.

## If the Agent does not reply

Check these items in order:

1. The Agent is enabled.
2. The `primary`, `light`, and `heavy` profiles are configured, and the LLM Provider is available.
3. A signal routing rule points to this Agent.
4. At least one worker is ready.
5. **Console → Conversations** contains the message and shows a useful error.

For channel-specific checks, see [Quick start troubleshooting](../quickstart/#if-the-agent-does-not-reply).
