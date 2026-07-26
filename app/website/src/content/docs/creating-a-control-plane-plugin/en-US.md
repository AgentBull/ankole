---
title: Creating a Control Plane Plugin
description: How to write a first-party Elixir plugin that contributes a signal adapter, an identity provider, AppConfigure keys, or supervised children to the control plane.
section: Developer guide
order: 113
---

A Control Plane Plugin is the first-party extension surface for the Elixir control plane. This page is the contributor walkthrough: the callback contract, the smallest possible plugin, the declarations that plug into subsystem contracts, and the registration that makes the plugin discoverable. It builds on the [Control Plane Plugins](../control-plane-plugins/) concept page; this is *how to write one*.

The decisive property, stated up front: a plugin is an Elixir module compiled into the release, registered in `config/config.exs`, and discovered at boot. There is no marketplace, no hot-load, no third-party packaging — a plugin is first-party code that declared itself through the contract. Write it as you would write any module in the control plane.

## The callback contract

A plugin implements callbacks against `Ankole.Plugins.Plugin`. Only one is required; the rest are optional and default to empty or nil:

| Callback | Required | Returns |
|---|---|---|
| `plugin_id/0` | yes | a lowercase slug (`~r/\A[a-z][a-z0-9_-]*\z/`) |
| `display_name/0` | no | localized text, or nil |
| `description/0` | no | localized text, or nil |
| `app_config_definitions/0` | no | a list of AppConfigure `Definition` structs |
| `app_config_patterns/0` | no | a list of AppConfigure `PatternDefinition` structs |
| `adapter_declarations/0` | no | a list of adapter declaration maps |
| `children/0` | no | a list of `Supervisor.child_spec` |

`Spec.from_module/1` reads these callbacks at boot and normalizes them into a `Spec`. Validation is strict for plugin-owned shape (identity, localized text, AppConfigure declarations, children, the adapter declaration envelope), and errors are wrapped with the offending module so a boot failure points at the responsible plugin.

## The smallest possible plugin

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

That is a complete, valid plugin. It declares nothing, contributes nothing, and is discovered and listed by the registry. It is the starting point — add callbacks as the plugin needs to contribute.

## Register the plugin

Add the module to the plugin list in `config/config.exs`:

```elixir
config :ankole, :control_plane_plugin_modules, [
  # ...existing plugins...
  Ankole.Plugins.MyPlugin
]
```

The registry reads this list at boot. The plugin appears in `GET /control-plane-plugins` as discovered; enable it through the Console to make it active (which registers its AppConfigure keys and starts its children).

## Declaring an adapter (signal adapter or identity provider)

The `adapter_declarations/0` callback returns adapter declaration maps, each plugging the plugin into a subsystem contract. The contract id names the subsystem:

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals_gateway.adapter",
      id: "my-adapter",
      plugin_id: plugin_id(),
      # ...adapter-specific fields, module, config_key_pattern...
    }
  ]
end
```

The contract-specific fields (`config_module`, `binding_saved_module`, `worker_env_module`, and so on) are interpreted by the subsystem that consumes the contract — `SignalsGateway.Adapters` for `signals_gateway.adapter`, the identity-provider registry for `principals.identity_provider`. The plugin registry only holds the generic envelope; the subsystem is the smart consumer. See the [SignalsGateway](../signals-gateway/) developer page for how an adapter declaration is consumed.

## Contributing AppConfigure keys

The `app_config_definitions/0` callback returns `Definition` structs for the operator-managed keys the plugin contributes. These are registered when the plugin is active, and they appear in the Console's AppConfigure surface:

```elixir
@impl true
def app_config_definitions do
  [
    AppConfigure.define(
      key: "my_plugin.setting",
      encrypted: false,
      schema: Schema.string(),
      scope: :global,
      default_value: "default",
      description: "A setting my plugin reads at runtime."
    )
  ]
end
```

Use `app_config_patterns/0` for the encrypted config patterns — for example, the shape of a provider's credential block. See [Environment variables](../environment-variables/) for the distinction between bootstrap env and AppConfigure keys; a plugin's keys are always AppConfigure, never bootstrap env.

## Contributing supervised children

The `children/0` callback returns child specs the plugin wants started when it is active — a `GenServer` that owns a long-connection, a `Registry`, a periodic reconciler. These run under the plugin's supervision tree, started when the plugin is enabled and stopped when it is disabled (on the next process start).

## The lifecycle: discovered, then active

The registry resolves the full plugin set once, in `init/1`. A plugin is **discovered** (in the catalog the operator sees) from the moment it is registered; it is **active** (config registered, children started) only when it is in the global enable list. Enabling is a Console operation; activation takes effect on the next process start. See [Control Plane Plugins](../control-plane-plugins/) for why activation is a boot-time concern.

## What this guide is not

It is not a tutorial on Elixir or OTP — write a plugin the way you write any module in the control plane. It is not a way to ship third-party or hot-loaded code; the model is first-party, compiled-in, boot-activated. And it is not a substitute for the subsystem pages; an adapter declaration's exact fields are documented by the subsystem that consumes them, not by this page.

## Next steps

- For the concept page (discovered vs active, the enable boundary), read [Control Plane Plugins](../control-plane-plugins/).
- For how a signal adapter declaration is consumed, read [SignalsGateway](../signals-gateway/).
- For the AppConfigure keys a plugin contributes, read [Environment variables](../environment-variables/).
