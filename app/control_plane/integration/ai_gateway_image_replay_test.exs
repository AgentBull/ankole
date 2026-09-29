defmodule Ankole.AIGateway.ImageReplayIntegrationTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  @image_id "ig_provider_banner"

  defmodule WebSocketUpstream do
    @moduledoc false
    @behaviour WebSock

    def init(opts) when is_list(opts), do: opts

    @impl true
    def init(handler) when is_function(handler, 1), do: {:ok, handler}

    def call(conn, opts), do: WebSockAdapter.upgrade(conn, __MODULE__, opts[:handler], [])

    @impl true
    def handle_in({payload, [opcode: :text]}, handler) do
      frames = Enum.map(handler.(Ankole.JSON.decode!(payload)), &{:text, Ankole.JSON.encode!(&1)})
      {:push, frames, handler}
    end

    @impl true
    def handle_info(_message, handler), do: {:ok, handler}
  end

  for transport <- ~w(sse websocket) do
    @tag transport: transport
    test "compatible Responses #{transport} replays stored images across three turns", %{
      transport: transport
    } do
      %{principal: agent} = agent_fixture()
      test_pid = self()

      base_url =
        start_upstream(transport, fn request ->
          send(test_pid, {:upstream_request, request})
          response_events(request)
        end)

      provider_id = "image-replay-#{transport}"

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai_compatible",
                 base_url: base_url,
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
                 },
                 connection_options: %{
                   "endpoint_kind" => "responses",
                   "upstream_transport" => transport
                 }
               })

      refute Providers.supports_native_image_generation?(%{
               "provider_kind" => "openai_compatible"
             })

      request = %{
        "model" => "#{provider_id}/gpt-main",
        "store" => true,
        "input" => [text_message("Generate a banner.")]
      }

      first = complete_response(agent.uid, request)
      assert_receive {:upstream_request, first_request}
      assert first_request["store"] == false

      first_message = Repo.get!(Message, String.trim_leading(first["id"], "resp_"))
      stored_image = Enum.find(first_message.content, &(&1["type"] == "image_generation_call"))
      assert stored_image["id"] == @image_id
      assert stored_image["result"] == nil
      assert first_message.status == "complete"

      assert {:ok, artifact} = Artifacts.get_generated_image(agent.uid, @image_id, payload?: true)
      assert artifact.payload == Base.decode64!(@png_base64)
      assert artifact.message_id == first_message.id
      assert artifact.expires_at == nil

      second =
        complete_response(
          agent.uid,
          %{
            request
            | "input" => [text_message("Too ugly. Simplify it.")]
          }
          |> Map.put("previous_response_id", first["id"])
        )

      assert_receive {:upstream_request, second_request}
      assert_replayed_image(second_request)
      assert List.last(second_request["input"]) == text_message("Too ugly. Simplify it.")

      second_message = Repo.get!(Message, String.trim_leading(second["id"], "resp_"))
      assert second_message.previous_message_id == first_message.id
      assert second_message.conversation_id == first_message.conversation_id

      image_reference = %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "Use the original image."},
          %{"type" => "input_image", "file_id" => @image_id}
        ]
      }

      third =
        complete_response(
          agent.uid,
          Map.merge(request, %{
            "conversation" => "conv_#{first_message.conversation_id}",
            "input" => [image_reference]
          })
        )

      assert_receive {:upstream_request, third_request}
      assert_replayed_image(third_request)
      assert text_message("Too ugly. Simplify it.") in third_request["input"]

      assert List.last(third_request["input"])["content"] == [
               %{"type" => "input_text", "text" => "Use the original image."},
               %{"type" => "input_image", "image_url" => "data:image/png;base64,#{@png_base64}"}
             ]

      third_message = Repo.get!(Message, String.trim_leading(third["id"], "resp_"))
      assert third_message.previous_message_id == second_message.id
      assert third_message.conversation_id == first_message.conversation_id
    end
  end

  defp complete_response(subject_uid, request) do
    assert {:ok, stream, meta} = AIGateway.open_websocket_stream(subject_uid, request)

    assert {:ok,
            %{
              stateful?: true,
              terminal_error: nil,
              terminal_response: %{"status" => "completed"} = response
            }, _meta} = ResponseStream.await_terminal(stream, meta, 5_000)

    response
  end

  defp assert_replayed_image(request) do
    assert request["store"] == false
    refute Map.has_key?(request, "previous_response_id")
    refute Map.has_key?(request, "conversation")
    image = Enum.find(request["input"], &(&1["type"] == "image_generation_call"))
    assert image["id"] == @image_id
    assert image["result"] == @png_base64
  end

  defp start_upstream("sse", handler) do
    start_upstream_server(fn request -> {:sse, 200, handler.(request.body), false} end) <> "/v1"
  end

  defp start_upstream("websocket", handler) do
    server =
      start_supervised!(
        {Bandit,
         plug: {WebSocketUpstream, handler: handler}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/v1"
  end

  defp response_events(request) do
    # Codex-compatible proxies remove input item IDs before they call the model.
    input = Enum.map(request["input"], &Map.delete(&1, "id"))
    image = Enum.find(input, &(&1["type"] == "image_generation_call"))

    if image && !is_binary(image["result"]) do
      [
        %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_replay_failed",
            "status" => "failed",
            "error" => %{
              "code" => "invalid_prompt",
              "type" => "invalid_request_error",
              "message" =>
                "Image generation items without `id` must include inline `result` data."
            }
          }
        }
      ]
    else
      item =
        if image do
          %{
            "id" => "msg_provider_#{length(input)}",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "I can revise this image."}]
          }
        else
          %{
            "id" => @image_id,
            "type" => "image_generation_call",
            "status" => "completed",
            "result" => @png_base64
          }
        end

      response = %{
        "id" => "resp_provider_#{length(input)}",
        "object" => "response",
        "status" => "completed",
        "output" => [item],
        "usage" => %{}
      }

      [
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => response}
      ]
    end
  end

  defp text_message(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
end
