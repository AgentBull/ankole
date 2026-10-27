---
title: Environment variables
description: Use the Console to configure the environment variables that command-line tools, MCP servers, and Background Agent Jobs need.
section: User guide
order: 10
---

Agents rely on environment variables when running CLI tools, calling MCP servers, or executing Background Agent Jobs on an Agent Computer Worker. Manage these API keys, bearer tokens, service URLs, and tool settings under **Environment variables** in the Console—never hardcode credentials inside Skills, Agent Markdown files, or chat messages.

Every command spawned by the Agent starts with a clean environment populated from these configured variables rather than inheriting the Worker daemon's own process environment, and both the Agent and any child processes that it launches can read them. Store only credentials that Agent tools genuinely need; configure LLM Provider keys, Identity Provider secrets, and chat-channel tokens on their dedicated Console pages instead.

## Select the scope first

| Who needs the variable | Where to set it | Scope |
|---|---|---|
| Agents across the entire site | **Console → Environment variables → New site variable** | Site default |
| Agents in a single tenant | **Console → select a tenant → Environment variables → New tenant variable** | Overrides the site default within that tenant |
| A single Agent | **Console → Agents → select an Agent → Environment variables** | Overrides both tenant and site values for that Agent |

When assembling an execution's environment, Ankole resolves each variable from the Agent override first, then the tenant value, and finally the site default. Clearing an override falls back to the next broader scope, and if none of the three scopes defines a value, Ankole omits the variable altogether.

## Add a site or tenant variable

1. Open **Console → Environment variables**, select the target tenant if applicable, and click **New site variable** or **New tenant variable**.
2. Enter a case-sensitive variable name using letters, digits, and underscores (not starting with a digit)—for example, `MY_API_KEY`.
3. Enter the value, leaving **Store as secret** enabled for API keys, tokens, passwords, and other credentials.
4. Optionally add an operator note describing which tool or service consumes the variable (Ankole never exposes this note to the Agent).
5. Save the variable.

Ankole reserves `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, and all names prefixed with `ANKOLE_`, and rejects attempts to set them here.

## Set a variable for one Agent

1. Open **Console → Agents** and select the target Agent.
2. Scroll to **Environment variables**.
3. Add a new variable, or click **Override** next to an inherited site or tenant variable.
4. Enter the Agent-specific value and save.

This table displays inherited site, tenant, and Agent-specific variables side by side, with the **Source** column indicating which scope wins. Clicking **Clear** deletes only the per-Agent override so the tenant or site value takes effect again.

## Understand the variable types

WorkerEnv holds exclusively operator-defined tool variables: neither Ankole core nor Control Plane Plugins inject `AppConfigure` keys into WorkerEnv, and runtime-internal variables and channel credentials remain isolated in their owning subsystems.

## Encrypt, reveal, and rotate values

**Store as secret** defaults to on for every new variable. In the Console, Ankole masks encrypted values in tables and forms while injecting the decrypted plaintext into the Agent's Worker commands at runtime.

When editing an encrypted variable's note, leave the masked value untouched to keep the existing secret. To rotate a secret, paste the new value directly and save—there is no need to click **Reveal** first. Use **Reveal** only when troubleshooting requires inspecting the stored value, and never turn off **Store as secret** (which prompts for explicit plaintext confirmation) on API keys, tokens, or passwords.

## When changes take effect

Saved variable changes apply to subsequent Worker executions; any turn or open workspace that has already captured its environment keeps the values it started with. Main-Agent language-model calls run in the control plane and never receive WorkerEnv in their OS environment.

If an Agent tool cannot find an expected variable, check these four points in order:

1. Verify that the variable name matches the Skill, script, or `bearer_token_env_var` field character for character (names are case-sensitive).
2. Inspect per-Agent and tenant overrides ahead of the site default.
3. Confirm that at least one of those scopes defines a non-empty value.
4. Start a fresh turn or Job so the Worker captures the updated environment rather than reusing an already-open workspace.

For MCP-backed Skills, declare only the variable name under `bearer_token_env_var` in `openai.yaml` and store the secret token here; see [MCP](../mcp/) for the schema.
