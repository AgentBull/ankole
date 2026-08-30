defmodule Ankole.IdentityProviders.DirectorySyncTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.IdentityProviders.StartupSync

  import Ankole.IdentityProviderTestHelpers

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
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

  test "control-plane startup enqueues full sync for active contacts-enabled providers" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, %{enqueued: [_job], skipped: []}} =
             StartupSync.enqueue(reason: "control_plane_started", source: "startup")

    assert_enqueued(
      worker: SyncProvider,
      args: %{
        "provider_id" => "lark-main",
        "reason" => "control_plane_started",
        "source" => "startup"
      }
    )
  end

  test "sync_provider honors disabled sync flags without calling the adapter" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appID" => "cli_identity",
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
            }} = DirectorySync.sync_provider("lark-main")
  end

  test "manual enqueue rejects unknown and sync-disabled providers" do
    assert {:error, {:unknown_identity_provider, "missing-main"}} =
             DirectorySync.enqueue_sync("missing-main")

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{
                 "appID" => "cli_identity",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false}
               },
               true
             )

    assert {:error, :sync_disabled} = DirectorySync.enqueue_sync("lark-main")
  end

  test "periodic manual enqueue rejects invalid interval overrides" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:error, {:invalid_directory_full_sync_interval_seconds, 0}} =
             DirectorySync.enqueue_sync("lark-main",
               reason: "periodic",
               source: "cron",
               directory_full_sync_interval_seconds: 0
             )
  end

  test "directory sync is skipped when the adapter does not declare the capability" do
    update_lark_identity_declaration(fn declaration ->
      Map.update!(declaration, :capabilities, &List.delete(&1, "directory_full_sync"))
    end)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    refute_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "provider_saved", "source" => "setup"}
    )

    assert {:error, :sync_unsupported} = DirectorySync.enqueue_sync("lark-main")

    assert {:ok, %{provider_id: "lark-main", directory: :skipped}} =
             DirectorySync.sync_provider("lark-main")

    assert {:ok, %{enqueued: [], skipped: ["lark-main"]}} =
             DirectorySync.enqueue_directory_syncs()
  end

  test "periodic directory sync worker enqueues only enabled contacts-enabled providers" do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled-sync",
               "lark",
               %{
                 "appID" => "cli_identity_disabled",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false}
               },
               true
             )

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-disabled-provider",
               "lark",
               %{"appID" => "cli_identity_disabled_provider", "appSecret" => "secret"},
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
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    assert {:ok, %{enqueued: [_job], skipped: []}} =
             DirectorySync.enqueue_directory_syncs()

    assert {:ok, %{enqueued: [], skipped: ["lark-main"]}} =
             DirectorySync.enqueue_directory_syncs()

    age_periodic_sync_jobs("lark-main", 3_700)

    assert {:ok, %{enqueued: [_job], skipped: []}} =
             DirectorySync.enqueue_directory_syncs()
  end

  test "every synced subject joins the provider-wide members group" do
    assert {:ok, observed} =
             Ankole.IdentityProviders.Directory.upsert_user("lark-main", %{
               provider: "lark-main",
               external_id: "ou_member_1",
               uid: "ou_member_1",
               display_name: "Member One"
             })

    group = Repo.get_by!(Ankole.AuthZ.Group, name: "lark-main:members:all")
    assert group.domain == :directory
    assert group.kind == :static

    assert Repo.get_by(Ankole.AuthZ.Membership,
             group_id: group.id,
             principal_uid: observed.principal.uid
           )
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
end
