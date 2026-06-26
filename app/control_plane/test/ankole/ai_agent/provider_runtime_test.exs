defmodule Ankole.AIAgent.ProviderRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.LlmCredentialBroker
  alias Ankole.ActorRuntime.RPCLane
  alias Ankole.ActorRuntime.WorkerAuthKeys
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.Repo

  test "provider source projection uses provider_source vocabulary" do
    sources = LlmProviders.list_provider_sources()

    assert Enum.map(sources, & &1["provider_source"]) == ~w(openrouter openai claude gemini)
    refute sources |> List.first() |> Map.has_key?("provider_family")
    assert Enum.find(sources, &(&1["provider_source"] == "openrouter"))["codex_compatible"]
  end

  test "provider CRUD encrypts credentials and rejects secret headers" do
    assert {:error, {:secret_header, "Authorization"}} =
             LlmProviders.create_provider(%{
               provider_id: "bad-secret-header",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{"headers" => %{"Authorization" => "Bearer leaked"}}
             })

    assert {:ok, provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-main",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{"include_usage" => true}
             })

    refute provider.encrypted_credential == "sk-test"
    assert {:ok, "sk-test"} = LlmProviders.plaintext_credential(provider)

    assert {:ok, projection} = LlmProviders.get_provider("openrouter-main")
    assert projection["credential"] == %{"present" => true, "masked" => "********"}
    refute inspect(projection) =~ "sk-test"
  end

  test "provider live_check performs a redacted operator-triggered provider call" do
    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-main",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
             })

    http_client = fn url, headers, timeout_ms ->
      assert url == "https://openrouter.ai/api/v1/models"
      assert {"authorization", "Bearer sk-test"} in headers
      assert timeout_ms == 15_000
      {:ok, %{"status" => "ok", "http_status" => 200}}
    end

    assert {:ok, result} =
             LlmProviders.live_check_provider("openrouter-main", http_client: http_client)

    assert result["provider_id"] == "openrouter-main"
    assert result["provider_source"] == "openrouter"
    assert result["endpoint"] == "/models"
    assert result["status"] == "ok"
    refute inspect(result) =~ "sk-test"
  end

  test "provider live_check rejects missing credentials before opening a network call" do
    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-no-key",
               provider_source: "openrouter",
               connection_options: %{}
             })

    http_client = fn _url, _headers, _timeout_ms ->
      flunk("live_check must not run without a credential")
    end

    assert {:error, :credential_missing} =
             LlmProviders.live_check_provider("openrouter-no-key", http_client: http_client)
  end

  test "model profiles validate provider references and codex compatibility" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-main",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{}
             })

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "claude-main",
               provider_source: "claude",
               credential: "sk-ant",
               connection_options: %{}
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

    assert {:error, :codex_incompatible_provider_source} =
             ModelProfiles.put_model_profile(agent.uid, "codex", %{
               provider_id: "claude-main",
               model: "claude-sonnet-4-5"
             })

    assert {:ok, %{"available" => false}} = ModelProfiles.codex_capability(agent.uid)
  end

  test "model profiles validate source-specific provider options and provider delete guard lists references" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-main",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{}
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

    assert {:error, {:provider_in_use, [reference]}} =
             LlmProviders.delete_provider("openrouter-main")

    assert reference == "#{agent.uid}:primary"
  end

  test "credential broker resolves agent profile over authenticated active route" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-main",
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2"
             })

    session_id = "signal-channel:mock"
    {route, turn} = assign_worker_route(agent.uid, session_id)

    assert {:ok, response} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-1",
                 "turn" => turn,
                 "agent_uid" => agent.uid,
                 "session_id" => session_id,
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert response["credential"] == "sk-test"
    assert response["provider_id"] == "openrouter-main"
    assert response["provider_source"] == "openrouter"
    assert response["model"] == "z-ai/glm-5.2"
  end

  test "runtime RPCLane resolves agent profile through generic rpc_response" do
    %{principal: agent} = agent_fixture()
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:profile")

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "agent-profile-1",
                 "method" => "agent_profile.resolve",
                 "payload_json" => %{
                   "turn" => turn,
                   "agent_uid" => agent.uid,
                   "session_id" => "signal-channel:profile"
                 }
               },
               route
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_response"
    payload = get_in(envelope, ["body", "rpc_response", "payload_json"])
    assert payload["agent_uid"] == agent.uid
    assert payload["display_name"] == agent.display_name
    assert payload["role"] == "Research Analyst"
  end

  test "runtime RPCLane resolves turn context and DB-backed skill overlays" do
    %{principal: agent} = agent_fixture()
    assert {:ok, %{skills: 3}} = Library.sync_agent_skills(agent.uid)
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:context")

    assert {:ok, context_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "turn-context-1",
                 "method" => "runtime.turn_context.resolve",
                 "payload_json" => %{"turn" => turn}
               },
               route
             )

    context_payload = get_in(context_envelope, ["body", "rpc_response", "payload_json"])
    assert context_payload["agent_uid"] == agent.uid
    assert context_payload["session_id"] == "signal-channel:context"
    assert is_binary(context_payload["soul"])
    assert Enum.any?(context_payload["skills"], &(&1["skill_name"] == "nano-pdf"))

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

  test "runtime RPCLane rejects turn context requests from an unassigned worker route" do
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
                 "method" => "runtime.turn_context.resolve",
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

  test "credential broker live_check requires the worker to be assigned to the requested actor" do
    %{principal: target_agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-live-check-target",
               provider_source: "openrouter",
               credential: "sk-target",
               connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(target_agent.uid, "primary", %{
               provider_id: "openrouter-live-check-target",
               model: "z-ai/glm-5.2"
             })

    {route, _other_turn} = assign_worker_route(other_agent.uid, "signal-channel:other")
    target_turn = fake_turn_ref(target_agent.uid, "signal-channel:target")

    assert {:error, error} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-live-check",
                 "turn" => target_turn,
                 "agent_uid" => target_agent.uid,
                 "session_id" => "signal-channel:target",
                 "profile" => "primary",
                 "purpose" => "live_check"
               },
               route
             )

    assert error["code"] == "worker_not_assigned_to_turn"
  end

  test "credential broker returns rejected envelopes for missing and disabled provider credentials" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-no-key",
               provider_source: "openrouter",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-no-key",
               model: "z-ai/glm-5.2"
             })

    {route, turn} = assign_worker_route(agent.uid, "signal-channel:no-key")

    assert {:error, error} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-missing",
                 "turn" => turn,
                 "agent_uid" => agent.uid,
                 "session_id" => "signal-channel:no-key",
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert error["code"] == "credential_missing"

    assert {:ok, _provider} =
             LlmProviders.update_provider("openrouter-no-key", %{
               disabled_at: DateTime.utc_now(:microsecond)
             })

    assert {:error, disabled_error} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-disabled",
                 "turn" => turn,
                 "agent_uid" => agent.uid,
                 "session_id" => "signal-channel:no-key",
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert disabled_error["code"] == "provider_disabled"
  end

  test "worker auth keys are scoped to stable worker ids" do
    assert {:ok, first} = WorkerAuthKeys.bootstrap_key("worker-one")
    assert {:ok, same} = WorkerAuthKeys.bootstrap_key("worker-one")
    assert {:ok, second} = WorkerAuthKeys.bootstrap_key("worker-two")

    assert first.pre_auth_key == same.pre_auth_key
    assert first.key_revision == same.key_revision
    refute first.pre_auth_key == second.pre_auth_key
    assert {:ok, _auth_key} = WorkerAuthKeys.verify("worker-one", first.pre_auth_key)
    assert {:error, :invalid_worker_auth_key} = WorkerAuthKeys.verify("worker-one", "wrong")
  end

  defp assign_worker_route(agent_uid, session_id) do
    route = "route-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      worker_instance_id: "#{worker_id}-1",
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
      worker_instance_id: "#{worker_id}-1",
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
      assigned_worker_instance_id: "#{worker_id}-1",
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

  defp fake_turn_ref(agent_uid, session_id) do
    %{
      "actor" => %{"agent_uid" => agent_uid, "session_id" => session_id},
      "activation_uid" => "activation-missing",
      "actor_epoch" => 1,
      "llm_turn_id" => Ecto.UUID.generate(),
      "revision" => 0
    }
  end
end
