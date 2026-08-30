---
title: Security hardening
description: The end-to-end shape of hardening an Ankole deployment instance — least authority, secret discipline, SSRF, credential rotation, and minimum ingress.
section: Guides
order: 316
---

Ankole ships with its security boundaries in place — Principal/AuthZ, encrypted secrets, sandboxed workers, authenticated ingress. Hardening is not adding walls; it is tightening the ones that are there to the smallest surface your actual usage needs. This page walks the five surfaces an operator hardens, in the order that closes the most risk first.

The decisive property, stated up front: Ankole's model is *least authority by default, expanded only where evidence demands*. Every move below narrows a permission, a secret's reach, or a network path. If you find yourself widening one, ask why — a widening is the move that deserves the scrutiny, not the narrowing.

## Surface 1: Principal and AuthZ authority

The agent runs under its Principal, and what that Principal can do is fenced by AuthZ. The hardening move is *least authority per agent*, not one powerful agent.

- **One Principal per agent, one purpose per agent.** A customer-success agent and a coding agent should be different Principals, so a compromise of one is not a compromise of both.
- **Grant the minimum that does the job.** A grant to read a channel is narrower than a grant to write to every channel; a grant scoped to a specific resource pattern is narrower than a wildcard. See [Principal and AuthZ](../principal-authz/).
- **Sync directory groups, then grant to groups.** Synced AuthZ groups let you scope authority by team membership, and revoke it by removing the group membership in the source directory — not by editing grants one by one when someone leaves.
- **Disable, do not delete, when in doubt.** A disabled Principal loses authority across the instance immediately; you can re-enable it. A deleted Principal's uid is gone.

The audit surface is `/permission-grants` and `/principals/:uid/grants`. Read them periodically; a grant that made sense at creation can drift into too much.

## Surface 2: Credentials that Agents use

Store credentials for Agent tools in **Environment variables** in the Console, with secret storage on. Limit who can use each value and rotate it regularly.

- **Reveal values sparingly.** Enter a replacement value to rotate a credential. Do not reveal the old value only to check it. See [Environment variables](../worker-env/).
- **Scope secrets per agent when you can.** A global secret reaches every agent; a per-agent secret reaches one. Prefer the per-agent form unless the secret is genuinely shared.
- **Do not override reserved names.** You cannot set `PATH`, `HOME`, `WORKER_ID`, `DATABASE_URL`, names that start with `ANKOLE_`, or some sandbox names in the Console. Do not bypass this restriction.
- **Rotate the bootstrap secrets on a cadence.** `ANKOLE_SECRET_BASE` and `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` derive other keys; rotating them is a deployment-restart operation, and the blast radius of a compromised `ANKOLE_SECRET_BASE` is the whole instance.

## Surface 3: SSRF and model-controlled fetches

An agent with `web_fetch` can ask Ankole to fetch URLs. `security.ssrf_filter` is the AppConfigure key that decides what gets rejected.

- **The default is `false` — and read why before you flip it.** Ankole is commonly an enterprise-internal agent, and intranet access is expected; the filter is off so internal fetches work.
- **Cloud metadata endpoints are always blocked**, regardless of the setting. A model that tries to read `169.254.169.254` is rejected whether the filter is on or off.
- **When the filter is on**, private, loopback, link-local, and CGNAT targets are rejected. Turn it on when your agent fetches from the public internet and has no legitimate reason to reach internal IPs — that is the case the filter exists for.

The decision applies to the complete deployment instance, and the wrong choice is not "off" or "on" — it is the one that does not match what your agent actually needs to reach.

## Surface 4: Adapter credential rotation

Each chat adapter and identity provider holds credentials (`appID`/`appSecret`, `botToken`/`appToken`, `clientId`/`clientSecret`, Entra ID `appPassword`, the Google Workspace `serviceAccountKey`). Rotate them on a cadence, and on any suspicion of leak.

- **Rotate at the provider first, then in Ankole.** Invalidate the old credential in the provider's console, then put the new value in the adapter's AppConfigure. The order matters: a credential rotated in Ankole but still valid at the provider is a window.
- **Use the correct Console page.** Put credentials for Agent tools in **Environment variables**. Rotate chat-channel and identity-provider credentials on their own Console pages.
- **Directory sync credentials are credentials too.** The Google Workspace `serviceAccountKey` and `adminEmail`, the Entra ID app used for Graph — these can read your directory. Treat their rotation with the same seriousness as the chat credentials.

## Surface 5: Minimum network ingress

Ankole needs some ingress; it rarely needs all of it. Tighten to what each transport actually requires.

- **Long-connection adapters need only outbound.** Lark, Slack, and DingTalk open outbound WebSocket/Stream connections; they do not need a public ingress endpoint. Keep the deployment private if you only use these.
- **Teams and webhook ingress need a public endpoint — scope it.** Bot Framework and the `/webhooks/v1/...` front door need to be reachable. Use your ingress to restrict that path to the expected providers (by source IP where you can), and rely on the adapter's own authentication (Bot Framework JWT, Graph `clientState`, ZAP/PLAIN worker auth) for the rest.
- **Webhook delegation URLs are credentials.** `/webhooks/v1/event-callbacks/*` must be reachable when an Agent delegates detection to an external system. Redact the complete path in ingress, proxy, CDN, and application logs. The URL authorizes only a wake-up, so the Agent must verify current external state before a consequential action.
- **The Console itself** should be behind your admin network or VPN, not open to the public internet. The bearer gate stops unauthorized access, but there is no reason to expose the admin surface to the world.

## The audit posture

Hardening is not a one-time pass; it is a posture. Two habits keep it:

- **Read the grants periodically.** `/permission-grants` and `/principals/:uid/grants` show what every Principal can do. Drift happens.
- **Test the restore.** The [backup-and-restore](../backup-and-restore/) discipline is a security control — a backup you cannot restore is no recovery from a compromise.

## What this guide is not

It is not a penetration test, and not a compliance checklist — it is the operator moves that tighten Ankole's existing boundaries. It is not "lock everything down"; least authority means the *minimum* surface your usage needs, not zero surface, and an agent that cannot do its job is its own failure. And it is not a substitute for the per-surface pages; each surface above links to the reference that explains its exact fields.

## Next steps

- For the permission model, read [Principal and AuthZ](../principal-authz/).
- For credentials that Agents use, read [Environment variables](../worker-env/).
- For the SSRF key and the bootstrap secrets, read [Environment variables](../environment-variables/).
