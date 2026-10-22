defmodule Ankole.AgentWorkers.WorkerEnvTest do
  use Ankole.AIGatewayCase

  import Ankole.SessionsCase,
    only: [
      handle_rpc: 3,
      rpc_request: 3,
      rpc_response_payload!: 2,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AppConfigure.Registry
  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.AgentWorkers.WorkerEnv.{EnvVar, SiteEnvVar}

  require Ash.Query

  setup do
    on_exit(fn -> Registry.clear_for_test() end)
    unique = System.unique_integer([:positive])
    {:ok, unique: unique, env_name: "WORKER_ENV_TEST_#{unique}"}
  end

  test "resource actions preserve secret state, exact bytes, and natural identity", %{
    env_name: name
  } do
    value = "  secret bytes\n"

    assert {:ok, original} =
             Ankole.Ash.create(SiteEnvVar, :put, %{
               scope: "global",
               name: name,
               input: %{"value" => value, "secret" => true}
             })

    refute original.value == value
    refute inspect(original) =~ value

    assert {:ok, edited} =
             Ankole.Ash.create(SiteEnvVar, :put, %{
               scope: "global",
               name: name,
               input: %{"description" => "metadata only"}
             })

    assert edited.value == original.value
    assert edited.secret
    assert {:ok, ^value} = WorkerEnv.console_decrypt_global(name)

    assert {:ok, exposed} =
             Ankole.Ash.create(SiteEnvVar, :put, %{
               scope: "global",
               name: name,
               input: %{"secret" => false}
             })

    assert exposed.value == value
    refute exposed.secret
    assert {:error, :not_encrypted} = WorkerEnv.console_decrypt_global(name)
    assert [%{name: ^name}] = SiteEnvVar |> Ash.Query.filter(name == ^name) |> Ankole.Ash.read!()
  end

  test "tenant overrides reseal inherited secrets and enforce the process scope", %{
    env_name: name
  } do
    tenant = Ankole.Repo.tenant_id!()

    assert {:ok, site} =
             Ankole.Ash.create(SiteEnvVar, :put, %{
               scope: "global",
               name: name,
               input: %{"value" => "inherited secret", "secret" => true}
             })

    assert {:ok, overridden} =
             Ankole.Ash.create(EnvVar, :put, %{
               scope: "tenant:" <> tenant,
               name: name,
               input: %{"description" => "tenant metadata"}
             })

    assert overridden.secret
    refute overridden.value == site.value
    assert {:ok, "inherited secret"} = WorkerEnv.console_decrypt_tenant(name)
    assert {:ok, "inherited secret"} = WorkerEnv.console_decrypt_global(name)

    assert {:error, %Ash.Error.Invalid{}} =
             Ankole.Ash.create(EnvVar, :put, %{
               scope: "tenant:" <> Ankole.Ecto.UUIDv7.autogenerate(),
               name: name,
               input: %{"value" => "wrong scope"}
             })

    assert {:error, {:reserved_worker_env_name, "ANKOLE_OWNED"}} =
             Ankole.Ash.create(EnvVar, :put, %{
               scope: "tenant:" <> tenant,
               name: "ANKOLE_OWNED",
               input: %{"value" => "reserved"}
             })
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
             handle_rpc(
               rpc_request(
                 "worker-env-1",
                 "worker_env.resolve",
                 %FabricProto.WorkerEnvResolveRequest{}
               ),
               "trusted-worker-route",
               agent.uid
             )

    response = rpc_response_payload!(envelope, FabricProto.WorkerEnvResolveResponse)
    assert envelope_body!(envelope, :rpc_response).request_id == "worker-env-1"
    assert response.vars[plain] == "plain-value"
    assert response.vars[secret] == "rpc-secret"
  end

  test "RuntimeFabric worker_env.resolve rejects an unknown Agent" do
    assert {:ok, envelope} =
             handle_rpc(
               rpc_request(
                 "worker-env-missing-agent",
                 "worker_env.resolve",
                 %FabricProto.WorkerEnvResolveRequest{}
               ),
               "trusted-worker-route",
               "agent-missing"
             )

    assert envelope_body_type(envelope) == :rpc_error
  end
end
