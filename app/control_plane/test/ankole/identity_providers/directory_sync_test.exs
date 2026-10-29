defmodule Ankole.IdentityProviders.DirectorySyncTest do
  use Ankole.DataCase, async: false
  import ExUnit.CaptureLog

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.IdentityProviders.StartupSync

  import Ankole.IdentityProviderTestHelpers

  defmodule RaisingReconciler do
    def reconcile, do: raise(ArgumentError, "private-reconcile-request-credential")
  end

  defmodule ReportingReconciler do
    def reconcile do
      %{
        started: 0,
        stopped: 0,
        errors: [
          %{tenant_id: "tenant", reason: {:snapshot_failed, "private-reconcile-provider-content"}}
        ]
      }
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    :ok
  end

  test "a broken tenant cannot prevent another tenant's periodic directory sync", %{
    tenant: broken
  } do
    assert {:ok, _} =
             AppConfigure.put_tenant_by_key("principals.identity_providers.active", [
               %{
                 "provider_id" => "broken",
                 "adapter_id" => "missing-adapter",
                 "plugin_id" => "missing-plugin",
                 "config_key" => "principals.identity_providers.lark.broken",
                 "enabled" => true
               }
             ])

    healthy = create_tenant()

    Repo.with_tenant(healthy.id, fn ->
      assert {:ok, _} =
               IdentityProviders.save_provider(
                 "healthy",
                 "lark",
                 %{"appID" => "cli_healthy", "appSecret" => "secret"},
                 true
               )
    end)

    assert {:ok, %{errors: errors}} = perform_job(EnqueueDirectorySyncs, %{})
    assert Enum.any?(errors, &(&1.tenant_id == broken.id))
    assert_enqueued(worker: SyncProvider, args: %{provider_id: "healthy", tenant_id: healthy.id})
  end

  test "startup keeps each tenant's enqueue failure without logging its private cause", %{
    tenant: broken
  } do
    secret = "private-startup-provider-configuration"

    assert {:ok, _} =
             AppConfigure.put_tenant_by_key("principals.identity_providers.active", [
               %{
                 "provider_id" => "broken",
                 "adapter_id" => secret,
                 "plugin_id" => "missing-plugin",
                 "config_key" => "principals.identity_providers.lark.broken",
                 "enabled" => true
               }
             ])

    healthy = create_tenant()

    Repo.with_tenant(healthy.id, fn ->
      assert {:ok, _} =
               IdentityProviders.save_provider(
                 "healthy",
                 "lark",
                 %{"appID" => "cli_healthy", "appSecret" => "secret"},
                 true
               )
    end)

    {result, log} =
      with_log(
        [format: "$metadata$message\n", metadata: :all],
        fn -> StartupSync.enqueue() end
      )

    assert {:ok, %{errors: [%{tenant_id: broken_id, reason: reason}]}} = result
    assert broken_id == broken.id
    assert inspect(reason) =~ secret
    assert_enqueued(worker: SyncProvider, args: %{provider_id: "healthy", tenant_id: healthy.id})
    assert Repo.tenant_id!() == broken.id
    assert log =~ "event=tenants.site_fanout_failed"
    assert log =~ "failure=Elixir.ErlangError"
    refute log =~ secret
  end

  test "reconcile exceptions retain their result and log only the class and call site" do
    adapter = %{
      capabilities: ["directory_realtime_sync"],
      connection_reconciler: RaisingReconciler
    }

    {result, log} =
      with_log(
        [format: "$metadata$message\n", metadata: :all],
        fn ->
          DirectorySync.reconcile_saved_provider(adapter, %{}, true, reconcile_realtime?: true)
        end
      )

    assert {:ok, {:error, {:error, %ArgumentError{message: message}}}} = result
    assert message == "private-reconcile-request-credential"
    assert log =~ "event=identity_providers.realtime_reconcile.failed"
    assert log =~ "failure=Elixir.ArgumentError"
    assert log =~ "RaisingReconciler.reconcile/0"
    refute log =~ message
  end

  test "reconcile error summaries retain the original errors without logging provider content" do
    adapter = %{
      capabilities: ["directory_realtime_sync"],
      connection_reconciler: ReportingReconciler
    }

    {result, log} =
      with_log(
        [format: "$metadata$message\n", metadata: :all],
        fn ->
          DirectorySync.reconcile_saved_provider(adapter, %{}, true, reconcile_realtime?: true)
        end
      )

    assert result == {:ok, ReportingReconciler.reconcile()}
    assert log =~ "event=identity_providers.realtime_reconcile.completed_with_errors"
    assert log =~ "error_count=1"
    refute log =~ "private-reconcile-provider-content"
  end

  test "a provider without stored configuration fails its Oban run" do
    key = "principals.identity_providers.missing-sync-config"

    definition =
      AppConfigure.define(key: key, encrypted: true, schema: Ankole.AppConfigure.Schema.object())

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    provider = %{
      "provider_id" => "missing-sync-config",
      "adapter_id" => "lark",
      "plugin_id" => "lark-adapter",
      "config_key" => key,
      "enabled" => true
    }

    assert {:ok, _} =
             AppConfigure.put_tenant_by_key("principals.identity_providers.active", [provider])

    assert :error = IdentityProviders.provider_config(provider)

    assert_raise CaseClauseError, fn ->
      perform_job(SyncProvider, %{"provider_id" => provider["provider_id"]})
    end
  end

  test "directory full sync interval defaults to six hours and is operator configurable" do
    assert {:ok, 900} = IdentityProviderConfig.directory_full_sync_interval_seconds()

    assert {:ok, 2} =
             AppConfigure.put_global(
               IdentityProviderConfig.directory_full_sync_interval_minutes_definition(),
               2
             )

    assert {:ok, 120} = IdentityProviderConfig.directory_full_sync_interval_seconds()

    assert {:error, {:invalid_integer, "directory_full_sync_interval_minutes", %{min: 1}}} =
             AppConfigure.put_global(
               IdentityProviderConfig.directory_full_sync_interval_minutes_definition(),
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
               IdentityProviderConfig.directory_full_sync_interval_minutes_definition(),
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

  test "directory sync binds the attested address as an email identity and never steals one" do
    assert {:ok, synced} =
             Ankole.IdentityProviders.Directory.upsert_user("lark-main", %{
               provider: "lark-main",
               external_id: "ou_mail_1",
               display_name: "Mail One",
               email: "Mail.One@Corp.example"
             })

    assert {:ok, by_email} =
             Ankole.Principals.resolve_platform_subject("email", "mail.one@corp.example")

    assert by_email.uid == synced.principal.uid

    assert {:ok, _again} =
             Ankole.IdentityProviders.Directory.upsert_user("lark-main", %{
               provider: "lark-main",
               external_id: "ou_mail_1",
               email: "mail.one@corp.example"
             })

    %{principal: other} = Ankole.PrincipalsFixtures.human_fixture()

    assert {:ok, _identity} =
             Ankole.Principals.MappingRequests.bind_subject(other.uid, %{
               provider: "email",
               external_id: "claimed@corp.example"
             })

    assert {:ok, _second} =
             Ankole.IdentityProviders.Directory.upsert_user("lark-main", %{
               provider: "lark-main",
               external_id: "ou_mail_2",
               email: "claimed@corp.example"
             })

    assert {:ok, still_other} =
             Ankole.Principals.resolve_platform_subject("email", "claimed@corp.example")

    assert still_other.uid == other.uid
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
