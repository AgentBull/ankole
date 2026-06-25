defmodule Ankole.AIAgent.ProviderRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.ActorRuntime.LlmCredentialBroker
  alias Ankole.ActorRuntime.WorkerAuthKeys
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
               provider_options: %{"reasoningEffort" => "medium"}
             })

    assert profile["provider_id"] == "openrouter-main"

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

    route = "route-1"
    worker_id = "worker-a"
    session_id = "signal-channel:mock"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      worker_instance_id: "worker-a-1",
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
      agent_uid: agent.uid,
      session_id: session_id,
      worker_id: worker_id,
      worker_instance_id: "worker-a-1",
      transport_route: route,
      status: "assigned",
      assigned_at: now,
      metadata: %{}
    })

    assert {:ok, envelope} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-1",
                 "agent_uid" => agent.uid,
                 "session_id" => session_id,
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert envelope["body"]["type"] == "llm_provider_credential_response"
    response = envelope["body"]["llm_provider_credential_response"]
    assert response["credential"] == "sk-test"
    assert response["provider_id"] == "openrouter-main"
    assert response["provider_source"] == "openrouter"
    assert response["model"] == "z-ai/glm-5.2"
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

    route = assign_worker_route(agent.uid, "signal-channel:no-key")

    assert {:ok, envelope} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-missing",
                 "agent_uid" => agent.uid,
                 "session_id" => "signal-channel:no-key",
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert get_in(envelope, ["body", "type"]) == "llm_provider_credential_rejected"

    assert get_in(envelope, ["body", "llm_provider_credential_rejected", "code"]) ==
             "credential_missing"

    assert {:ok, _provider} =
             LlmProviders.update_provider("openrouter-no-key", %{
               disabled_at: DateTime.utc_now(:microsecond)
             })

    assert {:ok, disabled_envelope} =
             LlmCredentialBroker.handle_request(
               %{
                 "request_id" => "cred-disabled",
                 "agent_uid" => agent.uid,
                 "session_id" => "signal-channel:no-key",
                 "profile" => "primary",
                 "purpose" => "ai_turn"
               },
               route
             )

    assert get_in(disabled_envelope, ["body", "llm_provider_credential_rejected", "code"]) ==
             "provider_disabled"
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

    route
  end
end
