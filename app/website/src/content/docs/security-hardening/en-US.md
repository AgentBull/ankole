---
title: Security hardening
description: The end-to-end shape of hardening an Ankole deployment instance — least authority, secret discipline, SSRF, credential rotation, and minimum ingress.
section: Guides
order: 316
---

Ankole ships with core security boundaries enabled out of the box—Principal and AuthZ enforcement, encrypted secret storage, dedicated Worker containers per Agent, and authenticated ingress. Hardening an instance means tightening those built-in boundaries to the smallest surface that your workloads actually need. This guide walks through the six surfaces that operators harden, ordered by risk reduction.

Ankole follows *least authority by default, expanded only with clear operational need*. Every recommendation below narrows a grant, restricts a secret's audience, or closes an unused network path—so whenever a configuration change widens access instead, pause and verify why that wider scope is necessary.

## Surface 1: Principal and AuthZ authority

Every Agent executes under its own Principal, bounded at runtime by AuthZ grants. Aim for *least authority per Agent* rather than running one all-purpose super-Agent:

- **One Principal and one role per Agent.** Keep a customer-support Agent and an engineering Agent on separate Principals so a misconfiguration or compromise in one never exposes the permissions of the other.
- **Grant the narrowest resource and action needed.** Prefer channel-specific or read-only grants over broad write wildcards; see [Principal and AuthZ](../principal-authz/).
- **Synchronize directory groups and attach grants to groups.** When grants live on synced directory groups, team transfers and departures in your Identity Provider update permissions automatically without manual grant cleanup.
- **Choose carefully between Suspend and Offboard.** Human Principals are never deleted. **Suspend** (`disposition: :suspended`) immediately revokes browser sessions, tokens, and future work while preserving personal `SiteCredential` bindings for later restoration. **Offboard** (`disposition: :offboarded`) revokes sessions, tokens, and future work, and also releases unshared `SiteCredential` bindings and Pod email bindings—always choose **Offboard** when someone leaves the organization.

Audit `/api/v2/permission-grants` and `/api/v2/principals/:uid/grants` periodically to catch permission drift early.

## Surface 2: Credentials that Agents use

Prefer **Pod → Connections** (`Ankole.Connectors`) first for GitHub, Lark/Feishu, Slack, and Linear integrations so upstream OAuth and App tokens remain encrypted inside the control plane—never entering Worker containers—while Ankole proxies MCP requests or injects short-lived turn-scoped helpers such as `GIT_ASKPASS`. Use **Environment variables** (`WorkerEnv`) in the Console (with **Store as secret** enabled) for custom CLI or script API keys that must execute inside the Worker, scope each secret narrowly, and rotate credentials on a regular schedule:

- **Avoid revealing stored secrets unnecessarily.** When rotating a secret, paste the replacement value directly and save—you do not need to reveal the existing value first. See [Environment variables](../worker-env/).
- **Prefer per-Agent overrides over site-wide secrets.** A site-level variable is exposed to every Agent in the deployment, whereas an Agent-level variable reaches only that one Agent.
- **Respect reserved environment names.** Ankole blocks overrides for `PATH`, `HOME`, `WORKER_ID`, `DATABASE_URL`, variables prefixed with `ANKOLE_`, and the other runtime-owned names listed in [Environment variables](../worker-env/). Never attempt to work around those guards.
- **Preserve the bootstrap encryption secret.** Back up `ANKOLE_SECRET_BASE` with the data encrypted under it. Replacing it and restarting does not re-encrypt stored secrets, so existing ciphertext requires the original value or a separate data migration. Rotate `ANKOLE_FUNCTION_RUNTIME_TOKEN` in the control plane and `ankole-function-runtime` together and restart both services. By contrast, you never manage Worker credentials by hand: the control plane generates a fresh random credential for each Worker generation, stores only its digest for authentication, and encrypts the launch token needed for idempotent retries.

For a remote Skill MCP server (`streamable_http`), store its bearer token under the declared `bearer_token_env_var` in **Environment variables**. The control plane reads that value for proxy requests and excludes it from Worker snapshots.

## Surface 3: SSRF and model-controlled fetches

When an Agent invokes `web_fetch`, Ankole checks `security.ssrf_filter` in AppConfigure to decide which destination addresses to block:

- **It defaults to `false` for intranet deployments.** Many teams run Ankole inside a corporate network so Agents can read internal wikis and dashboards; keeping `security.ssrf_filter` off allows those intranet fetches.
- **Cloud metadata addresses are blocked unconditionally.** Ankole rejects requests targeting `169.254.169.254` regardless of whether `security.ssrf_filter` is `true` or `false`.
- **Enabling the filter blocks private address ranges.** Setting `security.ssrf_filter` to `true` rejects private, loopback, link-local, and CGNAT IP targets—turn it on whenever Agents fetch exclusively from the public internet and have no business reaching internal networks, which is the exact scenario that the filter exists for.

Because `security.ssrf_filter` applies across the entire deployment instance, align it with whether your Agents legitimately read internal network hosts.

## Surface 4: Adapter credential rotation

Every chat adapter and Identity Provider stores external platform credentials (`appID`/`appSecret`, `botToken`/`appToken`, `clientId`/`clientSecret`, Entra ID `appPassword`, or Google Workspace `serviceAccountKey`). Rotate them on a fixed schedule and immediately upon any suspected exposure:

