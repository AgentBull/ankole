defmodule Ankole.AIGateway.ProviderMetadataToolLoopIntegrationTest do
  alias Ankole.AIGateway.ResponseChain
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Run
  alias Ankole.Signals.Signal

  @moduletag :real_llm
  @moduletag timeout: 180_000

  for kind <- ~w(openai claude) do
    @tag provider_kind: kind
    test "#{kind} keeps local metadata through a real tool round", %{provider_kind: kind} do
      {remote, model, key, credentials} = provider(kind)
      assert is_binary(key) and key != "", "Set the provider API key or OPEN_ROUTER_API_KEY"
      %{principal: agent} = agent_fixture()
      owner = self()

      proxy =
        start_upstream_server(fn request ->
          # Capture only the body. Authentication headers must stay out of assertions.
          send(owner, {:provider_body, request.body})

          headers =
            Map.take(request.headers, [
              "authorization",
              "x-api-key",
              "anthropic-version",
              "anthropic-beta"
            ])

          {:ok, response} =
            Req.post(remote <> "/" <> request.path,
              headers: headers,
              json: request.body,
              retry: false,
              receive_timeout: 120_000,
              compressed: true
            )

          case response.body do
            body when is_binary(body) -> {:raw, response.status, "text/event-stream", body}
            body -> {:json, response.status, body}
          end
        end)

      id = "real-metadata-#{kind}-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ProviderConfigs.create_provider(%{
                 provider_id: id,
                 provider_kind: kind,
                 base_url: proxy,
                 credential_pool: %{
                   "entries" => [
                     Map.merge(%{"label" => "Real test", "api_key" => key}, credentials)
                   ]
                 }
               })

      assert {:ok, conversation} = Conversations.ensure_conversation(agent.uid, id)

      run = %Run{
        agent_uid: agent.uid,
        session_id: id,
        signal_id: Ecto.UUID.generate(),
        epoch: 1,
        event: %Signal{},
        conversation: conversation,
        instructions:
          "Call multiply exactly once with a=6 and b=7, then answer with only its numeric result.",
        input: [%{"type" => "message", "role" => "user", "content" => "What is six times seven?"}],
        spec: %{
          model_ref: %{"provider_id" => id, "model" => model, "profile" => "primary"},
          request_context: %{"ai_agent" => %{"max_output_tokens" => 1_024}}
        }
      }

      request =
        Model.request(run)
        |> Map.put("tools", [
          %{
            "type" => "function",
            "name" => "multiply",
            "description" => "Multiply two integers.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}},
              "required" => ["a", "b"],
              "additionalProperties" => false
            }
          }
        ])
        |> Map.put("metadata", %{
          "signal_id" => run.signal_id,
          "local_diagnostics" => %{"pages" => %{"private_marker" => "never-send-this"}}
        })
        |> Map.put("provider_options", %{
          "reasoningEffort" => if(kind == "claude", do: "low", else: "none")
        })

      first = complete(kind, agent.uid, request)
      assert first["status"] == "completed"
      assert [call] = Enum.filter(first["output"], &(&1["type"] == "function_call"))
      assert call["name"] == "multiply"
      assert Ankole.JSON.decode!(call["arguments"]) == %{"a" => 6, "b" => 7}
      if kind == "openai", do: assert_local(agent.uid, first["id"], request)
      assert_receive {:provider_body, first_body}, 1_000
      assert_wire(first_body)

      continuation =
        request
        |> Map.put("previous_response_id", first["id"])
        |> Map.put("input", [
          %{"type" => "function_call_output", "call_id" => call["call_id"], "output" => "42"}
        ])

      continuation =
        if kind == "claude",
          do:
            Map.put(continuation, "input", run.input ++ first["output"] ++ continuation["input"]),
          else: continuation

      final = complete(kind, agent.uid, continuation)
      assert final["status"] == "completed"
      assert Ankole.Conversations.Delivery.Text.visible_text(final["output"]) == "42"
      if kind == "openai", do: assert_local(agent.uid, final["id"], request)
      assert_receive {:provider_body, final_body}, 1_000
      assert_wire(final_body)
    end
  end

  # Anthropic Messages currently uses explicit stateless replay. The stateful
  # gateway contract is limited to Responses and Chat Completions resolvers.
  defp complete("claude", uid, request) do
    assert {:ok, %{body: response}} =
             AIGateway.create_response(
               uid,
               Map.drop(request, ~w(conversation store previous_response_id))
             )

    response
  end

  defp complete("openai", uid, request) do
    assert {:ok, stream, meta} = AIGateway.open_websocket_stream(uid, request)

    assert {:ok, %{terminal_error: nil, terminal_response: response}, _} =
             ResponseStream.await_terminal(stream, meta, 150_000)

    response
  end

  defp assert_wire(body) do
    refute Map.has_key?(body, "metadata")
    refute Map.has_key?(body, "model_profile")
    refute Ankole.JSON.encode!(body) =~ "never-send-this"
  end

  defp assert_local(uid, id, request) do
    assert {:ok, response} = ResponseChain.get_response_for_subject(uid, id)
    assert response.metadata["request_metadata"] == request["metadata"]
    assert response.metadata["model_profile"] == "primary"
  end

  defp provider("openai") do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" ->
        {"https://api.openai.com/v1", System.get_env("ANKOLE_REAL_OPENAI_MODEL", "gpt-5.4-nano"),
         key, %{}}

      _ ->
        {"https://openrouter.ai/api/v1", "openai/gpt-5.4-nano",
         System.get_env("OPEN_ROUTER_API_KEY"), %{}}
    end
  end

  defp provider("claude") do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        {"https://api.anthropic.com",
         System.get_env("ANKOLE_REAL_CLAUDE_MODEL", "claude-haiku-4-5"), key, %{}}

      _ ->
        {"https://openrouter.ai/api", "anthropic/claude-haiku-4.5",
         System.get_env("OPEN_ROUTER_API_KEY"), %{"auth_mode" => "auth_token"}}
    end
  end
end
