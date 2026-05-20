defmodule BullxTelegram.Plugin do
  @moduledoc """
  Registers the trusted Telegram EventBus channel adapter.

  The plugin uses the `BullxTelegram.*` namespace because third-party Telegram
  libraries commonly own `Telegram.*`. It contributes only the EventBus channel
  adapter extension; Telegram browser login is out of scope for this design.
  """

  use BullX.Plugins.Plugin,
    display_name: %{"en-US" => "Telegram", "zh-Hans-CN" => "Telegram"},
    description: %{
      "en-US" => "Channel adapter for Telegram bot conversations and outbound replies.",
      "zh-Hans-CN" => "用于 Telegram 机器人会话和出站回复的通道适配器。"
    }

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "telegram",
        module: BullxTelegram.ChannelAdapter,
        opts: %{provider: "telegram", setup_module: BullxTelegram.SourceSetup}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [BullxTelegram.Config]

  @impl BullX.Plugins.Plugin
  def children(_context), do: [BullxTelegram.SourceSupervisor]
end
