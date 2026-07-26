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

The ten profile slots are not just "primary model and friends." Each one is a dial:

- Turn **`primary`** down to a cheaper model when the agent mostly answers quick questions; turn it up when quality matters more than cost.
- Bind **`light`** to something genuinely cheap and fast — it exists for the high-volume, low-stakes path.
- Set **`vision_fallback`** only if the agent sees images; otherwise leave it unbound and save the slot.
- **`web_search`** and **`web_fetch`** are independent — bind them only when the agent needs to reach the web.

An agent that "feels slow" is often a `primary` bound too heavy for the work it actually does.

## Rotate a WorkerEnv secret without breaking a turn

Worker environment changes take effect on the **next turn**, not the one currently running. So:

1. Put the new value with `PUT /worker-envs/:name` (or the per-agent form).
2. Let any in-flight turn finish — it already has its environment.
3. Send a new message to verify the new value is in effect.

Do not judge a secret change from a turn that was running when you saved it; it will not see the new value.

## Decrypt is a separate permission — use it sparingly

`POST /worker-envs/:name/decryptions` is a distinct, separately-authorized action, not a side effect of reading. Prefer to rotate a secret (set a new value) over decrypting the old one; each decryption is observable, and the value travels to the caller. Use decrypt only when you genuinely need to see the stored value — for debugging, or to confirm what is there before a scripted rotation.

## Recover from a stuck turn

A turn that seems stuck is usually waiting on the model or a provider, not on Ankole. Before cancelling anything:

1. Check `/ai-gateway/conversations` for the turn's recent model calls — if there is a long gap, the provider is the holdup.
2. Check the worker logs for an in-flight tool call — a slow tool looks like a stuck turn.
3. Only if the turn is genuinely wedged, the agent's session can be steered or the turn allowed to time out; cancellation of a background job is `POST /background-agent-jobs/:id/cancel`, which lets an in-flight turn finish.

Cancelling aggressively is how operators create half-done side effects.

## Disable a binding quietly

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` is a *disable*, not a hard delete — the configuration stays recoverable. Use it when you want an agent silent in a channel without losing the setup (revoked credentials, a holiday, an incident). Re-enable with `PATCH`.

## Back up before you upgrade, every time

A Helm rollback does not reverse a database migration. The two-minute `pg_dump` before an upgrade is the difference between "rolled back" and "restored from backup, lost a day." See [Updating](../updating/) for the exact commands.

## Keep the persona as the tuning surface

When the agent's behavior is wrong — too chatty, too quiet, off-topic — the persona (`MISSION.md`, `SOUL.md`, `DESIGN.md`) is almost always the right lever, not a configuration change. Edit the document, watch a day, edit again. Configuration changes the agent's *capabilities*; the persona changes its *judgment*, and judgment is usually what was wrong.

## One robot per DingTalk agent

DingTalk enforces a hard constraint: one enabled binding per agent, one `clientId` per agent. If you are scaling out, plan one robot per agent from the start — a second binding on the same agent fails with `dingtalk_binding_already_exists`, and reusing a `clientId` on a second agent fails with `dingtalk_app_already_bound`. See the [DingTalk first bot](../dingtalk-first-bot/) guide.

## Teams needs a public endpoint, always

Teams delivers as Bot Framework webhook calls, not over a long connection. If a Teams bot stops working, the first thing to check is the public HTTPS endpoint — certificate expiry, DNS change, and ingress downtime all look like "the bot stopped replying." Lark, Slack, and DingTalk use long connections and will survive a brief endpoint blip; Teams will not.

## Next steps

- For the full operator surface, read [Console operations](../console-operations/) and the [Console API reference](../console-api/).
- For environment knobs, read [Environment variables](../environment-variables/).
- For the kit commands, read the [kit CLI reference](../kit-cli/).
