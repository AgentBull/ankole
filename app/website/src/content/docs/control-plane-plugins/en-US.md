---
title: Control Plane Plugins
description: First-party Elixir extensions for the control plane, including activation modes, subsystem contracts, transaction hooks, Cohort supervision, and next-start configuration.
section: Developer guide
order: 110
---

Control Plane Plugins extend an Ankole site with trusted, first-party Elixir and OTP code compiled directly into the release (`:control_plane_plugin_modules`). Through `Ankole.Plugins`, a plugin can register `AppConfigure` keys, subsystem adapters, synchronous transaction hooks, and supervised processes.

Ankole discovers and validates these modules at startup rather than providing a marketplace, runtime code loading, or plugin sandboxes. Fixed build plugins (`activation: :always`) run automatically whenever compiled into the build, whereas optional plugins (`activation: :optional`) follow the site's global enable list and activate on the next process start.

## Discovered and active plugins

At runtime, every compiled plugin sits in one of two states:

- **Discovered**: Compiled into the release and validated at startup. Operators can inspect the full catalog of discovered plugins in the Site Admin Console.
- **Active**: Either configured with `activation/0` set to `:always`, or configured with `:optional` and listed in `plugins.enabled_ids` (while first-run setup is incomplete, Ankole also treats all discovered plugins as active). Only active plugins register `AppConfigure` definitions, publish subsystem adapters and domain hooks, and start supervised child processes.

When a discovered plugin is inactive, it remains visible in the catalog and PostgreSQL retains any saved `AppConfigure` values for it, but Ankole registers none of its runtime definitions, adapters, hooks, or processes.

## The plugin contract

Each plugin module implements the `Ankole.Plugins.Plugin` behaviour. Only one callback is required:

- **`plugin_id/0`**: A unique lowercase identifier matching `~r/\A[a-z][a-z0-9_-]*\z/`.

All remaining callbacks are optional:

- **`activation/0`**: Returns `:optional | :always` (default `:optional`). `:optional` plugins follow `plugins.enabled_ids`, whereas `:always` plugins stay active whenever compiled into the selected source build and Ankole rejects requests to disable them.
- **`display_name/0`**, **`description/0`**: Localized text maps for operator interfaces.
- **`app_config_definitions/0`**, **`app_config_patterns/0`**: `Ankole.AppConfigure` keys and pattern definitions owned by the plugin.
- **`adapter_declarations/0`**: Atom-keyed adapter declarations that connect the plugin to subsystem contracts, using `Ankole.Plugins.ConfigField` schemas to render browser forms.
- **`hooks/0`**: `[{hook_point, module}]` entries for synchronous, in-transaction domain hooks. Each hook module implements `Ankole.Plugins.Hook.before_commit_in_tx/2` on declared hook points (`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`) and can return `{:error, reason}` to roll back the calling transaction.
- **`children/0`**: `Supervisor.child_spec()` entries started under the plugin runtime supervisor.

At startup, `Ankole.Plugins.Spec.from_module/1` reads these callbacks and builds a validated `Spec`. If any module fails shape validation, duplicates an ID, or fails contract validation, Ankole halts startup with an error naming the responsible module.

## Subsystem contracts and site contribution points

`Ankole.Plugins.Contracts` defines five subsystem adapter contracts, each providing startup `validate` checks alongside optional `refresh` publication callbacks and `veto_disable` transaction guards:

- **`signals.adapter`**: Declares a messaging or event adapter validated by `Ankole.Signals.Adapters` for Signal Bindings and Conversations delivery.
- **`signals.webhook_handler`**: Declares an HTTP webhook handler validated by `Ankole.Signals.WebhookHandlers` for `/webhooks/v1/:handler_id/:instance_id/:kind`.
- **`principals.identity_provider`**: Declares an enterprise identity and directory adapter validated by `Ankole.IdentityProviders`.
- **`ai_gateway.provider`**: Declares a model provider adapter validated by `Ankole.AIGateway.Providers`, with a `refresh` callback that publishes active declarations to AI Gateway.
- **`agent_workers.provider_kind`**: Declares an Agent Worker infrastructure kind (`Ankole.AgentWorkers.ProviderKind`), publishing discovered and active specs via `refresh` and guarding disables via `veto_disable` (`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`) so operators cannot disable a plugin while any tenant still has an assigned Worker row for one of its kinds.

