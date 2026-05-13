defmodule Feishu.PluginTest do
  use ExUnit.Case, async: true

  alias BullX.Plugins.Discovery

  test "declares Gateway adapter and Principal login-provider extensions" do
    assert {:ok, spec} = Discovery.discover_app(:feishu, modules: [Feishu.Plugin])

    assert spec.id == "feishu"
    assert spec.config_modules == [Feishu.Config]

    assert Enum.any?(spec.extensions, fn extension ->
             extension.point == :"bullx.gateway.adapter" and extension.id == "feishu" and
               extension.module == Feishu.GatewayAdapter
           end)

    assert Enum.any?(spec.extensions, fn extension ->
             extension.point == :"bullx.principals.login_provider" and
               extension.id == "feishu" and extension.module == Feishu.OIDCProvider
           end)
  end
end
