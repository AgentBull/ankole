defmodule Discord.Plugin do
  @moduledoc """
  Registers the trusted Discord Gateway adapter and OAuth2 login provider.

  The plugin has no plugin-wide runtime supervisor of its own. Enabled Gateway
  sources start their per-source runtime under `BullX.Gateway.SourceSupervisor`
  through `Discord.GatewayAdapter.source_child_spec/1`.

  The plugin exposes two extension declarations:

  - `:"bullx.gateway.adapter"` id `"discord"` for Signals Gateway transport.
  - `:"bullx.principals.login_provider"` id `"discord"` for Human OAuth2
    browser login. The concrete Principal `login_subject.provider` is the
    enabled Gateway source slug, not the literal `"discord"`.
  """

  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.gateway.adapter",
        id: "discord",
        module: Discord.GatewayAdapter
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
  def children(_context) do
    [
      {Registry, keys: :unique, name: Discord.Registry}
    ]
  end
end