- **Issue the new credential and revoke the old one at the provider, and update Ankole promptly.** If you update Ankole while leaving the previous secret valid upstream, an attacker holding the old secret can still authenticate against the external platform until you revoke it there.
- **Keep chat-channel, Identity Provider, and connector credentials out of WorkerEnv.** Manage reusable service integrations in **Pod → Connections**, manage chat-channel and Identity Provider credentials on their dedicated Console pages, and follow the environment-variable setup above for remote Skill MCP bearer tokens.
- **Treat directory-sync credentials as high-privilege secrets.** Credentials such as a Google Workspace `serviceAccountKey` and `adminEmail` or an Entra ID Graph application can read your entire employee directory—rotate and audit them with the same rigor as production chat tokens.

## Surface 5: Minimum network ingress

Expose only the inbound HTTP paths that your configured transports actually require:

- **Outbound-only chat adapters need zero public ingress.** Lark, Slack, and DingTalk establish outbound WebSocket or Stream connections from the control plane, so if you use only those channels, keep the entire deployment on your private network.
- **Restrict public webhook paths when using Teams or external webhooks.** Microsoft Teams Bot Framework and `/webhooks/v1/...` require HTTPS reachability; narrow ingress rules at your load balancer or firewall (filtering source IP ranges where supported) while relying on Ankole's built-in adapter verification (Bot Framework JWTs, Graph `clientState`) at the application layer.
- **Treat webhook delegation URLs as bearer capabilities.** When Agents accept external callbacks under `/webhooks/v1/event-callbacks/*`, configure your ingress controller, reverse proxy, and CDN to redact that full URL path in access logs. Because a callback URL authorizes only a wake-up, Agents must still re-read authoritative upstream state before taking consequential action.
- **Keep the Console off the public internet.** Place the administrative Console behind your corporate VPN or private admin network; authentication stops unauthenticated requests, but an internal admin surface does not belong on the open internet.

## Surface 6: Worker containers, Function Runtime, and the control plane

Each Agent runs inside its own dedicated Worker container or Pod—Agents never share a Worker, cache volume, or Worker credential. Meanwhile, stateless TypeScript programs—Workflow orchestrators, programmatic tool calls (PTC), Pod Applet backends, published Applet Actions (including Automation Jobs), and host MCP calls—run in the separate `ankole-function-runtime` service with neither database credentials nor Kubernetes ServiceAccount tokens. Inside each Worker container or Pod, the `root` supervisor (`ankole-worker-supervisor` and its `ankole-rclone` FUSE helper) holds `/dev/fuse` and `SYS_ADMIN` strictly inside private mount and PID namespaces to mount `/drive`, then drops all Linux capabilities before launching Agent child processes: Worker shell commands, the Codex `app-server`, and Chromium all run as `uid 1000` (`gid 1000`) with empty capability sets and no `sudo`.

- **Commands run unprivileged inside the Worker.** Because child processes run as `uid 1000` with empty capabilities and no `sudo`, an Agent can install user-space tools in `/workspace` and read or write authorized `/drive` mounts, but cannot alter FUSE mounts or install OS packages, while concurrent Sessions of the same Agent share that Agent's filesystem and process tree.
- **Each Worker credential is bound to a single Agent generation.** The Worker supervisor holds its RuntimeFabric and Drive VFS credentials in memory and strips them from child process environments, and the control plane rejects credentials belonging to another Agent or a superseded Worker generation.
- **Guard the control plane as a root-equivalent component.** The control plane provisions Workers either over the host Docker socket (which is equivalent to host `root`) or through a Kubernetes namespace Role permitted to create and delete Pods, Secrets, and PVCs.
- **Use gVisor on Kubernetes where available.** Set `podTemplate.spec.runtimeClassName` in your Kubernetes `WorkerProvider` YAML to your cluster's gVisor RuntimeClass (such as `gvisor`); when you save updated instance settings, the control plane replaces idle Workers for that provider. In Helm deployments, `worker.runtimeClassName` seeds the initial provider on first boot, after which you manage the provider in the Console.
- **Restrict egress from Workers and `ankole-function-runtime`.** Under Docker Compose, Workers attach to `ankole_workers` and `ankole-function-runtime` attaches to `ankole_functions`—both can reach the control plane and the internet, while neither can reach PostgreSQL on the internal `ankole_backend` network. On cloud VMs, set the hop limit for instance metadata to `1` or block `169.254.169.254` from container subnets. Under Helm with `networkPolicy.enabled`, Worker Pods reject all inbound traffic and reach only the control plane, DNS, and public IPs outside `networkPolicy.workerDeniedCIDRs`, while a dedicated `NetworkPolicy` restricts `ankole-function-runtime` to control-plane ingress and public egress outside `functionRuntime.deniedCIDRs` (covering private and metadata CIDRs); set the node metadata hop limit to `1` as well.

## The audit posture

Security hardening only holds if you verify it over time:

- **Review grants on a recurring cadence.** Query `/api/v2/permission-grants` and `/api/v2/principals/:uid/grants` regularly so temporary exceptions do not become permanent permission drift.
- **Rehearse your backup restore.** Treat [backup and restore](../backup-and-restore/) drills as part of your security posture—a backup that you have never restored cannot be counted on during incident recovery.

## What this guide is not

This guide is neither a penetration-testing playbook nor a compliance matrix; instead, it focuses on the concrete configuration levers that tighten Ankole's built-in boundaries. Least authority means giving each Agent the *smallest* surface required to succeed—not locking everything down so tightly that Agents cannot complete real work. Follow the linked reference pages under each section for exact field names and schemas.

## Next steps

- For the permission model, read [Principal and AuthZ](../principal-authz/).
- For credentials that Agents use, read [Environment variables](../worker-env/).
- For the SSRF key and the bootstrap secrets, read [Environment variables](../environment-variables/).
- For the Worker that runs each Agent's commands, read [Agent Computer Worker](../agent-computer-worker/).
