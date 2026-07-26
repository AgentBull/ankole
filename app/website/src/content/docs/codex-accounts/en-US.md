---
title: Codex accounts
description: Add a ChatGPT subscription account and let selected Agents use it for Background Agent Jobs.
section: User guide
order: 41
---

Background Agent Jobs use AI Gateway by default. Add a Codex account only when you want Jobs to use a ChatGPT subscription.

One Codex account can serve several Agents. The control plane stores its authentication data in encrypted form. Do not put this data in Agent environment variables or chat messages.

## Before you add an account

First, sign in to Codex on your computer. After the sign-in succeeds, find the `auth.json` file that Codex created:

- The default location is `~/.codex/auth.json`.
- If you set `CODEX_HOME`, the file is in that directory.

The file contains account credentials. Paste it only into the Ankole Console. Do not send it to a chat channel, ticket, or source repository.

## Add the account in the Console

1. Open **Console → LLM Providers**.
2. Find **Codex Accounts** near the end of the page and select **New Codex account**.
3. Enter a clear name, such as “Research team ChatGPT.”
4. Open `auth.json`, copy all of its content, and paste it into the field.
5. Save the account. The Console derives the ChatGPT account ID from the file.

## Assign the account to an Agent

1. Open **Console → Agents** and select the Agent.
2. Find **Background Agent Jobs** under **Model profiles**.
3. Change the runtime to a ChatGPT subscription account.
4. Select the Codex account. Set the model, reasoning effort, and Fast Mode as necessary.
5. Save the profile. New Background Agent Jobs use this configuration.

This setting does not change normal chat turns. It applies only to Background Agent Jobs.

## Update or delete an account

When the Codex sign-in data changes, get a current complete `auth.json`, edit the account, and paste the new content. If you leave the field empty when you save, Ankole keeps the existing authentication data.

Before you delete an account, change every Agent that uses it to AI Gateway or another Codex account. The Console does not delete an account that is still in use.

See [Background Agent Jobs](../background-jobs/) for Job creation, control, and troubleshooting.
