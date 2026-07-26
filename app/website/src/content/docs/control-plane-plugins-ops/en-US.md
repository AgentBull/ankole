---
title: Control Plane Plugin operations
description: How to enable, disable, and inspect Control Plane Plugins through the Console — the next-start model and what to check before and after a change.
section: User guide
order: 56
---

Control Plane Plugins extend the control plane with first-party Elixir modules — signal adapters, identity providers, AppConfigure keys, supervised children. The operator's job is to enable and disable them, and to understand when the change takes effect. This page is the task-oriented view of that surface.

The decisive property, stated up front: plugin activation takes effect on the **next process start**, not immediately. This is deliberate — activating or deactivating a plugin can add or remove supervised children and config keys, which is a boot-time concern. You stage the change through the Console; a restart applies it.

## List plugins

```bash
curl https://ankole.example.com/api/v1/control-plane-plugins \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /control-plane-plugins` returns every discovered plugin — its id, display name, description, and two states:

- **discovered** — the plugin is compiled into the release and visible in the catalog. Every discovered plugin appears here, whether or not it is enabled.
- **active** — the plugin is in the global enable list and will contribute its config and children on the next start (or is already contributing them, if the current process started with it enabled).

The response shows both states side by side, so you can tell what is active now and what is staged for the next start.

## Enable or disable a plugin

```bash
curl -X PUT https://ankole.example.com/api/v1/control-plane-plugins \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "id": "lark-adapter", "enabled": true }'
```

`PUT /control-plane-plugins` stages one plugin for the next start. The response shows the updated state — what will be active after the next restart. The change does not take effect until the control plane restarts.

## When the change takes effect

After `PUT`, restart the control plane:

```bash
# Compose
docker compose restart control-plane

# Helm
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

On restart, the registry reads the enable list, activates the enabled plugins, registers their AppConfigure keys, and starts their supervised children. A plugin that was disabled has its children stopped and its keys unregistered.

If a plugin fails during activation (bad config, missing dependency, uniqueness conflict), the registry's `init` returns `:stop`, which halts application startup before it can run with a partly registered plugin set. The failure is loud, not silent.

## What to check before enabling

- **Is the plugin's configuration ready?** Some plugins need AppConfigure keys or adapter credentials before they can work. Check the plugin's documentation or the adapter page.
- **Does the plugin need a network path?** Signal adapters that use long connections need outbound internet; webhook handlers need a public ingress. Confirm the deployment has the path the plugin needs.
- **Are there conflicts?** Two plugins that declare the same adapter id or the same config key conflict. The registry rejects the second one at boot.

## What to check after enabling

- **Did the control plane start cleanly?** Read the startup logs for plugin initialization errors.
- **Is the plugin's contract surface visible?** For a signal adapter, `GET /signal-adapters` should show the new adapter. For an identity provider, `GET /identity-provider-adapters` should show it.
- **Does a real round-trip work?** Send a test message or trigger a test login through the newly enabled adapter.

## What this guide is not

It is not the plugin concept page — for the discovered/active model, the contracts, and the first-party extension design, read [Control Plane Plugins](../control-plane-plugins/). It is not a plugin-authoring guide — for writing a plugin, read [Creating a Control Plane Plugin](../creating-a-control-plane-plugin/). And it is not a deployment guide — for restarting the control plane, read [Updating](../updating/) or [Installation](../installation/).

## Next steps

- For the concept page, read [Control Plane Plugins](../control-plane-plugins/).
- For writing a plugin, read [Creating a Control Plane Plugin](../creating-a-control-plane-plugin/).
- For restarting, read [Updating](../updating/).
- For the Console routes, read the [Console API reference](../console-api/).
