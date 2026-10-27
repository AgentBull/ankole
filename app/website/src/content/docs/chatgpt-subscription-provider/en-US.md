---
title: ChatGPT subscription provider
description: Connect ChatGPT subscriptions to AIGateway with device login and a shared credential pool.
section: User guide
order: 41
---

A ChatGPT subscription integrates into AIGateway as a standard provider, so any model profile—including interactive conversations and Background Agent Jobs—can point to it by selecting the provider row and an entitled model.

Each provider row manages an encrypted credential pool inside the control plane, automatically refreshing OAuth tokens and selecting a healthy account for each request. An Agent Computer Worker receives only its AIGateway endpoint and AIGateway key—never a ChatGPT refresh token.

## Create the provider

1. Open **Console → LLM Providers**.
2. Add a provider and select **ChatGPT Subscription** as the provider kind.
3. Enter a stable provider ID, such as `chatgpt-main`.
4. Save the provider.

By default, the endpoint and identity headers match the Codex protocol; adjust advanced endpoint or header fields only if your network environment requires it.

## Add accounts with device login

1. Open the ChatGPT subscription provider.
2. Select **Add ChatGPT account**.
3. Open the verification link and enter the one-time code displayed in the Console.
4. Wait for the Console to complete sign-in and add the account to the pool.
5. Repeat these steps to pool additional ChatGPT accounts under the same provider.

Whenever available, the Console uses OpenAI's device-code login flow; if that flow is unavailable, the Console displays a browser sign-in URL and prompts you to paste back the full callback URL. Enterprise operators can alternatively supply a trusted access token along with its ChatGPT account ID.

## Configure the credential pool

For each pool member, the Console displays its label, priority, login source, health status, request count, rate-limit state, and model or image usage, while keeping raw secret tokens hidden.

Choose a pool selection strategy (localized in the Console UI, stored and returned via API under its canonical key):

| Console label | API value | Behavior |
| --- | --- | --- |
| Fill first | `fill_first` | Use the first healthy member until it becomes unavailable. |
| Round robin | `round_robin` | Rotate after each selection. |
| Least used | `least_used` | Select the member with the smallest request count. |
| Random | `random` | Select any healthy member. |

When an account hits rate limits and enters `exhausted`, AIGateway automatically returns it to rotation once its cooldown elapses. If an account enters `dead`, re-authenticate it or replace its credential (renaming the label alone does not clear `dead`), or disable or delete the member from the pool.

## Assign the provider to an Agent

1. Open **Console → Agents** and select the Agent.
2. Open the target model profile—use **Background Agent Jobs** for durable Jobs, or another profile for foreground turns.
3. Select the ChatGPT subscription provider and an entitled model.
4. Configure reasoning effort and Fast Mode as needed.
5. Save the profile.

All requests flow through AIGateway, which pins a stateful thread to the same account when possible, rotates to another healthy pool member on retryable upstream errors, and never crosses over to a different provider. If every member in the pool is cooling down, interactive calls return a rate-limit error with the earliest recovery timestamp, while Background Agent Jobs return to `queued` until the earliest pool member recovers.

See [Background Agent Jobs](../background-jobs/) for Job creation, control, and troubleshooting.
