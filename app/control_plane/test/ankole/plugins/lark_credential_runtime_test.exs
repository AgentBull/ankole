defmodule Ankole.Plugins.LarkCredentialRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase,
    only: [
      handle_rpc: 3,
      rpc_request: 3,
      rpc_response_payload!: 2
    ]

  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Crypto, as: AppConfigureCrypto
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.Config, as: PluginsConfig
  alias Ankole.Plugins.Registry, as: PluginsRegistry
  alias Ankole.Repo

  alias Ankole.AgentWorkers.BindingWorkerEnv
  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings

  defmodule FailingWorkerEnv do
    @moduledoc false

    def resolve_worker_env(_binding), do: {:error, :credentials_unavailable}
  end

  defmodule FailingWorkerEnvPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "failing-worker-env"

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "failing-env",
          adapter_category: "enterprise_im",
          plugin_id: plugin_id(),
          worker_env_module: Ankole.Plugins.LarkCredentialRuntimeTest.FailingWorkerEnv
        }
      ]
    end
  end

  defmodule ReservedWorkerEnv do
    @moduledoc false
    def resolve_worker_env(_binding), do: {:ok, %{"PATH" => "/binding-owned/path"}}
  end

  defmodule ReservedWorkerEnvPlugin do
    @moduledoc false
    @behaviour Ankole.Plugins.Plugin
    @impl true
    def plugin_id, do: "reserved-worker-env"
    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "reserved-env",
          adapter_category: "enterprise_im",
          plugin_id: plugin_id(),
          worker_env_module: Ankole.Plugins.LarkCredentialRuntimeTest.ReservedWorkerEnv
        }
      ]
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()

    on_exit(fn ->
      # A saved Lark binding starts an asynchronous pass of the shared Lark
      # connection reconciler. Wait for the pass before the caches are cleared
      # and the sandbox owner stops, so that the pass cannot read the data of
      # a later test.
      :sys.get_state(ConnectionReconciler)
      AppConfigureRegistry.clear_for_test()
    end)

    :ok
  end

  test "one Agent can bind several Lark apps and each app has one enabled binding" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    first_config = lark_config("cli_first")
    second_config = lark_config("cli_second")

    assert {:ok, %{binding: first_binding, config_key: first_config_key}} =
             Bindings.put_binding(
               first_agent.uid,
               "lark",
               "lark-main",
               binding_attrs(first_config)
             )

    assert first_config_key == Config.binding_config_key(Repo.tenant_id!(), first_binding.id)
    assert first_binding.config_ref == "app-config://#{first_config_key}"

    assert {:ok, %{binding: second_binding, config_key: second_config_key}} =
             Bindings.put_binding(
               first_agent.uid,
               "lark",
               "lark-other",
               binding_attrs(second_config)
             )

    assert second_config_key == Config.binding_config_key(Repo.tenant_id!(), second_binding.id)
    refute second_config_key == first_config_key
    assert second_binding.config_ref == "app-config://#{second_config_key}"

    assert {:ok, %{"appID" => "cli_first"}} =
             Bindings.binding_config(first_binding, Config)

    assert {:ok, %{"appID" => "cli_second"}} =
             Bindings.binding_config(second_binding, Config)

    assert {:error,
            {:platform_application_already_bound, "lark:[\"feishu\",\"cli_first\"]",
             first_agent_uid, "lark-main"}} =
             Bindings.put_binding(
               first_agent.uid,
               "lark",
               "lark-duplicate",
               binding_attrs(first_config)
             )

    assert first_agent_uid == first_agent.uid

    assert {:error,
            {:platform_application_already_bound, "lark:[\"feishu\",\"cli_first\"]",
             first_agent_uid, "lark-main"}} =
             Bindings.put_binding(
               second_agent.uid,
               "lark",
               "lark-main",
               binding_attrs(first_config)
             )

    assert first_agent_uid == first_agent.uid

    assert {:ok, _disabled} =
             Bindings.disable_binding(
               Ankole.Signals.get_agent_binding!(first_agent.uid, "lark-main").id
             )

    assert {:ok, %{binding: %Binding{agent_uid: second_agent_uid}}} =
             Bindings.put_binding(
               second_agent.uid,
               "lark",
               "lark-main",
               binding_attrs(first_config)
             )

    assert second_agent_uid == second_agent.uid
  end

  test "the same app ID can identify separate Feishu and Lark applications" do
    %{principal: agent} = agent_fixture()
    feishu_config = lark_config("cli_shared_domain_id")
    lark_config = Map.put(feishu_config, "domain", "lark")

    assert {:ok, %{binding: %Binding{name: "feishu-main"}}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "feishu-main",
               binding_attrs(feishu_config)
             )

    assert {:ok, %{binding: %Binding{name: "lark-main"}}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-main",
               binding_attrs(lark_config)
             )
  end

  test "saving a legacy binding preserves its config and assigns a binding-owned key" do
    %{principal: agent} = agent_fixture()
    legacy_config = lark_config("cli_legacy")
    legacy_config_key = "signals.lark.bindings." <> agent.uid

    assert {:ok, _stored} = AppConfigure.put_global_by_key(legacy_config_key, legacy_config)

    assert {:ok, %Binding{} = original} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "lark-main",
               adapter: "lark",
               config_ref: "app-config://#{legacy_config_key}",
               filters: %{},
               unaddressed_group_message_policy: :ignore,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    binding_config_key = Config.binding_config_key(Repo.tenant_id!(), original.id)

    assert {:ok, %{binding: %Binding{} = binding, config_key: ^binding_config_key}} =
             Bindings.update_binding(
               Ankole.Signals.get_agent_binding!(agent.uid, "lark-main").id,
               %{
                 "agent_uid" => agent.uid,
                 "config" => %{"userName" => "Renamed Lark Bot"},
                 "group_message_mode" => "addressed_only"
               }
             )

    assert binding.config_ref == "app-config://#{binding_config_key}"

    assert {:ok, stored_config} = Bindings.binding_config(binding, Config)
    assert stored_config["appID"] == legacy_config["appID"]
    assert stored_config["appSecret"] == legacy_config["appSecret"]
    assert stored_config["userName"] == "Renamed Lark Bot"
  end

  test "a binding-owned key cannot overlap a legacy Agent-owned key" do
    %{principal: target_agent} = agent_fixture()
    binding = Ankole.SignalsFixtures.binding_fixture(target_agent.uid, "lark-main", :ignore)
    binding_config_key = Config.binding_config_key(Repo.tenant_id!(), binding.id)

    digest =
      [Repo.tenant_id!(), binding.id]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    legacy_agent_uid = "binding:#{digest}"
    insert_legacy_agent!(legacy_agent_uid)
    legacy_config_key = "signals.lark.bindings." <> legacy_agent_uid
    legacy_config = lark_config("cli_legacy_collision")
    target_config = lark_config("cli_target_collision")

    assert legacy_config_key == "signals.lark.bindings.binding:#{digest}"
    assert binding_config_key == "signals.lark.binding_configs.#{digest}"
    refute binding_config_key == legacy_config_key
    assert {:ok, _stored} = AppConfigure.put_global_by_key(legacy_config_key, legacy_config)

    assert {:ok, %Binding{}} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: legacy_agent_uid,
               name: "lark-main",
               adapter: "lark",
               config_ref: "app-config://#{legacy_config_key}",
               filters: %{},
               unaddressed_group_message_policy: :ignore,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    assert {:ok, %{binding: target_binding, config_key: ^binding_config_key}} =
             Bindings.put_binding(
               target_agent.uid,
               "lark",
               "lark-main",
               binding_attrs(target_config)
             )

    assert target_binding.config_ref == "app-config://#{binding_config_key}"

    assert {:ok, %{"appID" => "cli_legacy_collision"}} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{legacy_config_key}"},
               Config
             )

    assert {:ok, %{"appID" => "cli_target_collision"}} =
             Bindings.binding_config(target_binding, Config)
  end

  test "Lark binding assignment persists its shared credential before the binding reference" do
    %{principal: agent} = agent_fixture()
    handler_id = {:lark_application_lock, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ankole, :repo, :query],
        fn _event, _measurements, %{query: query, params: params}, _config ->
          send(parent, {:repo_query, query, params})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    config = lark_config("cli_serialized")
    {:ok, application} = Config.platform_application(config)

    assert {:ok, %{binding: %Binding{} = binding}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-main",
               binding_attrs(config)
             )

    queries = drain_repo_queries([])

    credential_index =
      Enum.find_index(queries, fn {query, _params} ->
        query =~ ~s(INTO "connector_auth_configs")
      end)

    persist_index =
      Enum.find_index(queries, fn {query, _params} ->
        query =~ ~s(INTO "signal_bindings")
      end)

    assert is_integer(credential_index)
    assert is_integer(persist_index)
    assert credential_index < persist_index
    assert {:ok, root} = Ankole.Connectors.get_auth_config(binding.auth_config_id, "lark")
    assert root.platform_application == application
  end

  defp drain_repo_queries(acc) do
    receive do
      {:repo_query, query, params} -> drain_repo_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "concurrent Lark binding saves validate app ownership from committed database state" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    shared_config = lark_config("cli_concurrent_shared")
    cache_pid = Process.whereis(AppConfigureCache)
    parent = self()

    assert {:ok, %{binding: %Binding{}, config_key: first_config_key}} =
             Bindings.put_binding(
               first_agent.uid,
               "lark",
               "lark-main",
               binding_attrs(lark_config("cli_concurrent_initial"))
             )

    assert {:ok, %{"appID" => "cli_concurrent_initial"}} =
             AppConfigure.get_by_key(first_config_key)

    assert {:ok, {:row, _envelope}} = AppConfigureCache.lookup("global", first_config_key)
    :ok = :sys.suspend(cache_pid)

    on_exit(fn ->
      if Process.alive?(cache_pid), do: :sys.resume(cache_pid)
    end)

    first_save =
      Task.async(
        Repo.bind_tenant(fn ->
          send(parent, {:ready, self()})
          receive do: (:save -> :ok)

          Bindings.put_binding(
            first_agent.uid,
            "lark",
            "lark-main",
            binding_attrs(shared_config)
          )
        end)
      )

    assert_receive {:ready, first_save_pid}, 1_000
    assert first_save_pid == first_save.pid
    :erlang.trace(first_save.pid, true, [:send])
    send(first_save.pid, :save)

    assert_receive {:trace, ^first_save_pid, :send,
                    {:"$gen_call", _from, {:refresh, "global", ^first_config_key, _}},
                    ^cache_pid},
                   1_000

    second_save =
      Task.async(
        Repo.bind_tenant(fn ->
          Bindings.put_binding(
            second_agent.uid,
            "lark",
            "lark-main",
            binding_attrs(shared_config)
          )
        end)
      )

    second_result = Task.yield(second_save, 500)
    :ok = :sys.resume(cache_pid)

    assert {:ok, %{binding: %Binding{agent_uid: first_agent_uid}}} = Task.await(first_save, 1_000)
    assert first_agent_uid == first_agent.uid

    second_result = second_result || {:ok, Task.await(second_save, 1_000)}

    assert {:ok,
            {:error,
             {:platform_application_already_bound, "lark:[\"feishu\",\"cli_concurrent_shared\"]",
              rejected_owner_uid, "lark-main"}}} =
             second_result

    assert rejected_owner_uid == first_agent.uid
    refute Repo.get_by(Binding, agent_uid: second_agent.uid, name: "lark-main")
  end

  test "Lark binding ownership fails closed when an enabled owner's config is unavailable" do
    %{principal: owner} = agent_fixture()
    %{principal: claimant} = agent_fixture()
    owner_config_key = "signals.lark.bindings." <> owner.uid
    claimed_config = lark_config("cli_claimed_while_owner_unknown")

    assert {:ok, %Binding{}} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: owner.uid,
               name: "lark-main",
               adapter: "lark",
               config_ref: "app-config://#{owner_config_key}",
               filters: %{},
               unaddressed_group_message_policy: :ignore,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    assert {:error, {:lark_binding_config_unavailable, owner_uid, "lark-main", :missing}} =
             Bindings.put_binding(
               claimant.uid,
               "lark",
               "lark-main",
               binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid

    put_raw_global_config(owner_config_key, %{"type" => "cipher", "value" => "invalid"})

    assert {:error,
            {:lark_binding_config_unavailable, owner_uid, "lark-main",
             {:storage_error, "global", ^owner_config_key, _decrypt_reason}}} =
             Bindings.put_binding(
               claimant.uid,
               "lark",
               "lark-main",
               binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid

    assert {:ok, invalid_config_ciphertext} =
             AppConfigureCrypto.seal(%{"appID" => "incomplete"}, "global", owner_config_key)

    put_raw_global_config(owner_config_key, %{
      "type" => "cipher",
      "value" => invalid_config_ciphertext
    })

    assert {:error,
            {:lark_binding_config_unavailable, owner_uid, "lark-main",
             {:storage_error, "global", ^owner_config_key, {:missing, "appSecret"}}}} =
             Bindings.put_binding(
               claimant.uid,
               "lark",
               "lark-main",
               binding_attrs(claimed_config)
             )

    assert owner_uid == owner.uid
    refute Repo.get_by(Binding, agent_uid: claimant.uid, name: "lark-main")
  end

  test "a rolled-back binding config write is never published to the AppConfigure cache" do
    config_key = Config.binding_config_key(Repo.tenant_id!(), Ecto.UUID.generate())

    assert {:error, :forced_rollback} =
             Repo.transact(fn ->
               assert {:ok, _committed_write} =
                        AppConfigure.put_global_by_key_in_tx(
                          config_key,
                          lark_config("cli_rollback")
                        )

               assert :miss = AppConfigureCache.lookup("global", config_key)
               {:error, :forced_rollback}
             end)

    assert :error = AppConfigure.get_by_key(config_key)
  end

  test "a cache refresh fault cannot turn a committed binding into failure or skip follow-up work" do
    %{principal: agent} = agent_fixture()
    binding = Ankole.SignalsFixtures.binding_fixture(agent.uid, "lark-main", :ignore)
    config_key = Config.binding_config_key(Repo.tenant_id!(), binding.id)

    # A read before the save puts the pre-save state in the cache.
    assert :error = AppConfigure.get_by_key(config_key)
    assert {:ok, :absent} = AppConfigureCache.lookup("global", config_key)

    assert :ok =
             AppConfigureCache.fail_next_refresh_for_test(
               "global",
               config_key,
               :injected_binding_refresh_failure
             )

    assert {:ok, %{binding: %Binding{} = binding}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-main",
               binding_attrs(lark_config("cli_after_commit"))
             )

    assert binding.agent_uid == agent.uid

    # The save also starts a Lark connection reconciliation. That reconciliation
    # can load the committed row into the cache at any time, so the cache can
    # hold the committed row or nothing. It must not keep the pre-save state.
    %SiteConfig{value: committed_envelope} =
      Repo.get_by!(SiteConfig, scope: "global", key: config_key)

    assert AppConfigureCache.lookup("global", config_key) in [
             :miss,
             {:ok, {:row, committed_envelope}}
           ]

    assert {:ok, %{"appID" => "cli_after_commit"}} =
             AppConfigure.get_by_key(config_key)

    assert_enqueued(
      worker: Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups,
      args: %{
        "binding_id" => binding.id,
        "reason" => "binding_saved",
        "source" => "signal_binding"
      }
    )
  end

  test "Lark bindings keep platform credentials out of the Worker environment" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _} = AgentPlugins.set_agent_override(agent.uid, "lark", true)

    for name <- ["primary", "secondary"] do
      assert {:ok, %{binding: %Binding{}}} =
               Bindings.put_binding(
                 agent.uid,
                 "lark",
                 name,
                 binding_attrs(lark_config("app_" <> name))
               )

      assert {:ok, env} = Ankole.SessionsCase.effective_worker_env(agent.uid, binding_name: name)
      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "LARKSUITE_CLI_"))
    end
  end

  test "an available binding env failure is returned instead of silently omitting identity" do
    %{principal: agent} = agent_fixture()

    assert {:ok, ["failing-worker-env"]} =
             PluginsConfig.put_enabled_ids([FailingWorkerEnvPlugin.plugin_id()])

    registry =
      start_supervised!(
        {PluginsRegistry, name: :failing_worker_env_registry, modules: [FailingWorkerEnvPlugin]},
        id: :failing_worker_env_registry
      )

    assert is_pid(registry)

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "failing-main",
               adapter: "failing-env",
               config_ref: "app-config://failing-env",
               filters: %{},
               unaddressed_group_message_policy: :record_only,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    assert {:error,
            {:binding_worker_env_unavailable, "failing-env", "failing-main",
             :credentials_unavailable}} =
             BindingWorkerEnv.resolve(agent.uid,
               adapter_server: :failing_worker_env_registry
             )
  end

  test "a residual binding for a disabled plugin does not block unrelated worker env" do
    %{principal: agent} = agent_fixture()
    registry_name = :"empty_worker_env_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {PluginsRegistry, name: registry_name, modules: []},
      id: registry_name
    )

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "disabled-main",
               adapter: "disabled-env",
               config_ref: "app-config://disabled-env",
               filters: %{},
               unaddressed_group_message_policy: :record_only,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    assert {:ok, %{}} =
             BindingWorkerEnv.resolve(agent.uid, adapter_server: registry_name)
  end

  test "a binding provider cannot replace the Worker PATH" do
    %{principal: agent} = agent_fixture()

    assert {:ok, ["reserved-worker-env"]} =
             PluginsConfig.put_enabled_ids([ReservedWorkerEnvPlugin.plugin_id()])

    registry_name = :reserved_worker_env_registry

    start_supervised!(
      {PluginsRegistry, name: registry_name, modules: [ReservedWorkerEnvPlugin]},
      id: registry_name
    )

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "reserved-main",
               adapter: "reserved-env",
               config_ref: "app-config://reserved-env",
               filters: %{},
               unaddressed_group_message_policy: :record_only,
               unmatched_sender_policy: :create_standalone,
               enabled: true
             })

    assert {:error, {:reserved_worker_env_name, "PATH"}} =
             BindingWorkerEnv.resolve(agent.uid, adapter_server: registry_name)
  end

  defp binding_attrs(config) do
    %{
      "config" => config,
      "group_message_mode" => "addressed_only"
    }
  end

  defp lark_config(app_id) do
    %{
      "appID" => app_id,
      "appSecret" => "app-secret",
      "domain" => "feishu",
      "userName" => "Lark Bot"
    }
  end

  defp put_raw_global_config(key, envelope) do
    SiteConfig
    |> where([row], row.scope == "global" and row.key == ^key)
    |> Repo.delete_all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [row]} =
      Repo.insert_all(
        SiteConfig,
        [
          %{
            scope: "global",
            key: key,
            value: envelope,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: true
      )

    row
  end

  defp insert_legacy_agent!(uid) do
    SQL.query!(
      Repo,
      """
      INSERT INTO principals (uid, tenant_id, type, status, display_name, inserted_at, updated_at)
      VALUES ($1, $2::text::uuid, 'agent', 'active', $1, NOW(), NOW())
      """,
      [uid, Repo.tenant_id!()]
    )

    %{principal: owner} = Ankole.PrincipalsFixtures.human_fixture()

    SQL.query!(Repo, "ALTER TABLE agents DROP CONSTRAINT agents_uid_agent_home_safe")

    SQL.query!(
      Repo,
      """
      INSERT INTO agents (uid, tenant_id, type, role, options, owner_principal_uid, inserted_at, updated_at)
      VALUES ($1, $3::text::uuid, 'ai_colleague', 'Legacy Agent', '{}'::jsonb, $2, NOW(), NOW())
      """,
      [uid, owner.uid, Repo.tenant_id!()]
    )

    SQL.query!(Repo, """
    ALTER TABLE agents
      ADD CONSTRAINT agents_uid_agent_home_safe
      CHECK (uid ~ '^[a-z0-9][a-z0-9._@+-]{0,95}$') NOT VALID
    """)
  end
end
