# Plugins

BullX plugins are compile-time trusted packages. They declare metadata,
extensions, optional config modules, and optional supervised children. The
runtime does not load plugin code from disk dynamically.

The implementation lives in `BullX.Plugins.*`.

## Discovery And Registry

`BullX.Plugins.Discovery` finds configured plugin modules. `BullX.Plugins.Spec`
validates plugin declarations and normalizes extension metadata.

`BullX.Plugins.Registry` stores:

- all discovered plugin specs;
- enabled plugin ids;
- all extensions;
- enabled extensions.

The public facade is `BullX.Plugins`.

## Enabled Plugins

Enabled plugin ids come from `BullX.Config.Plugins.enabled_plugins!/0`.

The default first-party enabled plugin ids are currently:

- `feishu`
- `bullx_telegram`

Additional internal plugin apps can be configured through the plugin config
module. A plugin id must match the OTP app name in `BullX.Plugins.Spec`.

## Plugin Declaration

A plugin module exposes `__bullx_plugin__/0` metadata with API version `1`.
Optional `display_name` and `description` values can be plain strings or
locale-keyed maps.

`extensions/0` returns extension declarations. Extension ids must be unique per
extension point inside one plugin.

`config_modules/0` returns modules that expose BullX config declarations and
secret-key metadata.

`children/0`, when present, returns supervised children for
`BullX.Plugins.Supervisor`.

## Current Extension Points

Current in-tree extension points are:

- `:"bullx.im_gateway.channel_adapter"`
- `:"bullx.principals.login_provider"`
- `:"bullx.llm.req_llm_provider"`
- `:"bullx.ai_agent.toolset"`

## IM Channel Adapter

The IM channel adapter extension is consumed by
`BullX.IMGateway.ChannelAdapter`.

An adapter module must implement `normalize_inbound/2`. It may implement
`deliver/4`, `fetch_source/1`, `consume_stream/4`, and `capabilities/0`.

Adapters normalize provider input to CloudEvents mail and hand it to IMGateway.
They do not create `mailbox_entries` directly.

Current setup-backed adapter ids:

- `feishu`
- `discord`
- `telegram`, provided by the `bullx_telegram` plugin

## Principal Login Provider

The login provider extension is consumed by `BullX.Principals.LoginProviders`
and web session controllers.

Current login provider plugins:

- Feishu OIDC
- Discord OAuth/OIDC-style login provider

Telegram currently provides IM channel identity and `/webauth` login auth code
support, but no browser OIDC provider extension.

## LLM Provider Plugins

`BullX.LLM.PluginProviders` registers built-in ReqLLM provider modules and
enabled plugin provider extensions at runtime start.

The `chinese_llm_providers_extra` plugin currently contributes additional
ReqLLM provider modules and overrides for Chinese LLM providers.

## AIAgent ToolSet Plugins

`BullX.AIAgent.Tools.Registry` reads `:"bullx.ai_agent.toolset"` extensions in
addition to code-owned built-in ToolSets. ToolSet plugins provide tool
definitions and callbacks, but AIAgent still enforces ACL and runtime execution
rules.

## Config

Plugin configuration uses the normal `BullX.Config` mechanism. Plugin secret
keys are declared by plugin config modules and participate in config encryption
and secret-key audits.

IM source setup modules store source configuration in plugin-owned config keys.
The ChannelAdapter fetches sources through the plugin setup/runtime modules.

## Invariants

- Plugin code is trusted and compiled into the release.
- Disabled plugins do not expose enabled extensions or supervised children.
- Adapters must not claim another adapter id in normalized CloudEvents data.
- MailBox receiver selection belongs to MailBox delivery rules, not plugins.
