defmodule Feishu.Plugin do
  @moduledoc """
  Registers the trusted Feishu/Lark Gateway adapter and Principal login hook.

  The plugin has no plugin-wide runtime supervisor. Enabled Gateway sources
  start their own source listeners under `BullX.Gateway.SourceSupervisor`.
  """

  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.gateway.adapter",
        id: "feishu",
        module: Feishu.GatewayAdapter
      },
      %{
        point: :"bullx.principals.login_provider",
        id: "feishu",
        module: Feishu.OIDCProvider,
        opts: %{adapter: "feishu", kind: :oidc}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [Feishu.Config]
end
