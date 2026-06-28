defmodule AnkoleWeb.AIGatewayResponsesSocketTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias AnkoleWeb.AIGatewayResponsesSocket

  setup do
    on_exit(fn -> Application.delete_env(:ankole, Ankole.AIGateway) end)

    %{principal: agent} = agent_fixture()
    provider_id = "openrouter-ws-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "openai/gpt-5.5"
             })

    {:ok, state} = AIGatewayResponsesSocket.init(%{agent_uid: agent.uid})

    %{agent: agent, state: state}
  end

  test "response.create emits OpenResponses streaming events as JSON frames", %{state: state} do
    test_pid = self()

    install_http_client(test_pid, fn request ->
      chat_completion_fixture(request.body, "counted")
    end)

    assert {:push, frames, state} =
             response_create(state, %{
               "model" => "primary",
               "input" => [
                 %{"type" => "message", "role" => "user", "content" => "Count from 1 to 3."}
               ]
             })

    assert Enum.map(decode_frames(frames), & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]

    assert Enum.map(decode_frames(frames), & &1["sequence_number"]) == Enum.to_list(0..7)
    refute Enum.any?(frame_payloads(frames), &(&1 == "[DONE]"))

    assert %{"response" => body} = List.last(decode_frames(frames))
    assert body["status"] == "completed"
    assert body["model"] == "openai/gpt-5.5"
    assert state.response_cache == %{}

    assert_receive {:gateway_request, upstream_request}
    assert upstream_request.url == "https://openrouter.ai/api/v1/chat/completions"
    assert upstream_request.body["model"] == "openai/gpt-5.5"
  end

  test "one WebSocket accepts sequential independent response.create turns", %{state: state} do
    test_pid = self()
    install_http_client(test_pid, fn request -> chat_completion_fixture(request.body, "turn") end)

    assert {:push, first_frames, _state} =
             response_create(state, %{"model" => "primary", "store" => false, "input" => "first"})

    assert {:push, second_frames, _state} =
             response_create(state, %{"model" => "primary", "store" => false, "input" => "second"})

    assert %{"response" => %{"status" => "completed"}} = List.last(decode_frames(first_frames))
    assert %{"response" => %{"status" => "completed"}} = List.last(decode_frames(second_frames))

    assert_receive {:gateway_request, first_request}
    assert_receive {:gateway_request, second_request}
    assert [%{"content" => "first"}] = first_request.body["messages"]
    assert [%{"content" => "second"}] = second_request.body["messages"]
  end

  test "store false previous_response_id continues within the same WebSocket connection", %{
    state: state
  } do
    test_pid = self()
    install_http_client(test_pid, fn request -> chat_completion_fixture(request.body, "OK") end)

    assert {:push, first_frames, state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "input" => "Remember the code word: cobalt. Reply with OK."
             })

    first_response_id = get_in(List.last(decode_frames(first_frames)), ["response", "id"])
    assert is_binary(first_response_id)
    assert_receive {:gateway_request, _first_request}

    assert {:push, second_frames, _state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "previous_response_id" => first_response_id,
               "input" => "What is the code word? Reply with only the code word."
             })

    assert %{"response" => %{"status" => "completed"}} = List.last(decode_frames(second_frames))
    assert_receive {:gateway_request, second_request}

    assert [
             %{"role" => "user", "content" => "Remember the code word: cobalt. Reply with OK."},
             %{"role" => "assistant", "content" => "OK"},
             %{
               "role" => "user",
               "content" => "What is the code word? Reply with only the code word."
             }
           ] = second_request.body["messages"]
  end

  test "missing WebSocket previous_response_id returns previous_response_not_found", %{
    state: state
  } do
    assert {:push, frame, ^state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "previous_response_id" => "resp_missing",
               "input" => "continue"
             })

    assert %{"type" => "error", "error" => %{"code" => "previous_response_not_found"}} =
             decode_frame(frame)
  end

  test "store false reconnect miss can recover with a clean new WebSocket response", %{
    state: state,
    agent: agent
  } do
    test_pid = self()

    install_http_client(test_pid, fn request ->
      chat_completion_fixture(request.body, "recovered")
    end)

    assert {:push, first_frames, _state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "input" => "Remember the reconnect code word: zinc."
             })

    response_id = get_in(List.last(decode_frames(first_frames)), ["response", "id"])
    assert_receive {:gateway_request, _first_request}

    {:ok, reconnected_state} = AIGatewayResponsesSocket.init(%{agent_uid: agent.uid})

    assert {:push, reconnect_frame, reconnected_state} =
             response_create(reconnected_state, %{
               "model" => "primary",
               "store" => false,
               "previous_response_id" => response_id,
               "input" => "Try to continue after reconnect."
             })

    assert %{"type" => "error", "error" => %{"code" => "previous_response_not_found"}} =
             decode_frame(reconnect_frame)

    assert {:push, recovery_frames, _state} =
             response_create(reconnected_state, %{
               "model" => "primary",
               "store" => false,
               "input" => "Start a new response and reply with exactly: recovered"
             })

    assert %{"response" => %{"status" => "completed"}} = List.last(decode_frames(recovery_frames))
    assert_receive {:gateway_request, recovery_request}
    refute Map.has_key?(recovery_request.body, "previous_response_id")
  end

  test "failed continuation evicts the referenced connection-local response", %{state: state} do
    test_pid = self()
    install_http_client(test_pid, fn request -> chat_completion_fixture(request.body, "OK") end)

    assert {:push, frames, state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "input" => "Remember the code word: ember. Reply with OK."
             })

    response_id = get_in(List.last(decode_frames(frames)), ["response", "id"])
    assert_receive {:gateway_request, _first_request}

    assert {:push, failed_frame, state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "previous_response_id" => response_id,
               "input" => [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_openresponses_missing",
                   "output" => "No matching tool call exists in the previous response."
                 }
               ]
             })

    assert %{"type" => "error", "error" => %{"code" => "invalid_request_error"}} =
             decode_frame(failed_frame)

    refute_receive {:gateway_request, _unexpected}

    assert {:push, retry_frame, _state} =
             response_create(state, %{
               "model" => "primary",
               "store" => false,
               "previous_response_id" => response_id,
               "input" => "Try to continue after the failed turn."
             })

    assert %{"type" => "error", "error" => %{"code" => "previous_response_not_found"}} =
             decode_frame(retry_frame)
  end

  test "WebSocket response.create rejects HTTP-only fields", %{state: state} do
    assert {:push, frame, ^state} =
             response_create(state, %{
               "type" => "response.create",
               "model" => "primary",
               "stream" => true,
               "input" => "hello"
             })

    assert %{
             "type" => "error",
             "error" => %{"code" => "invalid_request_error", "param" => "stream"}
           } = decode_frame(frame)
  end

  defp response_create(state, %{"type" => "response.create"} = event) do
    AIGatewayResponsesSocket.handle_in({Ankole.JSON.encode!(event), [opcode: :text]}, state)
  end

  defp response_create(state, event) do
    event = Map.put(event, "type", "response.create")
    response_create(state, event)
  end

  defp install_http_client(test_pid, response_fun) do
    Application.put_env(:ankole, Ankole.AIGateway,
      http_stream_client: fn request, state, handler ->
        send(test_pid, {:gateway_request, request})
        body = response_fun.(request)

        chat_stream_chunks(body)
        |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, state} ->
          case handler.(sse_data(chunk), state) do
            {:cont, state} -> {:cont, {:ok, state}}
            {:halt, {:error, reason}} -> {:halt, {:error, reason}}
          end
        end)
      end
    )
  end

  defp chat_stream_chunks(body) do
    content = get_in(body, ["choices", Access.at(0), "message", "content"]) || ""

    [
      %{
        "id" => body["id"],
        "object" => "chat.completion.chunk",
        "created" => body["created"],
        "model" => body["model"],
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => content},
            "finish_reason" => nil
          }
        ]
      },
      %{
        "id" => body["id"],
        "object" => "chat.completion.chunk",
        "created" => body["created"],
        "model" => body["model"],
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => body["usage"]
      }
    ]
  end

  defp sse_data(payload), do: "data: #{Ankole.JSON.encode!(payload)}\n\n"

  defp chat_completion_fixture(body, content) do
    %{
      "id" => "chatcmpl_#{System.unique_integer([:positive])}",
      "object" => "chat.completion",
      "created" => 1_764_967_971,
      "model" => body["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
    }
  end

  defp decode_frames(frames) do
    frames
    |> List.wrap()
    |> Enum.map(&decode_frame/1)
  end

  defp decode_frame({:text, payload}), do: Ankole.JSON.decode!(payload)

  defp frame_payloads(frames) do
    frames
    |> List.wrap()
    |> Enum.map(fn {:text, payload} -> payload end)
  end
end
