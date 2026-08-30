defmodule Ankole.IdentityProvidersTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.PluginFixtures.UnknownIdentityCapabilityPlugin
  alias Ankole.Plugins.Config, as: PluginConfig
  alias Ankole.Plugins.LarkAdapter

  import Ankole.IdentityProviderTestHelpers

  defmodule TestRealtimeReconciler do
    @moduledoc false

    def reconcile do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:identity_realtime_reconciled, self()})
      %{started: 1, errors: []}
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
  end

  test "adapter catalog hides active plugins removed from the next-start enable list" do
    assert Enum.any?(IdentityProviders.list_adapters(), &(&1.plugin_id == "lark-adapter"))
    assert {:ok, []} = PluginConfig.put_enabled_ids([])
    # The built-in local adapter is part of the control plane, not a plugin,
    # so the enable list does not remove it.
    assert Enum.map(IdentityProviders.list_adapters(), & &1.adapter_id) == ["local"]
  end

  test "adapter catalog fails closed when the enable list cannot be decoded" do
    :ok = AppConfigure.delete_global(PluginConfig.enabled_ids_definition())
    now = DateTime.utc_now(:second)

    Repo.insert!(%AppConfig{
      scope: "global",
      key: "plugins.enabled_ids",
      value: %{"type" => "plaintext", "value" => "invalid"},
      inserted_at: now,
      updated_at: now
    })

    Cache.clear_for_test()
    assert Enum.map(IdentityProviders.list_adapters(), & &1.adapter_id) == ["local"]
  end

  test "saving an enabled provider enqueues the first full sync" do
    assert {:ok, provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
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

  test "a second local provider instance is rejected" do
    assert {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)

    # Saving the same instance again stays an upsert.
    assert {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)

    assert {:error, {:local_provider_exists, "local-main"}} =
             IdentityProviders.save_provider("local-2", "local", %{}, true)
  end

  test "saving a websocket-enabled provider reconciles realtime directory listeners immediately" do
    put_test_reconciler_pid()

    update_lark_identity_declaration(fn declaration ->
      Map.put(declaration, :connection_reconciler, TestRealtimeReconciler)
    end)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appID" => "cli_identity",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => true, "websocket" => true}
               },
               true,
               reconcile_realtime?: true
             )

    assert_received {:identity_realtime_reconciled, _pid}
  end

  test "invalid identity provider adapter declarations return contract errors" do
    assert {:error,
            {:unsupported_identity_provider_operation, MissingIdentityCallbackPlugin,
             :upsert_user, 2}} =
             MissingIdentityCallbackPlugin.adapter_declarations()
             |> List.first()
             |> IdentityProviders.validate_adapter_declaration()

    assert {:error, {:unknown_identity_capability, "made_up"}} =
             UnknownIdentityCapabilityPlugin.adapter_declarations()
             |> List.first()
             |> IdentityProviders.validate_adapter_declaration()
  end

  test "adapter validation loads compiled callback modules before checking them" do
    declaration =
      LarkAdapter.adapter_declarations()
      |> Enum.find(&(&1.contract_id == "principals.identity_provider"))

    reconciler = declaration.connection_reconciler
    :code.purge(reconciler)
    :code.delete(reconciler)

    assert :code.is_loaded(reconciler) == false
    assert :ok = IdentityProviders.validate_adapter_declaration(declaration)
    assert {:file, _path} = :code.is_loaded(reconciler)
  end

  test "list_active_provider_refs returns only enabled refs for one adapter" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled",
               "lark",
               %{"appID" => "cli_identity_disabled", "appSecret" => "secret"},
               false
             )

    assert {:ok, refs} = IdentityProviders.list_active_provider_refs("lark")

    assert refs == [
             %{
               "provider_id" => "lark-main",
               "adapter_id" => "lark",
               "plugin_id" => "lark-adapter",
               "config_key" => "principals.identity_providers.lark.lark-main"
             }
           ]
  end

  defp put_test_reconciler_pid do
    :persistent_term.put({TestRealtimeReconciler, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({TestRealtimeReconciler, :test_pid})
    end)
  end
end
