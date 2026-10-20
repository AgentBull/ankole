defmodule Ankole.Sessions.ModelMetadataTest do
  alias Ankole.AIGateway.ResponseChain
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, openai_response_stream_events: 3]
  import Ankole.PrincipalsFixtures, only: [agent_fixture: 0]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Run
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Signals.Signal

  setup do
    allow_cache_database_access()
    :ok = CredentialPool.reset_for_test()
    %{principal: agent} = agent_fixture()

    base_url =
      start_upstream_server(fn request ->
        refute Map.has_key?(request.body, "model_profile")
        refute Map.has_key?(request.body, "metadata")
        {:sse, 200, openai_response_stream_events("resp_profile", request.body["model"], "Reply")}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "profile-provider",
        provider_kind: "openai",
        base_url: "#{base_url}/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "profile-provider",
        model: "gpt-5.5"
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, "profile-metadata")
    %{agent: agent, conversation: conversation}
  end

  test "primary survives the request, provider completion, and Console API", context do
    profile = "primary"
    {:ok, model_ref} = ModelProfiles.resolve_runtime_model_ref(context.agent.uid, profile)
    assert model_ref["profile"] == profile
    assert model_ref["model"] == "gpt-5.5"

    run = run(context, model_ref)
    request = Model.request(run)
    refute Map.has_key?(request, "model_profile")

    assert {:ok, stream, meta} =
             AIGateway.open_websocket_stream(context.agent.uid, request,
               receiver: self(),
               response_metadata: %{"model_profile" => profile}
             )

    assert {:ok, %{terminal_response: response}, _meta} =
             ResponseStream.await_terminal(stream, meta, 5_000)

    assert {:ok, stored} =
             ResponseChain.get_response_for_subject(context.agent.uid, response["id"])

    assert stored.status == "complete"
    assert stored.metadata["model_profile"] == profile
    assert stored.metadata["provider_model"] == "gpt-5.5"
    assert stored.metadata["request_model"] == "profile-provider/gpt-5.5"

    conn =
      context.conn
      |> console_conn()
      |> get(~p"/api/v1/ai-gateway/conversations/#{context.conversation.id}/messages")

    assert %{"messages" => [message], "next_cursor" => nil} = json_response(conn, 200)
    assert message["metadata"]["model_profile"] == profile
    assert message["metadata"]["provider_model"] == "gpt-5.5"
  end

  test "an explicit model without a frozen profile does not invent a tier", context do
    request =
      Model.request(run(context, %{"provider_id" => "profile-provider", "model" => "gpt-5.5"}))

    refute Map.has_key?(request, "model_profile")
    assert request["model"] == "profile-provider/gpt-5.5"
  end

  defp run(context, model_ref) do
    %Run{
      agent_uid: context.agent.uid,
      session_id: "profile-metadata",
      signal_id: UUIDv7.autogenerate(),
      epoch: 1,
      event: %Signal{producer: :kernel},
      conversation: context.conversation,
      spec: %{model_ref: model_ref, request_context: %{"ai_agent" => %{}}},
      instructions: "Reply to the user.",
      input: [%{"type" => "message", "role" => "user", "content" => "Hello"}]
    }
  end
end
