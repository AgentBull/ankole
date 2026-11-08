defmodule Ankole.IdentityProviders.LoginTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Login

  import Ankole.IdentityProviderTestHelpers

  setup do
    AppConfigureRegistry.clear_for_test()
    :ok
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

  test "login buttons name the platform each provider signs in through" do
    for {provider_id, domain} <- [{"lark-cn", "feishu"}, {"lark-global", "lark"}] do
      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 provider_id,
                 "lark",
                 %{"appID" => "cli_#{domain}", "appSecret" => "secret", "domain" => domain},
                 true
               )
    end

    assert {:ok, providers} = Login.list_login_providers()

    assert Map.new(providers, &{&1["provider_id"], &1["display_name"]}) == %{
             "lark-cn" => %{"default" => "Feishu", "zh-Hans-CN" => "飞书"},
             "lark-global" => %{"default" => "Lark"}
           }

    # Account menus and logout screens name a signed-in provider the same way.
    assert IdentityProviders.provider_name("lark-cn") == %{
             "default" => "Feishu",
             "zh-Hans-CN" => "飞书"
           }

    assert IdentityProviders.provider_name("lark-global") == %{"default" => "Lark"}
    assert IdentityProviders.provider_name("lark-missing") == nil
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
