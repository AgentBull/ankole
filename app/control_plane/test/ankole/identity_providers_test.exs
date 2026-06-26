defmodule Ankole.IdentityProvidersTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins.LarkAdapter

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
    :ok = IdentityProviderConfig.ensure_registered()
  end

  test "saving an enabled provider enqueues the first full sync" do
    assert {:ok, provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert provider["provider_id"] == "lark-main"

    assert_enqueued(
      worker: SyncProvider,
      args: %{
        "provider_id" => "lark-main",
        "reason" => "provider_saved",
        "source" => "setup"
      }
    )
  end

  test "sync_provider honors disabled sync flags without calling the adapter" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appId" => "cli_identity",
                 "appSecret" => "secret",
                 "sync" => %{"users" => false, "departments" => false}
               },
               true
             )

    assert {:ok,
            %{
              provider_id: "lark-main",
              users: :skipped,
              departments: :skipped
            }} = IdentityProviders.sync_provider("lark-main")
  end
end
