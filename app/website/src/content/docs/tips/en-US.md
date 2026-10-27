---
title: Operator tips
description: Short, tested moves that save time when running Ankole — reading logs, scoping agents, rotating secrets, recovering from a stuck turn, and getting the model profile dials right.
section: Guides
order: 308
---

This page collects practical operator habits that come up across everyday Ankole deployments—each short, grounded in how the runtime works, and much faster to read here than to learn during an incident.

## Read logs in pretty mode locally

By default, the control plane emits structured JSON logs—ideal for log aggregators, hard to scan in a terminal. During local development, pipe JSON logs through the devkit pretty-printer:

```bash
bun run dev                                      # in one terminal
bun run kit logs pretty < /path/to/log-stream    # or pipe a log file through it
```

In production, ship raw JSON logs to your log collector and reserve `kit logs pretty` for local inspection.

## Scope the log level before a bug hunt

`ANKOLE_LOG_LEVEL` defaults to `info`. Drop it to `debug` only while reproducing a specific bug, then restore `info` as soon as you finish—leaving a production deployment at `debug` generates heavy I/O and log noise. Valid values are `debug | info | warning | error`; Ankole rejects invalid values at boot rather than ignoring them silently.

## Get the activation code without the terminal

If the first-visit setup page asks for the bootstrap activation code and you cannot see the `bun run dev` or control-plane container stdout:

```bash
bun run kit show bootstrap-activation-code          # local
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

Always read the code from these runtime sources rather than trying to inspect raw database tables.

## Treat model-profile slots as dials

Each Agent's eight built-in profile slots—`primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, and `image_generate`—work like independent dials:

- Point **`primary`** at a faster, cheaper model when an Agent mainly answers quick operational questions, or dial it up to a frontier reasoning model when accuracy outweighs latency and cost.
- Bind **`light`** to a genuinely fast, low-cost model, since Ankole uses it for high-volume background classification and routing work.
- Configure **`vision_fallback`** only if the Agent receives images and its `primary` model lacks native vision; otherwise leave it empty.
- Treat **`web_search`** and **`web_fetch`** independently—bind them only on Agents that need public web access.
- Configure Brain retrieval in **AppConfigure**: the site-wide `brain.embedding_model` powers vector search across all Agents, while each tenant's `brain.rerank_model` controls cross-encoder reranking. Leaving the embedding model empty disables vector search, and leaving the rerank model empty keeps reciprocal-rank fusion order; see [Brain](../brain/).

When an Agent feels sluggish in chat, its `primary` slot is often bound to a heavier model than the work that it actually performs requires.

## Rotate a credential in Environment variables

Updates to Worker environment variables apply starting on the **next turn** rather than mutating processes mid-turn:

1. Save the updated secret in **Environment variables** in the Console.
2. Allow any currently running turn or workspace command to finish with its captured environment.
3. Start a new turn to verify the rotated credential.

Never judge whether a credential rotation worked from a turn that was already running when you clicked save.

## Reveal encrypted values only when necessary

To rotate a secret, simply paste the replacement value and save—you do not need to view the old secret first. Click **Reveal** only when diagnosing a configuration mismatch requires inspecting the currently stored value.

## Recover from a stuck turn

A turn that appears stuck is almost always waiting on an upstream LLM provider or a long-running Worker command rather than deadlocked inside Ankole. Before cancelling anything:

1. Inspect `/api/v2/ai-gateway/conversations` for the turn's latest model requests—a long pause there points to upstream provider latency.
2. Check the Agent's Worker logs for an active shell or browser command, since a slow tool call looks identical to a quiet turn in chat.
3. Only if the work is genuinely wedged, steer the Session or let its inactivity timeout fire. To stop a Background Agent Job cleanly, call `POST /api/v2/background-agent-jobs/:id/cancel`, which lets any in-flight turn settle safely.

Cancelling turns impulsively is the fastest way to leave external side effects half-finished.

## Disable a binding quietly

Calling `DELETE /api/v2/agents/:agent_uid/signal-bindings/:binding_name` disables the routing rule instead of erasing it, keeping all credentials and routing settings recoverable. Use it whenever you want to silence an Agent in a channel temporarily—during credential rotation, a holiday freeze, or an incident—and re-enable it later with `PATCH`.

## Back up before you upgrade, every time

Rolling back a Helm release or container tag never reverses Ecto database migrations. Before every upgrade, run `pg_dump` across the control-plane PostgreSQL database and every configured `BASE_DB_URLS` shard database, and back up your bootstrap secrets (`ANKOLE_SECRET_BASE`, `RELEASE_COOKIE`, and `ANKOLE_FUNCTION_RUNTIME_TOKEN`). See [Backup and restore](../backup-and-restore/) for the exact commands.

## Adjust the correct durable document

Update `MISSION.md` when an Agent's scope or responsibilities change, `SOUL.md` when its tone or judgment misses the mark, and `DESIGN.md` when generated web pages, slides, documents, or charts need consistent visual styling. Because each file owns one concern, keep behavioral rules out of `DESIGN.md` and visual tokens out of `MISSION.md`.

## One robot per DingTalk agent

DingTalk enforces a strict one-to-one mapping: at most one enabled binding per Agent, and at most one Agent per `clientId`. When scaling out multiple Agents on DingTalk, register a separate DingTalk robot for each Agent—if you add a second enabled binding to the same Agent, Ankole rejects it with `dingtalk_binding_already_exists`, and if you reuse a `clientId` on another Agent, Ankole rejects it with `dingtalk_app_already_bound`. See [Quickstart](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) for setup steps.

## Teams needs a public endpoint, always

Unlike Lark, Slack, and DingTalk—which connect outbound over persistent WebSockets and tolerate brief ingress blips—Microsoft Teams delivers messages exclusively via inbound Bot Framework HTTPS webhooks. Whenever a Teams bot goes silent, check your public HTTPS endpoint first: an expired TLS certificate, a DNS change, or a reverse-proxy outage will all look like a dead bot.

## Next steps

- For the Console interface reference, read [Console API reference](../console-api/).
- For environment knobs, read [Environment variables](../environment-variables/).
- For the kit commands, read the [kit CLI reference](../kit-cli/).
