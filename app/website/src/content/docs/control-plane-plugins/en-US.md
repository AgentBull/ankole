---
title: Control Plane Plugins
description: First-party Elixir extensions for the control plane, including activation modes, subsystem contracts, transaction hooks, Cohort supervision, and next-start configuration.
section: Developer guide
order: 110
---

Control Plane Plugins extend an Ankole site with trusted first-party Elixir and OTP code. A plugin can add `AppConfigure` keys, subsystem adapters, synchronous transaction hooks, and supervised processes through `Ankole.Plugins`.

Control Plane Plugins are first-party Elixir modules compiled into the release (`:control_plane_plugin_modules`). Ankole discovers and validates these modules at startup. Ankole does not provide a marketplace, runtime code loading, or plugin sandboxes. Optional plugins use the global enable list and activate on the next process start, while fixed build plugins with `activation: :always` are always active when compiled into the build.

## Discovered and active plugins

A plugin has two states at runtime:

- **Discovered**: Every plugin module compiled into the release and validated at startup. Operators can inspect the full discovered catalog in the Site Admin Console.
- **Active**: Every discovered plugin that has `activation/0` set to `:always`, or has `activation/0` set to `:optional` and appears in `plugins.enabled_ids` (plus all discovered plugins while first-run setup is incomplete). Only active plugins register `AppConfigure` definitions, publish subsystem adapters and domain hooks, and start supervised child processes.

A discovered plugin that is inactive stays visible in the catalog, and its saved `AppConfigure` values remain in PostgreSQL, but it registers no runtime definitions, adapters, hooks, or processes.

## The plugin contract

A plugin module implements the `Ankole.Plugins.Plugin` behaviour. Only one callback is required:

- **`plugin_id/0`**: A unique lowercase identifier that matches `~r/\A[a-z][a-z0-9_-]*\z/`.

All other callbacks are optional:

- **`activation/0`**: Returns `:optional | :always` (default `:optional`). `:optional` plugins follow `plugins.enabled_ids`. `:always` plugins stay active whenever compiled into the selected source build and reject disable requests.
- **`display_name/0`**, **`description/0`**: Localized text maps for operator interfaces.
- **`app_config_definitions/0`**, **`app_config_patterns/0`**: `Ankole.AppConfigure` keys and pattern definitions owned by the plugin.
- **`adapter_declarations/0`**: Atom-keyed adapter declarations that connect the plugin to subsystem contracts, using `Ankole.Plugins.ConfigField` schemas for browser forms.
- **`hooks/0`**: `[{hook_point, module}]` entries for synchronous in-transaction domain hooks. Each hook module implements `Ankole.Plugins.Hook.before_commit_in_tx/2` on declared hook points (`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`) and can return `{:error, reason}` to roll back the calling transaction.
- **`children/0`**: `Supervisor.child_spec()` entries started under the plugin runtime supervisor.

`Ankole.Plugins.Spec.from_module/1` reads these callbacks at startup and builds a validated `Spec`. If any module fails shape validation, duplicates an ID, or fails contract validation, startup stops with an error that names the responsible module.

## Subsystem contracts and site contribution points

`Ankole.Plugins.Contracts` defines the five subsystem adapter contracts. Each contract provides startup `validate` checks, plus optional `refresh` publication and `veto_disable` transaction guards:

- **`signals.adapter`**: Declares a messaging or event adapter validated by `Ankole.Signals.Adapters` for Signal Bindings and Conversations delivery.
- **`signals.webhook_handler`**: Declares an HTTP webhook handler validated by `Ankole.Signals.WebhookHandlers` for `/webhooks/v1/:handler_id/:instance_id/:kind`.
- **`principals.identity_provider`**: Declares an enterprise identity and directory adapter validated by `Ankole.IdentityProviders`.
- **`ai_gateway.provider`**: Declares a model provider adapter validated by `Ankole.AIGateway.Providers`, with a `refresh` callback that publishes active declarations to AI Gateway.
- **`agent_workers.provider_kind`**: Declares an Agent Worker infrastructure kind (`Ankole.AgentWorkers.ProviderKind`), with `refresh` publication from discovered and active specs and `veto_disable` (`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`) to block disabling a plugin while any tenant still has an assigned Worker row for one of its kinds.

Across a site build, first-party extensions also use compile-time, site-scoped contribution points:

- **`Ankole.Plugins.ConfigField`**: Publishes typed configuration fields from plugin adapters to Console and Pod forms.
- **Domain transaction hooks (`hooks/0`)**: Runs synchronous `Ankole.Plugins.Hook.before_commit_in_tx/2` checks inside the owning domain's transaction and lock order.
- **Outer HTTP plugs**: Runs build-selected request plugs (such as admission challenges) in an outer router before forwarding to the core router with `AnkoleWeb.runtime_forward`.
- **Dual-scoped extension JSON:API routes**: Mounts typed extension JSON:API routes under scoped `/api/v2/*` paths on the site Host and Pod Hosts, authorized through `Ankole.AuthZ.Authorizer`.
- **Typed UI slots (`entries.json` `overrides`)**: Wraps public webapps (`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`) with lazy components gated by the HTML shell's active site plugin snapshot (`ankole-active-plugins`) and optional `when` feature conditions.

Dynamic runtime policy decisions that must change without a process restart belong in OpenFeature (`Ankole.Features`), not in plugin activation.

## Cohort supervision and the next-start boundary

Optional plugins are site-wide and fail closed on completed installations. Operators select them through the global `AppConfigure` key `plugins.enabled_ids` in PostgreSQL.

Changing `plugins.enabled_ids` stages the selection for the **next Ankole process start**. It does not hot-swap running processes, adapters, or `AppConfigure` definitions. Inside the configuration write transaction, `Ankole.Plugins.Contracts.veto_disable/2` lets owning subsystems reject a disable request when durable state still depends on that plugin.

At runtime, `Ankole.Plugins.Cohort` supervises `Ankole.Plugins.Registry` before `Ankole.Plugins.Supervisor` with a `:rest_for_one` strategy over one immutable startup snapshot:

- `Ankole.Plugins.Registry` resolves the boot snapshot once, validates active declarations, registers plugin `AppConfigure` keys, refreshes subsystem views, and publishes the snapshot to `:persistent_term`.
- `Ankole.Plugins.Supervisor` starts the `children/0` specs of active plugins.
- If `Ankole.Plugins.Registry` crashes, `Ankole.Plugins.Cohort` restarts both `Registry` and `Supervisor` from the same immutable boot snapshot, so configuration edits made after boot cannot alter the active set mid-run. A crash inside one plugin child stays isolated inside `Ankole.Plugins.Supervisor`.

## Operator API

Site administrators inspect and stage Control Plane Plugins through two JSON:API routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | List discovered plugins with `activation`, `configured_enabled`, `active`, and `restart_required` |
| `PUT` | `/api/v2/site/control-plane-plugins` | Stage `{ "data": { "id": string, "enabled": boolean } }` for an `:optional` plugin on the next process start |

Both routes authorize against `site_console:control_plane_plugins` (`read` and `update`) in the privileged tenant.

## Scope and boundaries

Control Plane Plugins run in the same BEAM node and trust domain as the control plane. They do not package model-facing Worker Skills or tools; Agent capabilities live in [Agent Library](../agent-library/), where an Agent Plugin and a related Control Plane Plugin maintain independent enabled states.

## Next steps

- For messaging and webhook adapters, read [Signals](../signals/).
- For `AppConfigure` settings and feature flags, read [AppConfigure](../app-configuration/) and [Console](../console-api/).
- For site administration permissions, read [Principal and AuthZ](../principal-authz/).
