defmodule Feishu.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias Feishu.Config.{Credentials, EventBusSources}
  alias Feishu.Source

  test "credentials cast keeps app secrets under credential profiles" do
    assert {:ok,
            %{
              "main" => %{
                "app_id" => "cli_x",
                "app_secret" => "secret_x",
                "app_type" => "self_built",
                "verification_token" => "verify_x",
                "encrypt_key" => "encrypt_x"
              }
            }} =
             Credentials.cast(%{
               main: %{
                 app_id: "cli_x",
                 app_secret: "secret_x",
                 verification_token: "verify_x",
                 encrypt_key: "encrypt_x"
               }
             })
  end

  test "eventbus source cast normalizes operator config without secrets" do
    assert {:ok, [source]} =
             EventBusSources.cast([
               %{
                 id: "main",
                 credential_id: "default",
                 connected_realm_ref: "feishu:tenant:acme",
                 web_login_disabled: true,
                 oidc: %{enabled: true}
               }
             ])

    assert source["id"] == "main"
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
               connected_realm_ref: "feishu:tenant:acme",
               web_login_disabled: true,
               domain: "lark",
               oidc: %{enabled: true, redirect_uri: "https://bullx.example.com/callback"},
               verification_token: "verify_x",
               encrypt_key: "encrypt_x"
             })

    assert source.domain == :lark
    assert source.web_login_disabled? == true

    assert {:ok, %{verification_token: "verify_x", encrypt_key: "encrypt_x"}} =
             Source.card_action_verify_config(source)

    refute inspect(source) =~ "app_secret"
    refute inspect(source) =~ "secret_x"
    refute inspect(source) =~ "verify_x"
    refute inspect(source) =~ "encrypt_x"

    public = Source.public_config(source)
    refute Map.has_key?(public, "app_secret")
    refute Map.has_key?(public, "verification_token")
    refute Map.has_key?(public, "encrypt_key")
    assert public["connected_realm_ref"] == "feishu:tenant:acme"
  end
end
