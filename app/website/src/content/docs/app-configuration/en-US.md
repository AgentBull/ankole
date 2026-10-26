---
title: AppConfigure
description: Manage Ankole AppConfigure runtime settings in the Console and reference the built-in keys.
section: User guide
order: 43
---

**Console → AppConfigure** contains settings that an administrator can change while the deployment instance is in service. Examples include conversation-history compaction, Agent limits, directory synchronization intervals, and plugin switches.

LLM Providers, Identity Providers, chat channels, and environment variables have their own Console pages. Do not configure them again here.

## AppConfigure and environment variables

AppConfigure settings are stored in PostgreSQL. They control Ankole product behavior while the instance runs. Most changes apply to later work and do not require a new deployment.

[Deployment environment variables](../environment-variables/) start the control plane and PostgreSQL and configure the Worker backend. Restart the affected process after you change one.

Use [Agent environment variables](../worker-env/) when a Skill, command-line tool, or MCP service needs a custom value such as an API key.

## Find a setting

The page groups related settings. You can search by key or description, or open a group to see its settings together.

Each row has one of these states:

- **Editable:** open the row and change it here.
- **Read-only:** the row shows current state but cannot be changed here.
- **Managed elsewhere:** follow the management link to the Console page that owns the setting.

The key is the stable name of the setting. Its description explains what it controls and which unit a number uses.

## Understand scope and source

Settings have **Site** or **Tenant** scope. Site keys control shared infrastructure. Tenant keys control the selected tenant's behavior. The Console shows site defaults and tenant overrides separately; Agent overrides are not supported.

A site key resolves its stored value, then the version default. A tenant key resolves the tenant override, then a site default for that key, then the version default. **Reset to default** removes the override at the selected scope. The source column shows which value applies.

## Change a setting

1. Open the setting or setting group.
2. Read the field descriptions and confirm the scope and units.
3. Change the necessary values and save.
4. Return to the list and confirm that the row shows an override.

Common settings use a dedicated form. Some advanced settings use a JSON editor. Keep the existing field structure and do not remove fields that you do not understand.

Most changes apply to later work. If the page says that a change applies at the next start, restart the control plane at a suitable time.

## Reset a setting

When you do not need a custom value, open the setting and select **Reset to default**. This removes the override at the selected scope and makes Ankole use the default declared by the installed version.

Resetting is different from entering the current default as a custom value. A reset follows a changed default in a later version. A stored custom value does not.

## Current built-in AppConfigure keys

The following AppConfigure keys are built into Ankole. A Control Plane Plugin can register more keys. The **AppConfigure** page in the current instance is the authoritative list.

### Agent runtime

| Key | Scope | Purpose |
|---|---|---|
| `ai_agent.max_iterations` | Tenant | Maximum model iterations for one Agent turn |
| `ai_agent.max_output_tokens` | Tenant | Output-token cap for one model response |
| `ai_agent.inactivity_timeout_ms` | Tenant | Time to wait for an inactive model or Provider before ending the turn |
| `ai_agent.library.agent_plugin_defaults` | Tenant | Default enablement for Agent Plugins |
| `ai_agent.library.skill_defaults` | Tenant | Default enablement for Skills |
| `agent_computer.background_agent_job.max_running_per_agent` | Tenant | Maximum concurrently running BackgroundAgentJobs per Agent; default `3`, valid range `1`–`64` |
| `automation_jobs.max_running_per_agent` | Tenant | Maximum concurrently running automation scripts per Agent; default `10`, valid range `1`–`64` |

### Pod, Base, and Applet

