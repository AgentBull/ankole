---
title: Agents
description: Create an Agent in the Console, then configure its role, durable behavior, models, capabilities, and environment variables.
section: User guide
order: 13
---

An Agent is a digital colleague that works over time. Each Agent has its own identity, work instructions, models, capabilities, and file space. A signal routing rule connects the Agent to messages from a chat channel.

## Create an Agent

1. Open **Console → Agents** and select **New Agent**.
2. Enter the required display name. The Console generates a UID from English or Chinese text, such as `research-analyst` for `Research Analyst` and `yan-jiu-fen-xi-shi` for `研究分析师`. Mixed-language names also work.
3. Review or change the UID, then enter a role and an optional avatar URL. The UID is a stable identifier that is unique in this deployment instance, and you cannot change it after you save the Agent. You can change the display name later without breaking existing configuration.
4. Save the Agent. The page then shows its durable instructions, model profiles, and Agent-specific environment variables.

An Agent from an earlier Ankole version can still load and run without a display name. You must add a display name before you next save its basic information.

The role gives a short summary of the work, such as “Research Analyst” or “Customer Support.” The three durable documents below manage responsibilities, behavior, and visual design.

## Set the durable documents

Open **MISSION / SOUL / DESIGN** on the Agent page:

| Document | What to write |
|---|---|
| `MISSION.md` | Why the Agent exists, what work it owns, and what a complete result means |
| `SOUL.md` | How it communicates, how it makes decisions, and how it handles uncertainty |
| `DESIGN.md` | The design system for web pages, slides, documents, charts, and other visual artifacts |

`DESIGN.md` uses the <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md format</a>. YAML frontmatter stores design tokens such as colors, type, spacing, corners, and components. The Markdown body explains the visual principles and how to apply them. Ankole includes a usable default design system. You can replace it with your company brand in **Console → Agents → DESIGN**.

Do not put workflows, permission boundaries, or behavior rules in `DESIGN.md`. Put them in `MISSION.md`, `SOUL.md`, or a specific Skill. Start with a small set of clear documents, then add rules only when real work shows that they are necessary.

Saved changes apply to later conversations. Work that is already running continues with the version it read when it started.

## Configure models

On the same page, configure at least the `primary`, `light`, and `heavy` model profiles. They serve normal conversation, light work, and complex reasoning.

For the first setup, all three can use the same model that you have already verified.

Configure optional profiles only when the Agent needs them:

- Configure `vision_fallback` when the Agent must read images.
- Configure `web_search` and `web_fetch` when the Agent must search or read public web pages.
- Configure `image_generate` when the Agent must create images.
- Configure **Background Agent Jobs** when Jobs need a separate provider or model. A ChatGPT subscription uses the same provider selection through its [ChatGPT subscription provider](../chatgpt-subscription-provider/).

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

A disabled Agent does not accept new work. If you only want to stop one chat entry point, disable or delete the related signal routing rule instead of disabling the full Agent.

## If the Agent does not reply

Check these items in order:

1. The Agent is enabled.
2. The `primary`, `light`, and `heavy` profiles are configured, and the LLM Provider is available.
3. A signal routing rule points to this Agent.
4. At least one worker is ready.
5. **Console → Conversations** contains the message and shows a useful error.

For channel-specific checks, see [Quick start troubleshooting](../quickstart/#if-the-agent-does-not-reply).
