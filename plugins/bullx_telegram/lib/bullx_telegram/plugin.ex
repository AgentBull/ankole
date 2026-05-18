defmodule BullxTelegram.Plugin do
  @moduledoc """
  Registers the trusted Telegram EventBus channel adapter.

  The plugin uses the `BullxTelegram.*` namespace because third-party Telegram
  libraries commonly own `Telegram.*`. It contributes only the EventBus channel
  adapter extension; Telegram browser login is out of scope for this design.
  """

  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "telegram",
        module: BullxTelegram.ChannelAdapter,
        opts: %{provider: "telegram"}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [BullxTelegram.Config]

  @impl BullX.Plugins.Plugin
  def children(_context), do: [BullxTelegram.SourceSupervisor]
end
