defmodule Ankole.IdentityProviders.LoginTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.Login
  alias Ankole.Plugins.LarkAdapter

  import Ankole.IdentityProviderTestHelpers

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
  end

  test "login list carries only enabled providers that can sign an admin in" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-off",
               "lark",
               %{"appID" => "cli_off", "appSecret" => "secret"},
               false
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-sync-only",
               "lark",
               %{
                 "appID" => "cli_sync",
                 "appSecret" => "secret",
                 "oidc" => %{"enabled" => false}
               },
               true
             )

    assert {:ok, providers} = Login.list_login_providers()
    assert Enum.map(providers, & &1["provider_id"]) == ["lark-main"]
  end

  test "login list excludes adapters without the OIDC capability" do
    update_lark_identity_declaration(fn declaration ->
      Map.update!(declaration, :capabilities, &List.delete(&1, "oidc_authorization"))
    end)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, []} = Login.list_login_providers()
  end

  test "authorization_url builds the provider URL for a login-enabled provider" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret", "domain" => "feishu"},
               true
             )

    assert {:ok, url} =
             Login.authorization_url("lark-main",
               redirect_uri: "https://ankole.example/sessions/oidc/lark-main/callback",
               state: "st-1"
             )

    assert url =~ "app_id=cli_identity"
    assert url =~ "state=st-1"
  end

  test "authorization_url and complete_oidc_login refuse a login-disabled provider" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appID" => "cli_identity",
                 "appSecret" => "secret",
                 "oidc" => %{"enabled" => false}
               },
               true
             )

    assert {:error, :oidc_disabled} =
             Login.authorization_url("lark-main", redirect_uri: "https://x", state: "s")

    assert {:error, :oidc_disabled} = Login.complete_oidc_login("lark-main", "code-1", [])
  end

  test "authorization_url refuses an adapter without the OIDC capability" do
    update_lark_identity_declaration(fn declaration ->
      Map.update!(declaration, :capabilities, &List.delete(&1, "oidc_authorization"))
    end)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:error, :oidc_unsupported} =
             Login.authorization_url("lark-main", redirect_uri: "https://x", state: "s")
  end
end
