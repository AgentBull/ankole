defmodule Feishu.Plugin do
  @moduledoc """
  Registers the trusted Feishu/Lark EventBus channel adapter and Principal login hook.

  Feishu remains a transport and identity-evidence plugin. It normalizes
  provider input into Events, sends provider replies, and exposes source-scoped
  OIDC login subjects; Event routing and business processing stay in BullX
  core and Targets.
  """

  use BullX.Plugins.Plugin,
    display_name: %{"en-US" => "Feishu / Lark", "zh-Hans-CN" => "飞书 / Lark"},
    description: %{
      "en-US" => "Channel adapter and source-scoped OIDC login for Feishu and Lark workspaces.",
      "zh-Hans-CN" => "面向飞书和 Lark 工作空间的通道适配器与来源域 OIDC 登录。"
    }

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "feishu",
        module: Feishu.ChannelAdapter,
        opts: %{provider: "feishu", setup_module: Feishu.SourceSetup}
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

  @impl BullX.Plugins.Plugin
  def children(_context), do: [Feishu.SourceSupervisor]
end
