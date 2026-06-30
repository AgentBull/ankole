defmodule Ankole.AIAgent.ProviderRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AppConfigure
  alias Ankole.ActorRuntime.RPCLane
  alias Ankole.ActorRuntime.WorkerAuthKey
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.Repo

  test "provider kind projection uses provider_kind vocabulary" do
    kinds = ProviderConfigs.list_provider_kinds()
    provider_kinds = Enum.map(kinds, & &1["provider_kind"])

    assert "openrouter" in provider_kinds
    assert "openai" in provider_kinds
    assert "openai-compatible" in provider_kinds
    assert "google_ai_studio_openai" in provider_kinds
    assert "jina" in provider_kinds
    assert "claude" in provider_kinds
    assert "azure_openai" in provider_kinds
    refute "gemini" in provider_kinds
    refute kinds |> List.first() |> Map.has_key?("provider_family")
    openrouter = Enum.find(kinds, &(&1["provider_kind"] == "openrouter"))
    openai_compatible = Enum.find(kinds, &(&1["provider_kind"] == "openai-compatible"))
    google_ai_studio = Enum.find(kinds, &(&1["provider_kind"] == "google_ai_studio_openai"))
    azure_openai = Enum.find(kinds, &(&1["provider_kind"] == "azure_openai"))

    assert "llm" in openrouter["capabilities"]
    assert "embedding" in openrouter["capabilities"]
    assert "rerank" in openrouter["capabilities"]
    assert "embedding" in google_ai_studio["capabilities"]

    assert "transport" in openrouter["connection_options"]
    assert "transport" in openai_compatible["connection_options"]

    assert is_nil(azure_openai["default_base_url"])
    refute Map.has_key?(openrouter, "default_transport")
    refute Map.has_key?(azure_openai, "default_transport")

    assert Enum.all?(kinds, fn provider ->
             label = provider["label"]

             Map.has_key?(label, "default") and Map.has_key?(label, "zh-Hans-CN") and
               not Map.has_key?(label, "en") and not Map.has_key?(label, "zh")
           end)
  end

  test "provider CRUD encrypts declared options and validates connection options" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               connection_options: %{
                 "api_key" => "sk-test",
                 "include_usage" => true,
                 "headers" => %{"Authorization" => "Bearer provider-managed"}
               }
             })

    refute Map.has_key?(provider.connection_options, "api_key")
    assert is_binary(provider.encrypted_options["api_key"])
    refute provider.encrypted_options["api_key"] == "sk-test"
    assert {:ok, connection} = ProviderConfigs.runtime_connection(provider)
    refute Map.has_key?(connection, "transport")
    assert connection["api_key"] == "sk-test"
    assert connection["headers"] == %{"Authorization" => "Bearer provider-managed"}

    assert {:ok, projection} = ProviderConfigs.get_provider("openrouter-main")

    assert projection["encrypted_options"] == %{
             "api_key" => %{"present" => true, "masked" => "********"}
           }

    refute Map.has_key?(projection["connection_options"], "api_key")
    refute inspect(projection) =~ "sk-test"

    assert {:ok, compatible_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-main",
               provider_kind: "openai-compatible",
               base_url: "https://compatible.test/v1",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:ok, compatible_connection} = ProviderConfigs.runtime_connection(compatible_provider)
    refute Map.has_key?(compatible_connection, "transport")

    assert {:ok, overridden_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-http2",
               provider_kind: "openai-compatible",
               base_url: "https://compatible.test/v1",
               connection_options: %{
                 "api_key" => "sk-test",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    assert {:ok, overridden_connection} = ProviderConfigs.runtime_connection(overridden_provider)

    assert overridden_connection["transport"] == %{
             "http_versions" => ["h1"],
             "compression" => ["gzip"]
           }

    json_secret = %{"access_key" => "ak-test", "secret_key" => "sk-test"}

    assert {:ok, json_secret_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "json-secret-provider",
               provider_kind: "openrouter",
               connection_options: %{"api_key" => json_secret}
             })

    assert {:ok, json_secret_connection} =
             ProviderConfigs.runtime_connection(json_secret_provider)

    assert json_secret_connection["api_key"] == json_secret

    assert {:ok, json_secret_projection} = ProviderConfigs.get_provider("json-secret-provider")

    assert json_secret_projection["encrypted_options"] == %{
             "api_key" => %{"present" => true, "masked" => "********"}
           }

    refute inspect(json_secret_projection) =~ "ak-test"
    refute inspect(json_secret_projection) =~ "sk-test"
  end

  test "provider live_check performs a redacted operator-triggered provider call" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{
                 "api_key" => "sk-test",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["gzip"],
                   "proxy" => "http://proxy.test:8080"
                 }
               }
             })

    http_client = fn request ->
      assert request.url == "https://openrouter.ai/api/v1/models"
      assert {"authorization", "Bearer sk-test"} in request.headers

      assert request.transport == %{
               "http_versions" => ["h1"],
               "compression" => ["gzip"],
               "proxy" => "http://proxy.test:8080"
             }

      assert request.timeout_ms == 15_000
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, result} =
             ProviderConfigs.live_check_provider("openrouter-main", http_client: http_client)

    assert result["provider_id"] == "openrouter-main"
    assert result["provider_kind"] == "openrouter"
    assert result["status"] == "ok"
    refute inspect(result) =~ "sk-test"
  end

  test "provider live_check uses provider-owned auth header rules" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-oauth",
               provider_kind: "claude",
               connection_options: %{"api_key" => "anthropic-token", "auth_mode" => "auth_token"}
             })

    http_client = fn request ->
      assert request.url == "https://api.anthropic.com/v1/models"
      assert {"authorization", "Bearer anthropic-token"} in request.headers
      refute {"x-api-key", "anthropic-token"} in request.headers
      assert {"anthropic-version", "2023-06-01"} in request.headers
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, %{"provider_kind" => "claude", "status" => "ok"}} =
             ProviderConfigs.live_check_provider("claude-oauth", http_client: http_client)
  end

  test "provider live_check uses Azure OpenAI catalog path and auth scheme" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-live",
               provider_kind: "azure_openai",
               base_url: "https://ankole-test.openai.azure.com",
               connection_options: %{
                 "api_key" => "azure-key",
                 "api_version" => "2025-04-01-preview"
               }
             })

    http_client = fn request ->
      assert request.url ==
               "https://ankole-test.openai.azure.com/openai/models?api-version=2025-04-01-preview"

      assert {"api-key", "azure-key"} in request.headers
      refute {"authorization", "Bearer azure-key"} in request.headers
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, %{"provider_kind" => "azure_openai", "status" => "ok"}} =
             ProviderConfigs.live_check_provider("azure-live", http_client: http_client)
  end

  test "provider live_check leaves missing encrypted options to provider-owned request logic" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-no-key",
               provider_kind: "openrouter",
               connection_options: %{}
             })

    http_client = fn request ->
      assert request.url == "https://openrouter.ai/api/v1/models"

      refute Enum.any?(request.headers, fn {name, _value} ->
               String.downcase(name) == "authorization"
             end)

      {:ok, %{"status" => 401, "body" => %{"error" => "missing key"}}}
    end

    assert {:error,
            {:provider_live_check_failed,
             %{
               "http_status" => 401,
               "reason" => "upstream_error",
               "body" => "%{\"error\" => \"missing key\"}"
             }}} =
             ProviderConfigs.live_check_provider("openrouter-no-key", http_client: http_client)
  end

  test "model profiles validate provider references and embedding/rerank capabilities" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-main",
               provider_kind: "claude",
               connection_options: %{"api_key" => "sk-ant"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-main",
               provider_kind: "jina",
               connection_options: %{"api_key" => "jina-key"}
             })

    assert {:ok, %{profile: profile}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{
                 "reasoning" => %{"effort" => "minimal", "exclude" => true},
                 "reasoningEffort" => "medium"
               }
             })

    assert profile["provider_id"] == "openrouter-main"
    assert profile["provider_options"]["reasoning"] == %{"effort" => "minimal", "exclude" => true}

    assert {:error, {:provider_kind_missing_capability, "embedding"}} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "claude-main",
               model: "claude-sonnet-4-5"
             })

    assert {:ok, %{profile: embedding_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "jina-main",
               model: "jina-embeddings-v4"
             })

    assert embedding_profile["provider_id"] == "jina-main"

    assert {:ok, runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "embedding")

    assert runtime_profile["capability"] == "embedding"
  end

  test "model profiles validate source-specific provider options and provider delete guard lists references" do
    %{principal: agent} = agent_fixture()
    %{principal: malformed_agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:error, {:provider_options, {:unknown_keys, ["thinking"]}}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"thinking" => %{"type" => "enabled"}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"reasoningEffort" => "medium"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2"
             })

    malformed_agent
    |> then(&Repo.get!(Ankole.Principals.Agent, &1.uid))
    |> Ankole.Principals.Agent.changeset(%{
      options: %{"ai_agent" => %{"models" => [%{"provider_id" => "openrouter-main"}]}}
    })
    |> Repo.update!()

    assert {:error, {:provider_in_use, references}} =
             ProviderConfigs.delete_provider("openrouter-main")

    assert references == Enum.sort(["#{agent.uid}:primary", "#{agent.uid}:light"])
  end

  test "runtime RPCLane resolves agent conversation context, history, and DB-backed skill overlays" do
    %{principal: agent} = agent_fixture()
    assert {:ok, %{skills: 3}} = Library.sync_agent_skills(agent.uid)
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:context")

    assert {:ok, context_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "turn-context-1",
                 "method" => "agent_conversation.context.resolve",
                 "payload_json" => %{"turn" => turn}
               },
               route
             )

    context_payload = get_in(context_envelope, ["body", "rpc_response", "payload_json"])
    assert context_payload["agent_uid"] == agent.uid
    assert context_payload["session_id"] == "signal-channel:context"
    assert context_payload["agent"]["display_name"] == agent.display_name
    assert context_payload["agent"]["role"] == "Research Analyst"
    assert context_payload["conversation"]["key"] == "signal-channel:context"
    assert is_binary(context_payload["soul"])
    assert Enum.any?(context_payload["skills"], &(&1["skill_name"] == "nano-pdf"))
    refute Map.has_key?(context_payload, "request_context")
    refute get_in(context_payload, ["conversation", "messages"])

    assert {:ok, history_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "conversation-history-1",
                 "method" => "conversation.history.resolve",
                 "payload_json" => %{"turn" => turn, "purpose" => "prompt"}
               },
               route
             )

    history_payload = get_in(history_envelope, ["body", "rpc_response", "payload_json"])
    assert history_payload["agent_uid"] == agent.uid
    assert history_payload["session_id"] == "signal-channel:context"
    assert history_payload["purpose"] == "prompt"
    assert history_payload["messages"] == []

    assert {:ok, replace_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "skill-overlay-replace-1",
                 "method" => "skills.overlay.replace",
                 "payload_json" => %{
                   "turn" => turn,
                   "skill_name" => "nano-pdf",
                   "content" => "Prefer page-by-page verification."
                 }
               },
               route
             )

    replace_payload = get_in(replace_envelope, ["body", "rpc_response", "payload_json"])
    assert replace_payload["has_overlay"]
    assert replace_payload["overlay_json"] == %{"text" => "Prefer page-by-page verification."}

    assert {:ok, resolve_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "skill-overlay-resolve-1",
                 "method" => "skills.overlay.resolve",
                 "payload_json" => %{"turn" => turn, "skill_name" => "nano-pdf"}
               },
               route
             )

    assert get_in(resolve_envelope, ["body", "rpc_response", "payload_json", "overlay_json"]) ==
             %{"text" => "Prefer page-by-page verification."}

    assert {:ok, clear_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "skill-overlay-clear-1",
                 "method" => "skills.overlay.clear",
                 "payload_json" => %{"turn" => turn, "skill_name" => "nano-pdf"}
               },
               route
             )

    refute get_in(clear_envelope, ["body", "rpc_response", "payload_json", "has_overlay"])
  end

  test "runtime RPCLane rejects agent conversation context requests from an unassigned worker route" do
    %{principal: target_agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    {_target_route, target_turn} =
      assign_worker_route(target_agent.uid, "signal-channel:target-context")

    {other_route, _other_turn} =
      assign_worker_route(other_agent.uid, "signal-channel:other-context")

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "turn-context-wrong-route",
                 "method" => "agent_conversation.context.resolve",
                 "payload_json" => %{"turn" => target_turn}
               },
               other_route
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "worker_not_assigned_to_turn"
  end

  test "runtime RPCLane rejects stale revision overlay writes" do
    %{principal: agent} = agent_fixture()
    assert {:ok, %{skills: 3}} = Library.sync_agent_skills(agent.uid)
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:stale-overlay")

    turn["activation_uid"]
    |> then(&Repo.get_by!(ActorSessionActivation, activation_uid: &1))
    |> Ecto.Changeset.change(%{revision: 1})
    |> Repo.update!()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "skill-overlay-stale",
                 "method" => "skills.overlay.replace",
                 "payload_json" => %{
                   "turn" => turn,
                   "skill_name" => "nano-pdf",
                   "content" => "This stale write must be rejected."
                 }
               },
               route
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "stale_revision"
  end

  test "worker auth key is global AppConfigure state" do
    definition = WorkerAuthKey.definition()

    assert {:ok, first} = WorkerAuthKey.ensure()
    assert {:ok, same} = WorkerAuthKey.ensure()
    assert first == same
    assert {:ok, _uuid} = Ecto.UUID.cast(first)

    assert {:ok, "tcp://:" <> rest} = WorkerAuthKey.runtime_fabric_url("tcp://control-plane:6010")
    assert rest == URI.encode_www_form(first) <> "@control-plane:6010"

    assert {:error, {:global_scope_only, _key}} =
             AppConfigure.put_for_agent("agent-a", definition, "agent-specific")
  end

  defp assign_worker_route(agent_uid, session_id) do
    route = "route-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })

    Repo.insert!(%ActorSessionWorkerAssignment{
      agent_uid: agent_uid,
      session_id: session_id,
      worker_id: worker_id,
      transport_route: route,
      status: "assigned",
      assigned_at: now,
      metadata: %{}
    })

    conversation =
      Repo.insert!(%Conversation{
        id: Ecto.UUID.generate(),
        agent_uid: agent_uid,
        conversation_key: session_id,
        generation: %{},
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    llm_turn =
      Repo.insert!(%LlmTurn{
        id: Ecto.UUID.generate(),
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        kind: "generation",
        status: "started",
        profile: "primary",
        provider: "test-provider",
        model: "z-ai/glm-5.2",
        input_message_ids: [],
        request_context: %{},
        request_refs: [],
        request_patches: [],
        response: %{},
        tool_results: [],
        usage: %{},
        provider_metadata: %{},
        started_at: now,
        inserted_at: now,
        updated_at: now
      })

    activation_uid = "activation-#{System.unique_integer([:positive])}"

    Repo.insert!(%ActorSessionActivation{
      activation_uid: activation_uid,
      agent_uid: agent_uid,
      session_id: session_id,
      actor_epoch: 1,
      status: "active",
      controller_node: "test",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      lease_expires_at: DateTime.add(now, 60, :second),
      assigned_worker_id: worker_id,
      current_llm_turn_id: llm_turn.id,
      revision: 0,
      started_at: now,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })

    {route,
     %{
       "actor" => %{"agent_uid" => agent_uid, "session_id" => session_id},
       "activation_uid" => activation_uid,
       "actor_epoch" => 1,
       "llm_turn_id" => llm_turn.id,
       "revision" => 0
     }}
  end
end
