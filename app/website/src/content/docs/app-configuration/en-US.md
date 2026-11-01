---
title: AppConfigure
description: Manage Ankole AppConfigure runtime settings in the Console and reference the built-in keys.
section: User guide
order: 43
---

In **Console → AppConfigure**, site administrators manage site defaults, workspace policies, and shared runtime parameters. Pod administrators use their existing Pod Settings permissions.

## Find and scope a setting

Choose **Site configuration and defaults** or **Current workspace overrides** before editing. The page always names the data workspace. A site default affects workspaces without an override; it does not impose a maximum on workspace values.

**By task** is the default view. Related settings open one form with an operational summary. **Read-only registry** lists every registered key and pattern, its scope, value source, encryption, and management owner. Search reaches fields inside grouped forms and former key names, and opens the matching field. Named management links open the relevant Console page and tab.

Site keys use the stored site value and then the code default. Tenant keys resolve an explicitly consumed Agent override, the workspace override, the site default, then the code default. Pod keys use only the workspace value and the code default. Five supported Agent override keys have read-only Agent inspection; this does not create an Agent configuration editor.

## Change and reset a setting

Edit one scope at a time, review the field's units, and save. Grouped tasks commit together: a rejected field leaves the whole task unchanged and preserves the draft. Secrets stay masked unless explicitly revealed. Reset confirmation shows the current value, the actual fallback value, and its source. Reset removes an override even when it equals the fallback; manually saving the same number keeps an independent override.

Time fields offer readable units while preserving storage units. Output limits distinguish no explicit limit (`null`) from a numeric cap, and inactivity timeout controls explicitly support disabled (`0`). Reducing deletion retention shows the consequences before saving.

Trace and Control Plane Plugin changes retain a restart-required status until the serving process matches the saved settings. Brain's background Tick checks the shared BM25 indexes every minute and rebuilds them when the tokenizer changes; maintenance may interrupt retrieval or block writes. Check the Brain health page and server Tick logs if repair fails.

The SMTP form can test the current draft without changing saved mail settings or creating an OTP. Omitting the password keeps the saved password. Test acceptance means transport acceptance; changing the draft invalidates its displayed test result. In SaaS, the Turnstile switch disables challenges while retaining both saved keys.

## AppConfigure and environment variables

AppConfigure stores declared product settings in PostgreSQL. Most changes affect subsequent work. [Deployment environment variables](../environment-variables/) provide bootstrap infrastructure, while custom tool credentials belong in [Agent environment variables](../worker-env/).

## Current built-in AppConfigure keys

Ankole ships with the built-in AppConfigure keys listed below, and Control Plane Plugins can register additional keys. Treat the **AppConfigure** page in your running instance as the authoritative catalog.

### Agent runtime

| Key | Scope | Purpose |
|---|---|---|
| `ai_agent.max_iterations` | Tenant | Maximum model iterations for one Agent turn |
| `ai_agent.max_output_tokens` | Tenant | Output-token cap for one model response |
| `ai_agent.inactivity_timeout_ms` | Tenant | Time to wait for an inactive model or Provider before ending the turn |
| `ai_agent.library.agent_plugin_defaults` | Tenant | Default enablement for Agent Plugins |
| `ai_agent.library.skill_defaults` | Tenant | Default enablement for Skills |
| `background_agent_jobs.max_running_per_agent` | Tenant | Maximum concurrently running BackgroundAgentJobs per Agent; default `3`, valid range `1`–`64` |
| `automation_jobs.max_running_per_agent` | Tenant | Maximum concurrently running automation scripts per Agent; default `10`, valid range `1`–`64` |

### Pod, Base, and Applet

| Key | Scope | Purpose |
|---|---|---|
| `pod.allow_external_guests` | Tenant | Allow invited external guests to access shared Pod pages; default `true` |
| `pod.applet.limits` | Tenant | Applet invocation limits (`timeout_ms: 60000`, `heap_mb: 128`) |
| `pod.base.limits` | Tenant | Base query and record limits (`query_rows: 1000`, `record_bytes: 1000000`, `group_count: 1000`, `statement_timeout_ms: 5000`) |
| `drive.trash_retention_days` | Tenant  Days Ankole retains deleted Drive nodes before automatic purge; default `30`, `0` keeps them indefinitely |
| `pod.ot_replay_window` | Tenant | Number of recent document change batches retained for OT replay; default `1000` |

### Workflows

