defmodule BullX.Plugins do
  @moduledoc """
  Plugin host API.

  Most of BullX's third-party integrations — Discord, Feishu, Telegram, and
  other IM/transport channels; tool registries; future Workflow extensions —
  are shipped as plugins compiled into the release. A plugin declares one or
  more **extension points** it contributes to (e.g.
  `bullx.im_gateway.channel_adapter`), and the host validates, registers, and
  supervises them at boot. Enablement is runtime config: a single release can
  carry every adapter the codebase knows about and a deployment turns on only
  the ones it has credentials for.

  This is closer to a VS Code / IDE extension model than to a hot-reloaded
  `require`: plugins are first-class compile-time citizens with typed
  contracts (see `BullX.IMGateway.ChannelAdapter`), not arbitrary code loaded
  from disk at runtime — a design choice that matters because BullX agents
  act with real authority (Principals, Budgets, channel identities), and the
  surface where third-party code reaches the runtime is auditable rather
  than dynamic.

  ## Internal contract

  The plugin host discovers trusted compile-time plugins, validates their
  declarations, stores extension metadata in a reconstructible registry, and
  starts children for plugins enabled through runtime configuration.
  """

  defdelegate plugins(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate enabled_plugins(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate enabled?(id, server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate all_extensions(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate extensions_for(point, server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry

  defdelegate enabled_extensions_for(point, server \\ BullX.Plugins.Registry),
    to: BullX.Plugins.Registry
end