| Key | Scope | Purpose |
|---|---|---|
| `pod.allow_external_guests` | Tenant | Allow invited external guests to access shared Pod pages; default `true` |
| `pod.applet.limits` | Tenant | Applet invocation limits (`timeout_ms: 60000`, `heap_mb: 128`) |
| `pod.applet.ai_agent_uid` | Tenant | Active Agent whose model profiles and usage own Applet `ctx.ai` calls; empty disables Applet AI |
| `pod.base.limits` | Tenant | Base query and record limits (`query_rows: 1000`, `record_bytes: 1000000`, `group_count: 1000`, `statement_timeout_ms: 5000`) |
| `pod.trash_retention_days` | Tenant | Positive integer days to retain deleted pages before automatic purge (default `30`), or `"unlimited"` to retain deleted pages without automatic purge |
| `pod.ot_replay_window` | Tenant | Number of recent document change batches retained for OT replay; default `1000` |

### Workflows

| Key | Scope | Purpose |
|---|---|---|
| `workflow.max_concurrency_per_run` | Tenant | Maximum task concurrency that one Workflow can request; default `8`, valid range `1`–`32` |
| `workflow.max_running_per_agent` | Tenant | Maximum running Workflow tasks across one Agent's runs; default `8`, valid range `1`–`64` |
| `workflow.max_agent_calls_per_run` | Tenant | Maximum subagent calls that one Workflow can create; default `32`, valid range `1`–`1,024` |

These limits apply to later Workflow work. A run can request a lower concurrency or call limit, but it cannot raise the tenant limit. Read [Workflows](../workflows/) for task behavior and other size boundaries.

### Brain

| Key | Scope | Purpose |
|---|---|---|
| `brain.enabled` | Tenant | Enable Brain retrieval, learning, and maintenance; stored knowledge remains when disabled |
| `brain.maintainer_agent_uid` | Tenant | Active Agent responsible for Brain maintenance; all Brain model calls run as this Agent and attribute usage to it; disabling it stops those calls and URL Source fetching until it is enabled or replaced; edit its `light`, `heavy`, and `web_fetch` profiles on the Agent page |
| `brain.embedding_model` | Site | Provider, model, and dimensions for vector retrieval; an empty value disables vector retrieval |
| `brain.rerank_model` | Tenant | Provider and model for reranking search results; an empty value keeps the fusion order |
| `brain.search_tokenizer` | Site | BM25 tokenizer: `icu`, `jieba`, `lindera_japanese`, or `lindera_korean`; a change requires a BM25 index rebuild |
| `brain.chunking` | Tenant | Source chunk size, overlap, and input limits |
| `brain.forgetting` | Tenant | Knowledge-decay half-lives and the soft-delete purge interval |
| `brain.dreaming_task_cron` | Tenant | Schedule for regular knowledge consolidation |
| `brain.self_healing_task_cron` | Tenant | Schedule for rebuilding stale chunk, embedding, and search-index projections |
| `brain.signal_channel_batch_idle_time` | Tenant | Idle seconds before pending chat messages enter learning; conversation end also triggers learning |
| `brain.skill_learning_enabled` | Tenant | Enable Skill lesson learning and delivery; when disabled, stored lessons remain but are not supplied |
| `brain.skill_learning_reflection_threshold` | Tenant | Unconsumed Signal Jobs one Agent must accumulate before Skill lesson reflection starts; minimum `2` |

Read [Brain](../brain/) for its knowledge behavior and model requirements. Read [Skill lessons](../skill-lessons/) for the lessons that Brain supplies with Skills.

### AI Gateway and observability

| Key | Scope | Purpose |
|---|---|---|
| `ai_gateway.compaction` | Site | Automatic conversation-history compaction policy |
| `observability.traces.enabled` | Site | Whether process-wide OpenTelemetry export starts on the next control-plane boot |
| `observability.traces.provider` | Site | Semantic projection for `langfuse`, `langsmith`, or generic `opentelemetry` traces |
| `observability.traces.otlp_endpoint` | Site | Base OTLP/HTTP endpoint for optional traces |
| `observability.traces.otlp_headers` | Site | Encrypted authentication headers for optional traces |

See [LLM observability](../llm-observability/) for Langfuse, LangSmith, VictoriaTraces, and other OTLP/HTTP receivers.

### Passwordless Email OTP and Pod login policy

