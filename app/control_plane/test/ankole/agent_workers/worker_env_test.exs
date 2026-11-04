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

  test "MCP Skill bearer credentials stay in the control plane", %{unique: unique} do
    %{principal: agent} = agent_fixture()
    name = "MCP_SECRET_#{unique}"

    {:ok, _} =
      WorkerEnv.console_put_for_agent(agent.uid, name, %{
        "value" => "upstream-only",
        "secret" => false
      })

    yaml =
      "dependencies:\n  tools:\n    - type: mcp\n      value: protected\n      transport: streamable_http\n      url: https://example.com/mcp\n      bearer_token_env_var: #{name}\n"

    {:ok, blob} = Ankole.Files.store(yaml)

    {:ok, _} =
      Ankole.Files.commit(agent.uid, [
        Map.merge(blob, %{path: "mcp/credential-test", source: "agent"})
      ])

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, skill} <-
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.Skill, :create, %{
                 slug: "credential-test",
                 name: "credential-test",
                 description: "fixture",
                 source_kind: :custom,
                 enabled_for_all: true,
                 manifest_xml: "<p>fixture</p>",
                 manifest_markdown: "fixture"
               }),
             do:
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.SkillFile, :put, %{
                 skill_id: skill.id,
                 relative_path: "agents/openai.yaml",
                 object_id: blob.object_id,
                 content_type: "application/yaml"
               })
      end)

    assert {:ok, %{vars: vars, operator_vars: operator}} =
             Ankole.AgentWorkers.WorkerEnvBroker.handle_request(
               agent.uid,
               %FabricProto.WorkerEnvResolveRequest{},
               %{turn_ref: nil, request_id: "env-secret"}
             )

    refute Map.has_key?(vars, name)
    refute Map.has_key?(operator, name)

    assert {:ok, snapshot} = WorkerEnv.runtime_projection(agent.uid)
    refute name in snapshot["names"]
    refute Map.has_key?(snapshot["plain_values"], name)

    assert {:ok, cleaned} =
             WorkerEnv.filter_runtime_projection(%{
               "names" => [name, "ORDINARY"],
               "plain_values" => %{
                 name => "historical-upstream-token",
                 "ORDINARY" => "frozen-value"
               }
             })

    assert cleaned == %{
             "names" => ["ORDINARY"],
             "plain_values" => %{"ORDINARY" => "frozen-value"}
           }

    assert {:ok, %{"headers" => [{"authorization", "Bearer upstream-only"}]}} =
             Ankole.AIAgent.resolve_mcp_server(agent, "credential-test", "protected")
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

  test "malformed unrelated MCP metadata does not block Worker environment renewal" do
    %{principal: agent} = agent_fixture()
    {:ok, blob} = Ankole.Files.store("dependencies: [unterminated")

    {:ok, _} =
      Ankole.Files.commit(agent.uid, [
        Map.merge(blob, %{path: "fixtures/broken-mcp", source: "agent"})
      ])

    {:ok, skill} =
      Repo.transact_top_level(fn ->
        with {:ok, skill} <-
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.Skill, :create, %{
                 slug: "broken-mcp",
                 name: "broken-mcp",
                 description: "invalid fixture",
                 source_kind: :custom,
                 enabled_for_all: false,
                 manifest_xml: "<p>fixture</p>",
                 manifest_markdown: "fixture"
               }),
             {:ok, _} <-
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.SkillFile, :put, %{
                 skill_id: skill.id,
                 relative_path: "agents/openai.yaml",
                 object_id: blob.object_id,
                 content_type: "application/yaml"
               }),
             do: {:ok, skill}
      end)

    assert {:ok, _} =
             Ankole.AgentWorkers.WorkerEnvBroker.handle_request(
               agent.uid,
               %FabricProto.WorkerEnvResolveRequest{},
               %{turn_ref: nil, request_id: "malformed-unrelated"}
             )

    {:ok, _} =
      Ankole.Ash.update(skill, :save, %{base_revision: skill.revision, enabled_for_all: true})

    assert {:error, %YamlElixir.ParsingError{}} =
             Ankole.AIAgent.resolve_mcp_server(agent, "broken-mcp", "protected")
  end
end
