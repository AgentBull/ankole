defmodule BullxTelegram.Plugin do
  @moduledoc """
  Registers the trusted Telegram Gateway adapter.

  The plugin has no plugin-wide runtime supervisor. Enabled Gateway sources
  start their own source listeners under `BullX.Gateway.SourceSupervisor`.

  Module namespace is `BullxTelegram.*` instead of `Telegram.*` because the
  `visciang/telegram` hex package owns the root `Telegram.*` namespace.
  """

  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.gateway.adapter",
        id: "telegram",
        module: BullxTelegram.GatewayAdapter
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [BullxTelegram.Config]

  @impl BullX.Plugins.Plugin
  def children(_context) do
    [
      {Registry, keys: :unique, name: BullxTelegram.Registry}
    ]
  end
end