Beyond runtime adapters, first-party extensions can hook into compile-time, site-scoped contribution points across a site build:

- **`Ankole.Plugins.ConfigField`**: Publishes typed configuration fields from plugin adapters to Console and Pod forms.
- **Domain transaction hooks (`hooks/0`)**: Run synchronous `Ankole.Plugins.Hook.before_commit_in_tx/2` checks inside the owning domain's transaction and lock order.
- **Outer HTTP plugs**: Execute build-selected request plugs (such as admission challenges) in an outer router before forwarding requests to the core router via `AnkoleWeb.runtime_forward`.
- **Dual-scoped extension JSON:API routes**: Mount typed extension JSON:API routes under scoped `/api/v2/*` paths on both the site Host and Pod Hosts, authorized through `Ankole.AuthZ.Authorizer`.
- **Typed UI slots (`entries.json` `overrides`)**: Wrap public webapps (`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`) with lazy components gated by the active site-plugin snapshot in the HTML shell (`ankole-active-plugins`) and optional `when` feature conditions.

Dynamic policy decisions that need to change at runtime without a process restart belong in OpenFeature (`Ankole.Features`), not in plugin activation.

## Cohort supervision and the next-start boundary

Optional plugins apply site-wide and fail closed on completed installations. Operators enable or disable them through the global `plugins.enabled_ids` `AppConfigure` key in PostgreSQL.

When an operator updates `plugins.enabled_ids`, Ankole stages that selection for the **next Ankole process start** rather than hot-swapping running processes, adapters, or `AppConfigure` definitions. Inside the configuration write transaction, `Ankole.Plugins.Contracts.veto_disable/2` lets owning subsystems reject a disable request whenever durable state still depends on that plugin.

At runtime, `Ankole.Plugins.Cohort` supervises `Ankole.Plugins.Registry` ahead of `Ankole.Plugins.Supervisor` under a `:rest_for_one` strategy backed by a single immutable startup snapshot:

- `Ankole.Plugins.Registry` resolves the boot snapshot once, validates active declarations, registers plugin `AppConfigure` keys, refreshes subsystem views, and publishes the snapshot to `:persistent_term`.
- `Ankole.Plugins.Supervisor` starts the `children/0` specs of active plugins.
- If `Ankole.Plugins.Registry` crashes, `Ankole.Plugins.Cohort` restarts both `Registry` and `Supervisor` from that same immutable boot snapshot, ensuring that configuration edits saved after boot cannot alter the active plugin set mid-run. Meanwhile, a crash inside an individual plugin child stays isolated under `Ankole.Plugins.Supervisor`.

## Operator API

Site administrators inspect and stage Control Plane Plugins through two JSON:API routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | List discovered plugins with `activation`, `configured_enabled`, `active`, and `restart_required` |
| `PUT` | `/api/v2/site/control-plane-plugins` | Stage `{ "data": { "id": string, "enabled": boolean } }` for an `:optional` plugin on the next process start |

Ankole authorizes both routes against `site_console:control_plane_plugins` (`read` and `update`) in the privileged tenant.

## Scope and boundaries

Control Plane Plugins run inside the same BEAM node and trust domain as the control plane. They do not package model-facing Worker Skills or tools; Agent capabilities live in [Agent Library](../agent-library/), where operators enable Agent Plugins and Control Plane Plugins independently.

## Next steps

- For messaging and webhook adapters, read [Signals](../signals/).
- For `AppConfigure` settings and feature flags, read [AppConfigure](../app-configuration/) and [Console](../console-api/).
- For site administration permissions, read [Principal and AuthZ](../principal-authz/).
