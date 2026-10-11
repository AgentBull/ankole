---
title: Environment variables
description: Use the Console to configure the environment variables that command-line tools, MCP servers, and Background Agent Jobs need.
section: User guide
order: 10
---

Agents require environment variables when running commands, calling MCP servers, or executing Background Agent Jobs on an Agent Computer Worker. Use **Environment variables** in the Console to manage API keys, tokens, service URLs, and related settings.

Do not put credentials in Skills, Agent documents, or chat messages.

The Agent and the programs that it starts can read these variables. Each command that the Agent runs starts with a fresh environment that contains these values; it does not inherit the environment of the Worker process. Store only credentials that the Agent must use. Configure credentials for LLM Providers, identity providers, and chat channels on their own Console pages.

## Select the scope first

| Who needs the variable | Where to set it | Scope |
|---|---|---|
| Agents across the site | **Console → Environment variables → New site variable** | Site default |
| Agents in one tenant | **Console → select a tenant → Environment variables → New tenant variable** | Overrides the site value in this tenant |
| One Agent | **Console → Agents → select an Agent → Environment variables** | Overrides tenant and site values for that Agent |

Values resolve from the Agent override, then the tenant value, then the site default. Clearing an override restores the next available value. Without any value, the variable is absent.

## Add a site or tenant variable

1. Open **Console → Environment variables**. Select the tenant, then choose **New site variable** or **New tenant variable** for the required scope.
2. Enter the name. It can contain letters, digits, and underscores, but it cannot start with a digit. For example, use `MY_API_KEY`.
3. Enter the value. Keep **Store as secret** on for API keys, tokens, passwords, and other sensitive values.
4. Add an optional note to identify the tool or service that uses the variable. The Agent does not receive this note.
5. Save the variable.

The runtime reserves `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, and names that start with `ANKOLE_`. You cannot set these names here.

## Set a variable for one Agent

1. Open **Console → Agents** and select the Agent.
2. Find **Environment variables**.
3. Add a variable, or select **Override** for an existing variable.
4. Enter the value and save it.

This section shows site, tenant, and Agent values. The **Source** column identifies the active value. **Clear** removes only the Agent override; the tenant or site value can then apply.

## Understand the variable types

Every WorkerEnv entry is a custom operator value. Ankole and Plugins do not export AppConfigure keys through WorkerEnv. Runtime-owned variables and binding credentials have their own owners.

## Encrypt, reveal, and rotate values

**Store as secret** is on by default for a new variable. The Console masks an encrypted value in lists, but the Agent receives the original value when it runs.

When you edit an encrypted variable, keep the mask unchanged to preserve the stored value. To rotate a credential, enter the new value and save it. You do not need to reveal the old value first.

Select **Reveal** only when you must check the current value. If you turn off **Store as secret**, the Console asks you to confirm plaintext storage. Do not turn off encryption for API keys, tokens, or passwords.

## When changes take effect

Changes apply to later Worker work. An execution or workspace that has already captured its environment keeps those values. Main model inference runs in the control plane and does not receive WorkerEnv as its process environment.

If the Agent does not receive the expected value, check these items in order:

1. The name matches the Skill, script, or `bearer_token_env_var` declaration exactly. Names are case-sensitive.
2. Check Agent and tenant overrides before the site default.
3. Confirm that a value exists at one of these scopes.
4. Start new Worker work after the change; an existing workspace keeps its captured environment.

For an MCP-backed Skill, put only the environment variable name in `bearer_token_env_var`. Store the token here. See [MCP](../mcp/) for the declaration contract.
