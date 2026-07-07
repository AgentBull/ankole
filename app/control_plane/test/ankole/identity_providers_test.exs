defmodule Ankole.IdentityProvidersTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.PluginFixtures.UnknownIdentityCapabilityPlugin
  alias Ankole.Plugins.LarkAdapter

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
    :ok = IdentityProviderConfig.ensure_registered()
  end

  test "directory full sync interval defaults to six hours and is operator configurable" do
    assert {:ok, 21_600} = IdentityProviderConfig.directory_full_sync_interval_seconds()

    assert {:ok, 2} =
             AppConfigure.put_global(
               IdentityProviderConfig.directory_full_sync_interval_hours_definition(),
               2
             )

    assert {:ok, 7_200} = IdentityProviderConfig.directory_full_sync_interval_seconds()

    assert {:error, {:invalid_integer, "directory_full_sync_interval_hours", %{min: 1}}} =
             AppConfigure.put_global(
               IdentityProviderConfig.directory_full_sync_interval_hours_definition(),
               0
             )
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

  test "list_active_provider_refs returns only enabled refs for one adapter" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled",
               "lark",
               %{"appId" => "cli_identity_disabled", "appSecret" => "secret"},
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

  test "sync_provider honors disabled sync flags without calling the adapter" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appId" => "cli_identity",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false, "websocket" => true}
               },
               true
             )

    refute_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "provider_saved", "source" => "setup"}
    )

    assert {:ok,
            %{
              provider_id: "lark-main",
              directory: :skipped
            }} = IdentityProviders.sync_provider("lark-main")
  end

  test "manual enqueue rejects unknown and sync-disabled providers" do
    assert {:error, {:unknown_identity_provider, "missing-main"}} =
             IdentityProviders.enqueue_sync("missing-main")

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appId" => "cli_identity",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false}
               },
               true
             )

    assert {:error, :sync_disabled} = IdentityProviders.enqueue_sync("lark-main")
  end

  test "periodic manual enqueue rejects invalid interval overrides" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:error, {:invalid_directory_full_sync_interval_seconds, 0}} =
             IdentityProviders.enqueue_sync("lark-main",
               reason: "periodic",
               source: "cron",
               directory_full_sync_interval_seconds: 0
             )
  end

  test "directory sync is skipped when the adapter does not declare the capability" do
    without_lark_directory_full_sync_capability()

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    refute_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "provider_saved", "source" => "setup"}
    )

    assert {:error, :sync_unsupported} = IdentityProviders.enqueue_sync("lark-main")

    assert {:ok, %{provider_id: "lark-main", directory: :skipped}} =
             IdentityProviders.sync_provider("lark-main")

    assert {:ok, %{enqueued: [], skipped: ["lark-main"]}} =
             IdentityProviders.enqueue_directory_syncs()
  end

  test "periodic directory sync worker enqueues only enabled contacts-enabled providers" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled-sync",
               "lark",
               %{
                 "appId" => "cli_identity_disabled",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false}
               },
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled-provider",
               "lark",
               %{"appId" => "cli_identity_disabled_provider", "appSecret" => "secret"},
               false
             )

    assert {:ok, %{enqueued: [_job], skipped: skipped}} =
             perform_job(EnqueueDirectorySyncs, %{})

    assert Enum.sort(skipped) == ["lark-disabled-provider", "lark-disabled-sync"]

    assert_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "periodic", "source" => "cron"}
    )

    refute_enqueued(
      worker: SyncProvider,
      args: %{
        "provider_id" => "lark-disabled-sync",
        "reason" => "periodic",
        "source" => "cron"
      }
    )
  end

  test "periodic directory sync enqueue honors the configured full sync interval" do
    assert {:ok, 1} =
             AppConfigure.put_global(
               IdentityProviderConfig.directory_full_sync_interval_hours_definition(),
               1
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appId" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, %{enqueued: [_job], skipped: []}} =
             IdentityProviders.enqueue_directory_syncs()

    assert {:ok, %{enqueued: [], skipped: ["lark-main"]}} =
             IdentityProviders.enqueue_directory_syncs()

    age_periodic_sync_jobs("lark-main", 3_700)

    assert {:ok, %{enqueued: [_job], skipped: []}} =
             IdentityProviders.enqueue_directory_syncs()
  end

  defp age_periodic_sync_jobs(provider_id, seconds) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -seconds, :second)

    Repo.update_all(
      from(job in Oban.Job,
        where: job.worker == ^inspect(SyncProvider),
        where: fragment("?->>? = ?", job.args, "provider_id", ^provider_id),
        where: fragment("?->>? = ?", job.args, "reason", "periodic"),
        where: fragment("?->>? = ?", job.args, "source", "cron")
      ),
      set: [inserted_at: cutoff]
    )
  end

  defp without_lark_directory_full_sync_capability do
    original_state = :sys.get_state(Ankole.Plugins.Registry)

    :sys.replace_state(Ankole.Plugins.Registry, fn state ->
      update_in(state.active["lark-adapter"].adapter_declarations, fn declarations ->
        Enum.map(declarations, fn declaration ->
          case Map.get(declaration, :contract_id) do
            "principals.identity_provider" ->
              Map.update!(declaration, :capabilities, &List.delete(&1, "directory_full_sync"))

            _other ->
              declaration
          end
        end)
      end)
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)
  end
end
