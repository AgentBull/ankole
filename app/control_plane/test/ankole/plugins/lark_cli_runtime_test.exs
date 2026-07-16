defmodule Ankole.Plugins.LarkCLIRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL
  alias FeishuOpenAPI.Client
  alias FeishuOpenAPI.TokenStore
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.RuntimeEnv
  alias Ankole.Plugins.Registry, as: PluginsRegistry
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorRuntime.BindingWorkerEnv
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings

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
    def api_version, do: 1

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals_gateway.adapter",
          id: "failing-env",
          plugin_id: plugin_id(),
          worker_env_module: Ankole.Plugins.LarkCLIRuntimeTest.FailingWorkerEnv
        }
      ]
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_definitions(LarkAdapter.app_config_definitions())
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
      AppConfigureCache.clear_for_test()
    end)

    :ok
  end

  test "Lark binding credentials are scoped by agent and one app cannot back two agents" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    config = lark_config("cli_shared")

    assert {:ok, %{binding: binding, config_key: config_key}} =
             Bindings.put_binding(first_agent.uid, "lark", "lark-main", binding_attrs(config))

    assert config_key == Config.chat_config_key(first_agent.uid)
    assert binding.config_ref == "app-config://#{config_key}"
    assert {:ok, %{"appID" => "cli_shared"}} = Config.load_chat_config_ref(binding.config_ref)

    assert {:error, :lark_binding_already_exists} =
             Bindings.put_binding(first_agent.uid, "lark", "lark-other", binding_attrs(config))

    assert {:error, {:lark_app_already_bound, "cli_shared", first_agent_uid}} =
             Bindings.put_binding(second_agent.uid, "lark", "lark-main", binding_attrs(config))

    assert first_agent_uid == first_agent.uid
  end

  test "Lark binding assignment holds the adapter lock across validation and persistence" do
    %{principal: agent} = agent_fixture()
    lock_key = "signals_gateway:binding_assignment:lark"
    parent = self()

    task =
      Task.async(fn ->
        Repo.transact(fn repo ->
          SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key])
          send(parent, :assignment_lock_acquired)
          Process.sleep(200)
          {:ok, :released}
        end)
      end)

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

  test "a rolled-back binding config write is never published to the AppConfigure cache" do
    %{principal: agent} = agent_fixture()
    config_key = Config.chat_config_key(agent.uid)

    assert {:error, :forced_rollback} =
             Repo.transact(fn repo ->
               assert {:ok, _committed_write} =
                        AppConfigure.put_global_by_key_in_tx(
                          repo,
                          config_key,
                          lark_config("cli_rollback")
                        )

               assert :miss = AppConfigureCache.lookup("global", config_key)
               {:error, :forced_rollback}
             end)

    assert :error = AppConfigure.get_by_key(config_key)
  end

  test "worker env gives the trusted worker the binding app identity and tenant token" do
    %{principal: agent} = agent_fixture()
    config = lark_config("cli_worker")
    seed_tenant_token(config, "tenant-token")

    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(agent.uid, "lark", "lark-main", binding_attrs(config))

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

    assert {:ok, effective_env} = WorkerEnv.effective_env(agent.uid)
    assert effective_env["LARKSUITE_CLI_APP_ID"] == "cli_worker"
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_APP_SECRET")
    assert effective_env["LARKSUITE_CLI_TENANT_ACCESS_TOKEN"] == "tenant-token"

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "lark-worker-env",
                 "method" => "worker_env.resolve",
                 "payload_json" => %{
                   "request_id" => "lark-worker-env",
                   "agent_uid" => agent.uid
                 }
               },
               "trusted-worker-route"
             )

    rpc_vars = get_in(envelope, ["body", "rpc_response", "payload_json", "vars"])
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
             binding
             |> Binding.changeset(%{enabled: false})
             |> Repo.update()

    assert {:ok, effective_env} = WorkerEnv.effective_env(agent.uid)
    assert effective_env["LARKSUITE_CLI_APP_ID"] == "operator-override"
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_APP_SECRET")
    refute Map.has_key?(effective_env, "LARKSUITE_CLI_TENANT_ACCESS_TOKEN")
  end

  test "an available binding env failure is returned instead of silently omitting identity" do
    %{principal: agent} = agent_fixture()

    registry =
      start_supervised!(
        {PluginsRegistry,
         name: :failing_worker_env_registry,
         discovery: [paths: [], modules: [FailingWorkerEnvPlugin]]},
        id: :failing_worker_env_registry
      )

    assert is_pid(registry)

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "failing-main",
               adapter: "failing-env",
               config_ref: "app-config://failing-env",
               filters: %{},
               unaddressed_group_message_policy: :record_only,
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
      {PluginsRegistry, name: registry_name, discovery: [paths: [], modules: []]},
      id: registry_name
    )

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "disabled-main",
               adapter: "disabled-env",
               config_ref: "app-config://disabled-env",
               filters: %{},
               unaddressed_group_message_policy: :record_only,
               enabled: true
             })

    assert {:ok, %{}} =
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
      "platformSubjectNamespace" => "lark-main",
      "userName" => "Lark Bot"
    }
  end

  defp seed_tenant_token(config, token) do
    {:ok, normalized} = Config.validate_chat_config(config)
    cache_namespace = normalized |> Config.client() |> Client.cache_namespace()
    key = {:tenant, cache_namespace, nil}

    :ets.insert(TokenStore.table(), {key, token, :infinity})
    on_exit(fn -> :ets.delete(TokenStore.table(), key) end)
  end
end
