---
title: Operator tips
description: Short, tested moves that save time when running Ankole — reading logs, scoping agents, rotating secrets, recovering from a stuck turn, and getting the model profile dials right.
section: Guides
order: 308
---

This is a grab-bag of operator moves that did not fit cleanly into one guide but come up often. Each tip is short, grounded in how Ankole actually works, and costs you less than the first time you discover it the hard way.

## Read logs in pretty mode locally

The control plane emits structured JSON logs by default — right for ingestion, hard to read. In local development, pipe them through the devkit pretty-printer:

```bash
bun run dev   # in one terminal
bun run kit logs pretty < /path/to/log-stream   # or pipe a log file through it
```

In production, leave `ANKOLE_LOG_FORMAT=json` and let your log ingester handle formatting. The pretty printer is a local convenience, not a production setting.

## Scope the log level before a bug hunt

`ANKOLE_LOG_LEVEL` defaults to `info`. Drop it to `debug` for a specific reproduction and put it back when you are done — a deployment left at `debug` is noisy and slow. The valid values are `debug | info | warning | error`; an invalid value is rejected at boot, not silently ignored.

## Get the activation code without the terminal

If the `bun dev` (or control-plane container) terminal is not visible and the setup page wants the code:

```bash
bun run kit show bootstrap-activation-code          # local
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

Do not guess the code from the database — read it from the source the setup flow actually uses.

## Treat model-profile slots as dials

The eight built-in Agent profile slots — `primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, and `image_generate` — are dials:

- Turn **`primary`** down to a cheaper model when the agent mostly answers quick questions; turn it up when quality matters more than cost.
- Bind **`light`** to something genuinely cheap and fast — it exists for the high-volume, low-stakes path.
- Set **`vision_fallback`** only if the agent sees images; otherwise leave it unbound and save the slot.
- **`web_search`** and **`web_fetch`** are independent — bind them only when the agent needs to reach the web.
- Configure Brain retrieval once in **AppConfigure**, not in an Agent profile. `brain.embedding_model` applies to vector retrieval for every Agent, and `brain.rerank_model` applies to reranking. An empty embedding model disables vector retrieval; an empty rerank model keeps the fusion order. See [Brain](../brain/).

An agent that "feels slow" is often a `primary` bound too heavy for the work it actually does.

## Rotate a credential in Environment variables

Worker environment changes take effect on the **next turn**, not the one currently running. So:

1. Enter the new value in **Environment variables** in the Console and save it.
2. Let any in-flight turn finish — it already has its environment.
3. Send a new message to verify the new value is in effect.

Do not judge a secret change from a turn that was running when you saved it; it will not see the new value.

## Reveal encrypted values only when necessary

Enter a replacement value to rotate a credential. Do not reveal the old value only to check it. Select **Reveal** only when you must inspect the current value to diagnose a problem.

## Recover from a stuck turn

A turn that seems stuck is usually waiting on the model or a provider, not on Ankole. Before cancelling anything:

1. Check `/ai-gateway/conversations` for the turn's recent model calls — if there is a long gap, the provider is the holdup.
2. Check the worker logs for an in-flight tool call — a slow tool looks like a stuck turn.
3. Only if the turn is genuinely wedged, the agent's session can be steered or the turn allowed to time out; cancellation of a background job is `POST /background-agent-jobs/:id/cancel`, which lets an in-flight turn finish.

Cancelling aggressively is how operators create half-done side effects.

## Disable a binding quietly

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` is a *disable*, not a hard delete — the configuration stays recoverable. Use it when you want an agent silent in a channel without losing the setup (revoked credentials, a holiday, an incident). Re-enable with `PATCH`.

## Back up before you upgrade, every time

A Helm rollback does not reverse a database migration. The two-minute `pg_dump` before an upgrade is the difference between "rolled back" and "restored from backup, lost a day." See [Backup and restore](../backup-and-restore/) for the commands.

## Adjust the correct durable document

Edit `MISSION.md` when the Agent's responsibilities are unclear. Edit `SOUL.md` when its communication or judgment is wrong. Edit `DESIGN.md` when web pages, slides, documents, or charts lack a consistent visual style. Each file owns one concern, so do not put behavior rules in the visual design system.

## One robot per DingTalk agent

DingTalk enforces a hard constraint: one enabled binding per agent and one agent per `clientId`. If you scale out, plan one robot for each agent. A second binding on the same agent fails with `dingtalk_binding_already_exists`. Reuse of a `clientId` on another agent fails with `dingtalk_app_already_bound`. See [Quickstart](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) for the setup.

## Teams needs a public endpoint, always

Teams delivers as Bot Framework webhook calls, not over a long connection. If a Teams bot stops working, the first thing to check is the public HTTPS endpoint — certificate expiry, DNS change, and ingress downtime all look like "the bot stopped replying." Lark, Slack, and DingTalk use long connections and will survive a brief endpoint blip; Teams will not.

## Next steps

- For the Console interface reference, read [Console API reference](../console-api/).
- For environment knobs, read [Environment variables](../environment-variables/).
- For the kit commands, read the [kit CLI reference](../kit-cli/).