| Key | Scope | Purpose |
|---|---|---|
| `authn.email.mail` | Site, encrypted | SMTP mail transport (`server`, `from`, `port`, `ssl`, and optional credentials) for passwordless Email OTP sign-in; empty disables Email OTP |
| `authn.email.code_ttl_seconds` | Site | Verification-code lifetime in seconds; default `600` |
| `authn.email.send_window_seconds` | Site | Rate-limit window in seconds for sending Email OTP codes; default `60` |
| `authn.email.send_email_limit` | Site | Maximum codes sent to one email address per send window; default `3` |
| `authn.email.send_source_limit` | Site | Maximum codes sent from one source address per send window; default `20` |
| `authn.email.send_channel_limit` | Site | Maximum codes sent across the channel per send window; default `100` |
| `authn.email.failure_window_seconds` | Site | Rate-limit window in seconds for failed code verifications; default `600` |
| `authn.email.failure_email_limit` | Site | Maximum failed verifications for one email address per failure window; default `10` |
| `authn.email.failure_source_limit` | Site | Maximum failed verifications from one source address per failure window; default `100` |
| `principals.pod_login_policy` | Tenant, managed elsewhere | Pod member login and invitation policy (`allow_email_otp`, `allow_member_credential_change`, `allowed_email_domains`, `require_sso_for_members`, `allow_invite_links`); managed in Pod Settings |

### Identity, Plugins, feature flags, and tenant defaults

| Key | Scope | Purpose |
|---|---|---|
| `principals.identity_providers.active` | Tenant, read-only | Active tenant Identity Providers that authenticate Pod workspace members and administrators; managed in Pod Settings and on the Identity Provider page |
| `principals.identity_providers.directory_full_sync_interval_minutes` | Tenant | Full organization-directory synchronization interval |
| `tenants.privileged_tenant_id` | Site, read-only | ID of the tenant whose `siteadmin` group administers this site |
| `plugins.enabled_ids` | Site, managed elsewhere | Optional (`:optional`) Control Plane Plugins to enable at the next start; `:always` plugins stay active with the build |
| `features.<flag>` | Site | Feature availability policy (`{enabled, percent, targets}`) backing OpenFeature (`Ankole.Features.Config`) |
| `signals.show_dead_letter_error_details` | Site | Whether dead-letter notices sent to Conversations include bounded, redacted Session turn error details; default `false` |
| `system.timezone` | Tenant | Default time zone for schedules and other control-plane features |
| `i18n.default_locale` | Tenant | Default language for the Ankole interface |

### Workers, web reading, and security

| Key | Scope | Purpose |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Site, read-only | Installation key that the control plane generates at first start; it names Lark profiles, and it is not a Worker credential |
| `agent_computer.worker.ready_timeout` | Site | Seconds that a Worker may stay not ready before it is rebuilt with a new cache disk; default `600` (10 minutes) |
| `worker.rendered_fetch_idle_ttl_ms` | Tenant | Idle lifetime for the built-in `web_fetch` rendered fallback |
| `security.ssrf_filter` | Site | Whether model-controlled fetches reject private, loopback, link-local, and CGNAT addresses |

Cloud metadata addresses are rejected even when this setting is off.

`agent_computer.worker.ready_timeout` controls recovery of observed unready instances. Set idle release in provider YAML with `idleReleaseAfter`. See [Workers](../worker-management/).

### First-run state

| Key | Scope | Purpose |
|---|---|---|
| `setup.bootstrap_activation_code` | Site, read-only | Temporary activation code for the first-run setup page |
| `setup.completed` | Site, read-only | Whether this instance has completed first-run setup |

The first-run setup flow owns these keys. To read the activation code, run `kit show bootstrap-activation-code`. Do not edit these keys on the AppConfigure page.

## Encrypted settings

Ankole stores credential settings in encrypted form and shows a mask in the list and editor. Saving the mask keeps the current value. Entering new content replaces it.

Use **Reveal** only when you must check the current value. Do not copy a revealed credential into chat, screenshots, or tickets.
