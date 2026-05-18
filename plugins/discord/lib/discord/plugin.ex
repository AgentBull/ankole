defmodule Discord.Plugin do
  @moduledoc """
  Registers the trusted Discord EventBus channel adapter and OAuth2 login hook.

  Discord stays inside the plugin boundary. It normalizes Discord gateway and
  interaction occurrences into Events, exposes Discord transport delivery, and
  provides source-scoped OAuth2 login subjects. Event routing and business
  processing remain owned by EventBus and Targets.
  """

  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "discord",
        module: Discord.ChannelAdapter,
        opts: %{provider: "discord"}
      },
      %{
        point: :"bullx.principals.login_provider",
        id: "discord",
        module: Discord.OAuth2Provider,
        opts: %{adapter: "discord", kind: :oauth2}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [Discord.Config]

  @impl BullX.Plugins.Plugin
  def children(_context), do: [Discord.SourceSupervisor]
end