| Key | Scope | Purpose |
|---|---|---|
| `workflow.max_concurrency_per_run` | Tenant | Maximum task concurrency that one Workflow can request; default `8`, valid range `1`–`32` |
| `workflow.max_running_per_agent` | Tenant | Maximum running Workflow tasks across one Agent's runs; default `8`, valid range `1`–`64` |
| `workflow.max_agent_calls_per_run` | Tenant | Maximum subagent calls that one Workflow can create; default `32`, valid range `1`–`1,024` |

Updates to these keys apply to newly started Workflow work. An individual run may request a lower concurrency or subagent-call cap, but it cannot exceed the tenant limit. Read [Workflows](../workflows/) for task execution rules and other size bounds.

### Brain

| Key | Scope | Purpose |
|---|---|---|
| `brain.enabled` | Tenant | Enable Brain retrieval, learning, and maintenance; stored knowledge remains when disabled |
| `brain.maintainer_agent_uid` | Tenant | Active Agent responsible for Brain maintenance; all Brain model calls run as this Agent and attribute usage to it; disabling it stops those calls and URL Source fetching until it is enabled or replaced; edit its `light`, `heavy`, and `web_fetch` profiles on the Agent page |
| `brain.embedding_model` | Site | Provider, model, and dimensions for vector retrieval; an empty value disables vector retrieval |
| `brain.rerank_model` | Tenant | Provider and model for reranking search results; an empty value keeps the fusion order |
| `brain.search_tokenizer` | Site | BM25 tokenizer: `icu`, `jieba`, `lindera_japanese`, or `lindera_korean`; a change requires a BM25 index rebuild |
| `brain.chunking` | Tenant | Source chunk size, overlap, and input limits |
| `brain.forgetting` | Tenant | Decay half-lives for each memory kind |
| `brain.soft_delete_retention_hours` | Tenant | Hours before Dreaming permanently purges soft-deleted Objects; default `72` |
| `brain.dreaming_task_cron` | Tenant | Schedule for regular knowledge consolidation |
| `brain.self_healing_task_cron` | Tenant | Schedule for rebuilding stale chunk, embedding, and search-index projections |
| `brain.signal_channel_batch_idle_time` | Tenant | Idle seconds before pending chat messages enter learning; conversation end also triggers learning |
| `brain.skill_learning_enabled` | Tenant | Enable Skill lesson learning and delivery; when disabled, stored lessons remain but are not supplied |
| `brain.skill_learning_reflection_threshold` | Tenant | Unconsumed Signal Jobs that one Agent must accumulate before Skill lesson reflection starts; minimum `2` |

Read [Brain](../brain/) for knowledge behavior and model requirements, and [Skill lessons](../skill-lessons/) for how Brain attaches learned guardrails to Skills.

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
| `authn.email.send_limits` | Site | Shared send window and maxima per email, source, and channel |
| `authn.email.failure_limits` | Site | Shared failure window and maxima per email and source |
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
| `i18n.default_locale` | Pod | Default language for the interface, notifications, and Agent messages in this Pod; Pod administrators can also update it in Pod Settings |

### Workers, web reading, and security

| Key | Scope | Purpose |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Site, read-only | Installation key that the control plane generates at first start; it names Lark profiles, and it is not a Worker credential |
| `agent_workers.ready_timeout_seconds` | Site | Seconds that a Worker may stay not ready before it is rebuilt with a new cache disk; default `600` (10 minutes) |
| `agent_workers.rendered_fetch_idle_ttl_ms` | Tenant | Idle lifetime for the built-in `web_fetch` rendered fallback |
| `security.ssrf_filter` | Site | Whether model-controlled fetches reject private, loopback, link-local, and CGNAT addresses |

Ankole rejects requests to cloud metadata addresses even when `security.ssrf_filter` is disabled.

`agent_workers.ready_timeout_seconds` governs how long the control plane waits on an observed unready Worker before rebuilding it, whereas idle Worker release is configured per pool via `idleReleaseAfter` in the provider YAML; see [Workers](../worker-management/).

### First-run state

| Key | Scope | Purpose |
|---|---|---|
| `setup.bootstrap_activation_code` | Site, read-only | Temporary activation code for the first-run setup page |
| `setup.completed` | Site, read-only | Whether this instance has completed first-run setup |

The first-run `/setup` flow manages both keys automatically. To read the activation code from the terminal, run `kit show bootstrap-activation-code`; never edit these keys on the AppConfigure page.

## Encrypted settings

Ankole encrypts secret settings at rest and displays a mask in both the list and editor. Saving the masked placeholder preserves the current value, whereas entering new text replaces it. Use **Reveal** only when you actively need to inspect the stored value, and never copy revealed credentials into chat threads, screenshots, or support tickets.
