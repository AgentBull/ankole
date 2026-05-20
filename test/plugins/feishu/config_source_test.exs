defmodule Feishu.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias Feishu.Config.EventBusSources
  alias Feishu.Source

  test "eventbus source cast normalizes one channel instance with source-local app secret" do
    assert {:ok, [source]} =
             EventBusSources.cast([
               %{
                 id: "main",
                 app_id: "cli_x",
                 app_secret: "secret_x",
                 web_login_disabled: true,
                 oidc: %{enabled: true}
               }
             ])

    assert source["id"] == "main"
    assert source["app_id"] == "cli_x"
    assert source["app_secret"] == "secret_x"
    assert source["domain"] == "feishu"
    assert source["enabled"] == true
    assert source["web_login_disabled"] == true
    assert source["oidc"] == %{"enabled" => true}
  end

  test "source normalization builds a redacted public projection" do
    assert {:ok, source} =
             Source.normalize(%{
               id: "main",
               app_id: "cli_x",
               app_secret: "secret_x",
               web_login_disabled: true,
               domain: "lark",
               oidc: %{enabled: true, redirect_uri: "https://bullx.example.com/callback"}
             })

    assert source.domain == :lark
    assert source.web_login_disabled? == true

    refute inspect(source) =~ "app_secret"
    refute inspect(source) =~ "secret_x"

    public = Source.public_config(source)
    refute Map.has_key?(public, "app_secret")
    assert public["app_id"] == "cli_x"
  end
end
