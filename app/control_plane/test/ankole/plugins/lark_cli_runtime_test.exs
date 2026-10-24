defmodule Ankole.Plugins.LarkCLIRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase,
    only: [
      handle_rpc: 3,
      rpc_request: 3,
      rpc_response_payload!: 2
    ]

  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL
  alias FeishuOpenAPI.Client
  alias FeishuOpenAPI.TokenStore
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Crypto, as: AppConfigureCrypto
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.RuntimeEnv
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
          worker_env_module: Ankole.Plugins.LarkCLIRuntimeTest.FailingWorkerEnv
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
          worker_env_module: Ankole.Plugins.LarkCLIRuntimeTest.ReservedWorkerEnv
        }
      ]
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()

    on_exit(fn ->
      # A saved Lark binding starts an asynchronous pass of the shared Lark
      # connection reconciler. Wait for the pass before the caches are cleared
      # and the sandbox owner stops, so that the pass cannot read the data of
      # a later test.
      :sys.get_state(ConnectionReconciler)
      AppConfigureRegistry.clear_for_test()
      AppConfigureCache.clear_for_test()
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

    assert first_config_key == Config.binding_config_key(first_agent.uid, "lark-main")
    assert first_binding.config_ref == "app-config://#{first_config_key}"

    assert {:ok, %{binding: second_binding, config_key: second_config_key}} =
             Bindings.put_binding(
               first_agent.uid,
               "lark",
               "lark-other",
               binding_attrs(second_config)
             )

    assert second_config_key == Config.binding_config_key(first_agent.uid, "lark-other")
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

    assert {:ok, _disabled} = Bindings.disable_binding(first_agent.uid, "lark-main")

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
    binding_config_key = Config.binding_config_key(agent.uid, "lark-main")

    assert {:ok, _stored} = AppConfigure.put_global_by_key(legacy_config_key, legacy_config)

    assert {:ok, %Binding{}} =
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

    assert {:ok, %{binding: %Binding{} = binding, config_key: ^binding_config_key}} =
             Bindings.update_binding(agent.uid, agent.uid, "lark-main", %{
               "config" => %{"userName" => "Renamed Lark Bot"},
               "group_message_mode" => "addressed_only"
             })

    assert binding.config_ref == "app-config://#{binding_config_key}"

    assert {:ok, stored_config} = Bindings.binding_config(binding, Config)
    assert stored_config["appID"] == legacy_config["appID"]
    assert stored_config["appSecret"] == legacy_config["appSecret"]
    assert stored_config["userName"] == "Renamed Lark Bot"
  end

  test "a binding-owned key cannot overlap a legacy Agent-owned key" do
    %{principal: target_agent} = agent_fixture()
    binding_config_key = Config.binding_config_key(target_agent.uid, "lark-main")

    digest =
      [target_agent.uid, "lark-main"]
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

  test "Lark binding assignment holds the adapter lock across validation and persistence" do
    %{principal: agent} = agent_fixture()
    lock_key = "signals_gateway:binding_assignment:lark"
    parent = self()

    task =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn repo ->
            SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key])
            send(parent, :assignment_lock_acquired)
            Process.sleep(200)
            {:ok, :released}
          end)
        end)
      )

    assert_receive :assignment_lock_acquired, 1_000
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{binding: %Binding{}}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-main",
               binding_attrs(lark_config("cli_serialized"))
             )

    assert System.monotonic_time(:millisecond) - started_at >= 150
    assert {:ok, :released} = Task.await(task, 1_000)
  end

  test "concurrent Lark binding saves validate app ownership from committed database state" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    shared_config = lark_config("cli_concurrent_shared")
    first_config_key = Config.binding_config_key(first_agent.uid, "lark-main")
    cache_pid = Process.whereis(AppConfigureCache)
    parent = self()

    assert {:ok, %{binding: %Binding{}}} =
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
    %{principal: agent} = agent_fixture()
    config_key = Config.binding_config_key(agent.uid, "lark-main")

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
    config_key = Config.binding_config_key(agent.uid, "lark-main")

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
        "agent_uid" => agent.uid,
        "binding_name" => "lark-main",
        "reason" => "binding_saved",
        "source" => "signal_binding"
      }
    )
  end

  test "WorkerEnv selects Lark credentials from the current signal binding" do
    %{principal: agent} = agent_fixture()
    primary_config = lark_config("cli_primary")
    secondary_config = lark_config("cli_secondary")
    seed_tenant_token(primary_config, "primary-token")
    seed_tenant_token(secondary_config, "secondary-token")

    assert {:ok, _override} = AgentPlugins.set_agent_override(agent.uid, "lark", true)

    assert {:ok, %{binding: %Binding{}}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-primary",
               binding_attrs(primary_config)
             )

    assert {:ok, %{binding: %Binding{}}} =
             Bindings.put_binding(
               agent.uid,
               "lark",
               "lark-secondary",
               binding_attrs(secondary_config)
             )

    assert {:ok, primary_env} =
             Ankole.SessionsCase.effective_worker_env(agent.uid, binding_name: "lark-primary")

    assert primary_env["LARKSUITE_CLI_APP_ID"] == "cli_primary"
    assert primary_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "primary-token"

    assert {:ok, secondary_env} =
             Ankole.SessionsCase.effective_worker_env(agent.uid, binding_name: "lark-secondary")

    assert secondary_env["LARKSUITE_CLI_APP_ID"] == "cli_secondary"
    assert secondary_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "secondary-token"

    for opts <- [[], [binding_name: "unrelated-route"]] do
      assert {:ok, ambiguous_env} = Ankole.SessionsCase.effective_worker_env(agent.uid, opts)
      refute Map.has_key?(ambiguous_env, "LARKSUITE_CLI_APP_ID")
      refute Map.has_key?(ambiguous_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")
    end

    assert {:ok, envelope} =
             handle_rpc(
               rpc_request(
                 "lark-worker-env-secondary",
                 "worker_env.resolve",
                 %Ankole.RuntimeFabric.V1.WorkerEnvResolveRequest{
                   binding_name: "lark-secondary"
                 }
               ),
               "trusted-worker-route",
               agent.uid
             )

    rpc_vars =
      rpc_response_payload!(envelope, Ankole.RuntimeFabric.V1.WorkerEnvResolveResponse).vars

    assert rpc_vars["LARKSUITE_CLI_APP_ID"] == "cli_secondary"
    assert rpc_vars["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "secondary-token"

    assert {:ok, _disabled} = Bindings.disable_binding(agent.uid, "lark-primary")

    assert {:ok, disabled_route_env} =
             Ankole.SessionsCase.effective_worker_env(agent.uid, binding_name: "lark-primary")

    refute Map.has_key?(disabled_route_env, "LARKSUITE_CLI_APP_ID")
    refute Map.has_key?(disabled_route_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")

    assert {:ok, disabled_route_envelope} =
             handle_rpc(
               rpc_request(
                 "lark-worker-env-disabled-route",
                 "worker_env.resolve",
                 %Ankole.RuntimeFabric.V1.WorkerEnvResolveRequest{
                   binding_name: "lark-primary"
                 }
               ),
               "trusted-worker-route",
               agent.uid
             )

    disabled_route_vars =
      rpc_response_payload!(
        disabled_route_envelope,
        Ankole.RuntimeFabric.V1.WorkerEnvResolveResponse
      ).vars

    refute Map.has_key?(disabled_route_vars, "LARKSUITE_CLI_APP_ID")
    refute Map.has_key?(disabled_route_vars, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")

    assert {:ok, implicit_env} = Ankole.SessionsCase.effective_worker_env(agent.uid)
    assert implicit_env["LARKSUITE_CLI_APP_ID"] == "cli_secondary"
    assert implicit_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "secondary-token"

    assert {:ok, unknown_route_env} =
             Ankole.SessionsCase.effective_worker_env(agent.uid,
               binding_name: "control-plane-route"
             )

    assert unknown_route_env["LARKSUITE_CLI_APP_ID"] == "cli_secondary"
    assert unknown_route_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "secondary-token"

    disabled_primary = Repo.get_by!(Binding, agent_uid: agent.uid, name: "lark-primary")

    assert {:ok, _unavailable} =
             Ankole.SignalsFixtures.raw_binding_fixture(disabled_primary, %{
               enabled: true,
               unavailable_reason: "credentials revoked"
             })

    assert {:ok, unavailable_route_env} =
             Ankole.SessionsCase.effective_worker_env(agent.uid, binding_name: "lark-primary")

    refute Map.has_key?(unavailable_route_env, "LARKSUITE_CLI_APP_ID")
    refute Map.has_key?(unavailable_route_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")
  end

  test "Lark Agent Plugin enablement gates the binding identity and tenant token" do
    %{principal: agent} = agent_fixture()
    config = lark_config("cli_worker")
    seed_tenant_token(config, "tenant-token")

    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(agent.uid, "lark", "lark-main", binding_attrs(config))

    assert {:ok, %{}} = RuntimeEnv.resolve_worker_env(binding)

    assert {:ok, effective_env} = Ankole.SessionsCase.effective_worker_env(agent.uid)
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_APP_ID")
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")

    assert {:ok, _override} = AgentPlugins.set_agent_override(agent.uid, "lark", true)

    assert {:ok, %{"agent_plugins" => catalog}} = Library.runtime_catalog_for_agent(agent.uid)
    assert %{"skills" => lark_skills} = Enum.find(catalog, &(&1["id"] == "lark"))

    # LarkSkillSourcesTest owns the member Skill list. Enablement is what this test proves.
    assert lark_skills != []

    assert {:ok, env} = RuntimeEnv.resolve_worker_env(binding)
    assert env["LARKSUITE_CLI_APP_ID"] == "cli_worker"
    refute Map.has_key?(env, "LARKSUITE_CLI_APP_SECRET")
    assert env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "tenant-token"
    assert env["LARKSUITE_CLI_BRAND"] == "feishu"
    assert env["LARKSUITE_CLI_DEFAULT_AS"] == "bot"
    assert env["LARKSUITE_CLI_STRICT_MODE"] == "bot"

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent.uid, "LARKSUITE_CLI_APP_ID", %{
               "value" => "operator-override"
             })

    assert {:ok, effective_env} = Ankole.SessionsCase.effective_worker_env(agent.uid)
    assert effective_env["LARKSUITE_CLI_APP_ID"] == "cli_worker"
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_APP_SECRET")
    assert effective_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "tenant-token"

    assert {:ok, envelope} =
             handle_rpc(
               rpc_request(
                 "lark-worker-env",
                 "worker_env.resolve",
                 %Ankole.RuntimeFabric.V1.WorkerEnvResolveRequest{}
               ),
               "trusted-worker-route",
               agent.uid
             )

    rpc_vars =
      rpc_response_payload!(envelope, Ankole.RuntimeFabric.V1.WorkerEnvResolveResponse).vars

    assert rpc_vars["LARKSUITE_CLI_APP_ID"] == "cli_worker"
    refute Map.has_key?(rpc_vars, "LARKSUITE_CLI_APP_SECRET")
    assert rpc_vars["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "tenant-token"

    assert {:ok, console_items} = WorkerEnv.console_list_for_agent(agent.uid)

    refute Enum.any?(
             console_items,
             &(&1.name == "LARKSUITE_CLI_APP_SECRET")
           )

    refute Enum.any?(
             console_items,
             &(&1.name == "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")
           )

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(binding, %{enabled: false})

    assert {:ok, effective_env} = Ankole.SessionsCase.effective_worker_env(agent.uid)
    assert effective_env["LARKSUITE_CLI_APP_ID"] == "operator-override"
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_APP_SECRET")
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")
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
      INSERT INTO agents (uid, tenant_id, handle, type, role, options, owner_principal_uid, inserted_at, updated_at)
      VALUES ($1, $3::text::uuid, $4, 'ai_colleague', 'Legacy Agent', '{}'::jsonb, $2, NOW(), NOW())
      """,
      [uid, owner.uid, Repo.tenant_id!(), "legacy-" <> Ecto.UUID.generate()]
    )

    SQL.query!(Repo, """
    ALTER TABLE agents
      ADD CONSTRAINT agents_uid_agent_home_safe
      CHECK (uid ~ '^[a-z0-9][a-z0-9._-]{0,95}$') NOT VALID
    """)
  end

  defp seed_tenant_token(config, token) do
    {:ok, normalized} = Config.validate_chat_config(config)
    cache_namespace = normalized |> Config.client() |> Client.cache_namespace()
    key = {:tenant, cache_namespace, nil}

    :ets.insert(TokenStore.table(), {key, token, :infinity})
    on_exit(fn -> :ets.delete(TokenStore.table(), key) end)
  end
end
