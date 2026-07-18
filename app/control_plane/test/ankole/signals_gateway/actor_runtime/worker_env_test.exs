defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnvTest do
  use Ankole.AIGatewayCase

  import Ankole.SignalsGateway.ActorRuntimeCase,
    only: [
      rpc_request: 3,
      rpc_request: 4,
      rpc_response_payload!: 2,
      rpc_error_payload!: 1,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  import Ecto.Query

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv.EnvVar

  setup do
    allow_cache_database_access()
    # Test-registered declared exports must not leak into other modules: the
    # registry is a global process, and production paths re-register lazily.
    on_exit(fn -> Registry.clear_for_test() end)
    unique = System.unique_integer([:positive])
    {:ok, unique: unique, env_name: "WORKER_ENV_TEST_#{unique}"}
  end

  test "custom variables merge global under agent and decrypt secrets", %{unique: unique} do
    %{principal: agent} = agent_fixture()
    plain = "PLAIN_#{unique}"
    secret = "SECRET_#{unique}"
    shared = "SHARED_#{unique}"

    assert {:ok, _item} = WorkerEnv.console_put_global(plain, %{"value" => "global-plain"})

    assert {:ok, _item} =
             WorkerEnv.console_put_global(secret, %{"value" => "s3cret", "secret" => true})

    assert {:ok, _item} = WorkerEnv.console_put_global(shared, %{"value" => "from-global"})

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent.uid, shared, %{"value" => "from-agent"})

    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    assert env[plain] == "global-plain"
    assert env[secret] == "s3cret"
    assert env[shared] == "from-agent"

    other = agent_fixture()
    assert {:ok, other_env} = WorkerEnv.effective_env(other.principal.uid)
    assert other_env[shared] == "from-global"
  end

  test "secret rows store ciphertext, hide values, and reveal on demand", %{unique: unique} do
    %{principal: agent} = agent_fixture()
    name = "SECRET_AT_REST_#{unique}"

    assert {:ok, item} =
             WorkerEnv.console_put_global(name, %{"value" => "hunter2", "secret" => true})

    assert item.secret == true
    refute Map.has_key?(item, :value)

    row = Repo.one!(from row in EnvVar, where: row.scope == "global" and row.name == ^name)
    assert row.secret
    refute row.value =~ "hunter2"
    ciphertext = row.value

    assert {:ok, "hunter2"} = WorkerEnv.console_decrypt_global(name)
    assert {:ok, "hunter2"} = WorkerEnv.console_decrypt_for_agent(agent.uid, name)

    assert {:ok, preserved} =
             WorkerEnv.console_put_global(name, %{"description" => "kept without revealing"})

    assert preserved.secret == true
    refute Map.has_key?(preserved, :value)

    preserved_row =
      Repo.one!(from row in EnvVar, where: row.scope == "global" and row.name == ^name)

    assert preserved_row.value == ciphertext
    assert preserved_row.description == "kept without revealing"
    assert {:ok, "hunter2"} = WorkerEnv.console_decrypt_global(name)

    assert {:ok, exposed_without_retyping} =
             WorkerEnv.console_put_global(name, %{"secret" => false})

    assert exposed_without_retyping.secret == false
    assert exposed_without_retyping.value == "hunter2"

    assert {:ok, resealed_without_retyping} =
             WorkerEnv.console_put_global(name, %{"secret" => true})

    assert resealed_without_retyping.secret == true
    refute Map.has_key?(resealed_without_retyping, :value)
    assert {:ok, "hunter2"} = WorkerEnv.console_decrypt_global(name)

    # An absent secret flag keeps the stored state: the row stays sealed.
    assert {:ok, still_secret} = WorkerEnv.console_put_global(name, %{"value" => "visible"})
    assert still_secret.secret == true
    assert {:ok, "visible"} = WorkerEnv.console_decrypt_global(name)

    assert {:ok, exposed} =
             WorkerEnv.console_put_global(name, %{"value" => "visible", "secret" => false})

    assert exposed.value == "visible"
    assert {:error, :not_encrypted} = WorkerEnv.console_decrypt_global(name)
  end

  test "reserved and malformed names are rejected at every write surface" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:reserved_worker_env_name, "PATH"}} =
             WorkerEnv.console_put_global("PATH", %{"value" => "/tmp"})

    assert {:error, {:reserved_worker_env_name, "ANKOLE_AGENT_UID"}} =
             WorkerEnv.console_put_for_agent(agent.uid, "ANKOLE_AGENT_UID", %{"value" => "x"})

    assert {:error, {:invalid_worker_env_name, "1BAD"}} =
             WorkerEnv.console_put_global("1BAD", %{"value" => "x"})

    assert {:error, {:invalid_worker_env_name, "BAD-NAME"}} =
             WorkerEnv.console_put_global("BAD-NAME", %{"value" => "x"})

    assert {:error, :invalid_worker_env_value} =
             WorkerEnv.console_put_global("OK_NAME", %{"value" => 42})
  end

  test "declared definitions export through AppConfigure with agent overrides", %{
    unique: unique,
    env_name: env_name
  } do
    %{principal: agent} = agent_fixture()

    definition =
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.token",
        encrypted: true,
        schema: Schema.string(),
        description: "Test declared export",
        worker_env_name: env_name
      )

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    refute Map.has_key?(env, env_name)

    assert {:ok, item} = WorkerEnv.console_put_global(env_name, %{"value" => "declared-global"})
    assert item.kind == "declared"
    assert item.declared_key == definition.key

    assert {:ok, preserved} = WorkerEnv.console_put_global(env_name, %{})
    assert preserved.secret == true
    assert preserved.source == "global"
    assert {:ok, "declared-global"} = WorkerEnv.console_decrypt_global(env_name)

    assert {:error, :invalid_worker_env_value} =
             WorkerEnv.console_put_for_agent(agent.uid, env_name, %{})

    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    assert env[env_name] == "declared-global"

    assert {:ok, agent_item} =
             WorkerEnv.console_put_for_agent(agent.uid, env_name, %{"value" => "declared-agent"})

    assert agent_item.source == "agent"

    assert {:ok, preserved_agent_item} =
             WorkerEnv.console_put_for_agent(agent.uid, env_name, %{})

    assert preserved_agent_item.source == "agent"
    assert {:ok, "declared-agent"} = WorkerEnv.console_decrypt_for_agent(agent.uid, env_name)

    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    assert env[env_name] == "declared-agent"

    assert {:ok, "declared-agent"} = WorkerEnv.console_decrypt_for_agent(agent.uid, env_name)

    assert {:ok, _item} = WorkerEnv.console_delete_for_agent(agent.uid, env_name)
    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    assert env[env_name] == "declared-global"
  end

  test "declared names cannot collide across definitions or export reserved names", %{
    unique: unique,
    env_name: env_name
  } do
    definition =
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.first",
        encrypted: false,
        schema: Schema.string(),
        worker_env_name: env_name
      )

    duplicate =
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.second",
        encrypted: false,
        schema: Schema.string(),
        worker_env_name: env_name
      )

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:error, {:duplicate_worker_env_name, ^env_name}} =
             AppConfigure.register_definitions([duplicate])

    assert_raise ArgumentError, ~r/invalid_worker_env_name/, fn ->
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.bad",
        encrypted: false,
        schema: Schema.string(),
        worker_env_name: "not a name"
      )
    end

    %{principal: agent} = agent_fixture()

    reserved =
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.reserved",
        encrypted: false,
        schema: Schema.string(),
        default_value: "boom",
        worker_env_name: "DATABASE_URL"
      )

    assert :ok = AppConfigure.register_definitions([reserved])

    assert {:error, {:reserved_worker_env_name, "DATABASE_URL"}} =
             WorkerEnv.effective_env(agent.uid)
  end

  test "console list and detail carry provenance for both tracks", %{
    unique: unique,
    env_name: env_name
  } do
    %{principal: agent} = agent_fixture()
    custom = "CUSTOM_LIST_#{unique}"

    definition =
      AppConfigure.define(
        key: "__test.worker_env.#{unique}.listed",
        encrypted: false,
        schema: Schema.string(),
        default_value: "from-default",
        worker_env_name: env_name
      )

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent.uid, custom, %{"value" => "agent-only"})

    assert {:ok, global_items} = WorkerEnv.console_list_global()
    declared_item = Enum.find(global_items, &(&1.name == env_name))
    assert %{kind: "declared", source: "default", value: "from-default"} = declared_item
    refute Enum.any?(global_items, &(&1.name == custom))

    assert {:ok, agent_items} = WorkerEnv.console_list_for_agent(agent.uid)

    assert %{kind: "custom", source: "agent", value: "agent-only"} =
             Enum.find(agent_items, &(&1.name == custom))

    assert %{kind: "declared", source: "default"} =
             Enum.find(agent_items, &(&1.name == env_name))

    assert {:ok, %{source: "agent"}} = WorkerEnv.console_detail_for_agent(agent.uid, custom)
    assert {:error, :not_found} = WorkerEnv.console_detail_global(custom)
    assert {:error, :not_found} = WorkerEnv.console_detail_global("MISSING_#{unique}")
  end

  test "deleting the agent tier keeps the global tier effective", %{unique: unique} do
    %{principal: agent} = agent_fixture()
    name = "TIERED_#{unique}"

    assert {:ok, _item} = WorkerEnv.console_put_global(name, %{"value" => "global"})
    assert {:ok, _item} = WorkerEnv.console_put_for_agent(agent.uid, name, %{"value" => "mine"})

    assert {:ok, item} = WorkerEnv.console_delete_for_agent(agent.uid, name)
    assert item.source == "global"
    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    assert env[name] == "global"

    assert {:error, :not_found} = WorkerEnv.console_delete_for_agent(agent.uid, name)

    assert {:ok, deleted} = WorkerEnv.console_delete_global(name)
    assert deleted.present == false
    assert {:ok, env} = WorkerEnv.effective_env(agent.uid)
    refute Map.has_key?(env, name)
  end

  test "RuntimeFabric worker_env.resolve returns the merged decrypted environment", %{
    unique: unique
  } do
    %{principal: agent} = agent_fixture()
    plain = "RPC_PLAIN_#{unique}"
    secret = "RPC_SECRET_#{unique}"

    assert {:ok, _item} = WorkerEnv.console_put_global(plain, %{"value" => "plain-value"})

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent.uid, secret, %{
               "value" => "rpc-secret",
               "secret" => true
             })

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "worker-env-1",
                 "worker_env.resolve",
                 %FabricProto.WorkerEnvResolveRequest{},
                 agent_uid: agent.uid
               ),
               "trusted-worker-route"
             )

    response = rpc_response_payload!(envelope, FabricProto.WorkerEnvResolveResponse)
    assert envelope_body!(envelope, :rpc_response).request_id == "worker-env-1"
    assert response.vars[plain] == "plain-value"
    assert response.vars[secret] == "rpc-secret"
  end

  test "RuntimeFabric worker_env.resolve rejects unknown agents and bad payloads" do
    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "worker-env-missing-agent",
                 "worker_env.resolve",
                 %FabricProto.WorkerEnvResolveRequest{},
                 agent_uid: "agent-missing"
               ),
               "trusted-worker-route"
             )

    assert envelope_body_type(envelope) == :rpc_error

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "worker-env-invalid",
                 "worker_env.resolve",
                 %FabricProto.WorkerEnvResolveRequest{}
               ),
               "trusted-worker-route"
             )

    assert envelope_body_type(envelope) == :rpc_error
    assert envelope_body!(envelope, :rpc_error).code == "missing_agent_uid"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
