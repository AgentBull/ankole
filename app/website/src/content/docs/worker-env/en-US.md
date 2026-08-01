---
title: Environment variables
description: Use the Console to configure the environment variables that command-line tools, MCP servers, and Background Agent Jobs need.
section: User guide
order: 10
---

An Agent can need environment variables when it runs commands, calls MCP servers, or starts Background Agent Jobs on an Agent Computer Worker. Use **Environment variables** in the Console for API keys, tokens, service URLs, and similar values.

Do not put credentials in Skills, Agent documents, or chat messages.

The Agent and the programs that it starts can read these variables. Store only credentials that the Agent must use. Configure credentials for LLM Providers, identity providers, and chat channels on their own Console pages.

## Select the scope first

| Who needs the variable | Where to set it | Scope |
|---|---|---|
| All Agents | **Console → Environment variables** | Available to every Agent by default |
| One Agent | **Console → Agents → select an Agent → Environment variables** | Available only to that Agent; a value with the same name overrides the global value |

When you clear an Agent value, the global value with the same name becomes active again. If no global value exists, the Agent no longer receives the variable.

## Add a variable for all Agents

1. Open **Console → Environment variables** and select **New variable**.
2. Enter the name. It can contain letters, digits, and underscores, but it cannot start with a digit. For example, use `MY_API_KEY`.
3. Enter the value. Keep **Store as secret** on for API keys, tokens, passwords, and other sensitive values.
4. Add an optional note to identify the tool or service that uses the variable. The Agent does not receive this note.
5. Save the variable. It becomes available from the Agent's next turn.

The runtime reserves `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `RUNTIME_FABRIC_URL`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, and names that start with `ANKOLE_`. You cannot set these names here.

## Set a variable for one Agent

1. Open **Console → Agents** and select the Agent.
2. Find **Environment variables**.
3. Add a variable, or select **Override** for an existing variable.
4. Enter the value and save it.

This section shows default values, global values, and values for this Agent. The **Source** column shows which value is active. Select **Clear** to remove the Agent value and restore the global or default value.

## Understand the variable types

| Type | Meaning | Available actions |
|---|---|---|
| Custom | An administrator added the variable in the Console | Edit or delete |
| Declared | Ankole or an enabled plugin provides the variable | Edit the value or reset it to the default |

A declared variable has a fixed name and data format. A variable with no value and no default appears as **Unset**.

## Encrypt, reveal, and rotate values

**Store as secret** is on by default for a new variable. The Console masks an encrypted value in lists, but the Agent receives the original value when it runs.

When you edit an encrypted variable, keep the mask unchanged to preserve the stored value. To rotate a credential, enter the new value and save it. You do not need to reveal the old value first.

Select **Reveal** only when you must check the current value. If you turn off **Store as secret**, the Console asks you to confirm plaintext storage. Do not turn off encryption for API keys, tokens, or passwords.

## When changes take effect

A change does not alter an execution that has already started. The new value is available to the Agent's next turn, later Background Agent Job executions, and later Automation Job attempts.

If the Agent does not receive the expected value, check these items in order:

1. The name exactly matches the name in the Skill, script, or `bearer_token_env_var` declaration. Names are case-sensitive.
2. Whether the Agent has a value with the same name. An Agent value overrides a global value.
3. The variable does not show **Unset**.
4. A new Agent turn started after the change.

For an MCP-backed Skill, put only the environment variable name in `bearer_token_env_var`. Store the token here. See [MCP](../mcp/) for the declaration contract.
