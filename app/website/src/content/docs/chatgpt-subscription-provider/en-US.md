---
title: ChatGPT subscription provider
description: Connect ChatGPT subscriptions to AIGateway with device login and a shared credential pool.
section: User guide
order: 41
---

A ChatGPT subscription is an ordinary AIGateway provider. Any model profile can point to it, including normal conversations and Background Agent Jobs. A profile selects the provider row and model. It does not select one account inside the row.

The provider row owns a credential pool. The control plane encrypts each account token, refreshes OAuth tokens, and selects a usable pool member for each request. An Agent Computer receives only its AIGateway endpoint and AIGateway key. It never receives a ChatGPT refresh token.

## Create the provider

1. Open **Console → LLM Providers**.
2. Add a provider and select **ChatGPT Subscription** as the provider kind.
3. Enter a stable provider ID, such as `chatgpt-main`.
4. Save the provider.

The default endpoint and identity headers match the Codex protocol. Change the advanced endpoint or headers only when your deployment has a specific requirement.

## Add accounts with device login

1. Open the ChatGPT subscription provider.
2. Select **Add ChatGPT account**.
3. Open the verification link and enter the one-time code that the Console shows.
4. Wait for the Console to finish the login and add the pool member.
5. Repeat the process to add more accounts to the same provider.

The Console uses the official device login when it is available. If that route is unavailable, the Console shows a browser sign-in URL and asks you to paste the complete callback URL. An Enterprise operator can instead add a trusted access token and its ChatGPT account ID.

## Configure the credential pool

Each member has a label, priority, source, health state, request count, rate-limit data, and model or image usage. Secret tokens are never shown.

Choose one selection strategy. The Console translates the display name, while the API and stored value stay stable:

| Console label | API value | Behavior |
| --- | --- | --- |
| Fill first | `fill_first` | Use the first healthy member until it becomes unavailable. |
| Round robin | `round_robin` | Rotate after each selection. |
| Least used | `least_used` | Select the member with the smallest request count. |
| Random | `random` | Select any healthy member. |

An `exhausted` member returns automatically after its cooldown. A `dead` member needs a new login or a replacement credential. You can also disable or delete a member. Changing only its label does not clear a `dead` state.

## Assign the provider to an Agent

1. Open **Console → Agents** and select the Agent.
2. Open the required model profile. Use **Background Agent Jobs** for durable Jobs, or another profile for normal model turns.
3. Select the ChatGPT subscription provider and an entitled model.
4. Set reasoning effort and Fast Mode as necessary.
5. Save the profile.

All calls continue through AIGateway. The gateway keeps a stateful thread on the same account when possible, rotates on a retryable provider failure, and does not fall back to a different provider. If all members are unavailable, an interactive call returns a rate-limit error with the next recovery time. A Background Agent Job returns to `queued` until the earliest pool member can recover.

See [Background Agent Jobs](../background-jobs/) for Job creation, control, and troubleshooting.
