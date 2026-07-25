---
title: Control Plane Plugins
description: The first-party Elixir extension model — discovered and active plugins, subsystem contracts, AppConfigure keys, supervised children, and the next-start enable boundary.
section: Concepts
order: 16
---

Control Plane Plugins are how an Ankole installation extends its own control plane — adds a signal adapter, an identity provider, an AppConfigure key, or a supervised process — without the control plane growing those things as one-off code paths. This page maps the model against the real code in `Ankole.Plugins`.

The decisive property, stated up front: these are first-party Elixir modules compiled into the release, not a marketplace of installable extensions. A plugin is discovered and validated at boot, opted into through a single global enable list, and activated only on the next process start. There is no hot-load, no third-party discovery, no isolation machinery — by design.

## Two stages with different meanings

A plugin's lifecycle has two stages, and the distinction is load-bearing:

- **Discovered** — every plugin module found and validated at boot. This is the full catalog the operator can see, whether or not it is enabled.
- **Active** — the discovered plugins that are in the global enable list. Only active plugins register their AppConfigure keys and start their supervised children.

A plugin that is discovered but not active is visible but inert. Its declarations do not reach the subsystems that would consume them, and its children do not run. This is what lets an operator survey the whole catalog before committing to one.

## The plugin contract

A plugin is an Elixir module that implements a small set of callbacks against `Ankole.Plugins.Plugin`. Only one is required:

- **`plugin_id/0`** — the plugin's identity, a lowercase slug matching `~r/\A[a-z][a-z0-9_-]*\z/`.

The rest are optional and default to empty or nil when the module does not export them:

- **`display_name/0`**, **`description/0`** — localized text for the operator surface.
- **`app_config_definitions/0`**, **`app_config_patterns/0`** — AppConfigure keys the plugin contributes.
- **`adapter_declarations/0`** — the generic envelope that lets a plugin plug into a subsystem contract.
- **`children/0`** — supervised child specs the plugin wants started.

`Spec.from_module/1` reads these callbacks at boot and normalizes them into a `Spec`. Validation is strict for plugin-owned shape — identity, localized text, AppConfigure declarations, children, and the adapter declaration envelope — and errors are wrapped with the offending module, so a boot failure points at the responsible plugin.

## Subsystem contracts

A plugin plugs into a subsystem through a named contract, and contract ids may contain dots so subsystems can namespace them. The contracts in actual use:

- **`signals_gateway.adapter`** — declare a Signal adapter that SignalsGateway resolves into its adapter registry. This is how a new chat or event provider becomes available as a binding target.
- **`signals_gateway.webhook_handler`** — declare a handler for the `/webhooks/v1/:handler_id/:instance_id/:kind` front door. The handler owns provider authentication and calls into ingress with a normalized fact.
- **`principals.identity_provider`** — declare an identity provider the operator can configure for admin sign-in.

Contract-specific callback semantics stay with the subsystem that consumes the contract. The plugin registry only holds the generic adapter declaration envelope; the subsystem (`SignalsGateway.Adapters`, for example) reads the declarations for its own contract id and interprets them. That separation keeps the registry a dumb catalog and the subsystem the smart consumer.

## The enable boundary: next process start

Plugins are installation-global and fail closed, so the operator explicitly opts them in through one durable list: `plugins.enabled_ids`, an AppConfigure key stored in PostgreSQL. The registry reads that list once, in `init/1`, when the control plane starts.

Changing the enable list does **not** take effect immediately. It takes effect on the next Ankole process start. This is deliberate. Activating or deactivating a plugin can add or remove supervised children and config keys, which is a boot-time concern, not a hot-swap. The Console's `PUT /control-plane-plugins` route is therefore labeled "configure one Control Plane Plugin for the next process start" — it writes the intent, and a restart applies it.

The registry itself is a GenServer whose state is immutable for the lifetime of the process. If module validation, a uniqueness invariant, or config registration fails during `init/1`, it returns `:stop`, which halts application startup before the system can run with a partly registered plugin set. A bad plugin fails the boot loudly, not silently.

## The operator surface

Two console-scoped routes cover the model:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/control-plane-plugins` | List active and next-start plugin state |
| `PUT` | `/control-plane-plugins` | Configure one plugin for the next process start |

Both run through the Console policy (`control_plane_plugins` read and update actions), so they sit under the same admin authority as the rest of the Console. The list response shows both what is active now and what is staged for the next start, so an operator can tell the two apart.

## Relationship to the first-party extension model

The project's design rule is to treat the extension model as trusted and first-party, and Control Plane Plugins are exactly that surface. A plugin is compiled into the release alongside the code it extends; it runs in the same trust domain as the control plane. There is no sandbox between a plugin and the control plane, because a plugin *is* control-plane code that declared itself through the contract.

This is why the model stops where it stops. There is no third-party marketplace, no hot-loading, no per-plugin isolation — those would be different products with different threat models. What the model provides instead is a disciplined way for first-party code to contribute capabilities the control plane already knows how to consume, validated at boot and activated through an explicit operator choice.

## What Control Plane Plugins are not

They are not a runtime plugin store and not a way to ship code the operator has not reviewed. They are not the place where Agent Computer tools or skills live — those are [Agent Library](../agent-library/) capabilities and worker-side tooling. And they are not hot-configurable; the next-start rule is the contract, and it exists because the things a plugin changes (children, config keys) are boot-time concerns. The boundary is clean: first-party code, declared through a contract, validated at boot, activated on the next start.

## Next steps

- For the signal adapters a plugin can declare, read the [SignalsGateway](../signals-gateway/) page.
- For the AppConfigure keys a plugin contributes, read the [Console](../console/) page.
- For the trust model this extension surface sits inside, read [Principal and AuthZ](../principal-authz/).
