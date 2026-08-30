defmodule Ankole.AIGateway.UniversalAIRequestTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Providers.OpenRouter
  alias Ankole.AIGateway.UniversalAIRequest

  test "non-stream model specs include a high-thinking timeout cap" do
    assert {:ok, spec} =
             request(stream?: false)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 1_800_000,
             idle_ms: 1_800_000,
             total_ms: 1_800_000
           }
  end

  test "stream model specs use the model no-activity budget without a total timeout" do
    assert {:ok, spec} =
             request(stream?: true)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 1_800_000,
             idle_ms: 1_800_000,
             total_ms: nil
           }
  end

  test "capability timeout overrides the non-stream total cap" do
    assert {:ok, spec} =
             request(stream?: false, timeout_ms: 240_000)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 240_000,
             first_byte_ms: 240_000,
             idle_ms: 240_000,
             total_ms: 240_000
           }
  end

  test "request-local provider options override context provider options" do
    assert {:ok, spec} =
             request(stream?: false)
             |> UniversalAIRequest.put_provider_options(%{"reasoningEffort" => "minimal"})
             |> UniversalAIRequest.to_spec()

    assert spec.response_context.provider_options == %{"reasoningEffort" => "minimal"}
  end

  test "response context identifies the reasoning source by provider type and model" do
    assert {:ok, provider} = Providers.fetch("openrouter")

    runtime = %{
      "model" => "test-model",
      "provider_options" => %{},
      "connection_options" => %{"base_url" => "https://api.example.test/v1"}
    }

    assert {:ok, ctx} =
             PrepareContext.build(
               provider,
               :language_model,
               runtime,
               %{"input" => "hello"},
               stream?: false
             )

    assert {:ok, spec} =
             ctx
             |> OpenRouter.prepare_language_model()
             |> UniversalAIRequest.to_spec()

    assert spec.response_context.request["__ankole_reasoning_source"] == %{
             "provider_type" => "openrouter",
             "model_id" => "test-model"
           }
  end

  test "credential header helpers omit missing optional settings" do
    request = request(stream?: false)

    bearer_request =
      Task.async(fn -> UniversalAIRequest.bearer_auth(request) end)
      |> Task.await(100)

    api_key_request =
      Task.async(fn -> UniversalAIRequest.api_key_header(request, "x-api-key") end)
      |> Task.await(100)

    assert bearer_request.headers == []
    assert api_key_request.headers == []
  end

  test "credential header helpers preserve configured settings" do
    request = request(stream?: false, api_key: "secret")

    assert UniversalAIRequest.bearer_auth(request).headers == [
             {"authorization", "Bearer secret"}
           ]

    assert UniversalAIRequest.api_key_header(request, "x-api-key").headers == [
             {"x-api-key", "secret"}
           ]
  end

  test "start_stream returns before ready and assigns the selected receiver" do
    {:ok, url, server} = start_blocked_sse_server()
    test_pid = self()
    receiver = spawn_link(fn -> forward_stream_messages(test_pid) end)

    assert {:ok, stream} =
             UniversalAIRequest.start_stream(stream_spec(url), :sse, receiver: receiver)

    assert stream.owner == receiver
    assert_receive :upstream_request_received, 1_000
    refute_receive {:stream_message, {:universal_ai_client, _, :ready, _}}, 50

    send(server, :release_response)

    assert_receive {:stream_message, {:universal_ai_client, ref, :ready, meta}}, 1_000
    assert ref == stream.ref
    assert meta["downstream_kind"] == "sse"

    assert :ok = Ankole.Kernel.UniversalAIClient.cancel(stream)
    send(receiver, :stop)
  end

  test "ready timeout uses first byte and a smaller total but never idle" do
    assert UniversalAIRequest.ready_timeout_ms(%{
             upstream: %{
               timeout: %{first_byte_ms: 5_000, idle_ms: 90_000, total_ms: 3_000}
             }
           }) == 4_000

    assert UniversalAIRequest.ready_timeout_ms(%{
             "upstream" => %{
               "timeout" => %{
                 "first_byte_ms" => 5_000,
                 "idle_ms" => 100,
                 "total_ms" => 8_000
               }
             }
           }) == 6_000

    assert UniversalAIRequest.ready_timeout_ms(%{
             upstream: %{timeout: %{idle_ms: 100, total_ms: nil}}
           }) == 61_000
  end

  test "stream error normalization preserves provider status details" do
    assert UniversalAIRequest.normalize_stream_error(%{
             "code" => "provider_status_rejected",
             "provider_status" => 429,
             "provider_body_excerpt" => ~s({"error":{"message":"slow down"}}),
             "provider_headers" => [["retry-after", "2"]]
           }) ==
             {:upstream_response_failed, 429, %{"error" => %{"message" => "slow down"}},
              [{"retry-after", "2"}]}
  end

  defp request(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    capability =
      %{upstream: :sse}
      |> maybe_put(:timeout_ms, timeout_ms)

    ctx = %{
      capability: capability,
      settings:
        %{base_url: "https://api.example.test/v1"}
        |> maybe_put(:api_key, Keyword.get(opts, :api_key)),
      model: "test-model",
      provider: %{provider_kind: "openrouter"},
      request: %{"input" => "hello"},
      provider_options: %{},
      stream?: Keyword.fetch!(opts, :stream?)
    }

    UniversalAIRequest.new(ctx, "responses", :openai_responses)
  end


  defp stream_spec(url) do
    %{
      api_resolver: :openai_responses,
      upstream: %{
        kind: :http_sse,
        method: "POST",
        url: url,
        headers: [{"content-type", "application/json"}],
        timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
        transport: %{http_versions: [:h1], compression: []}
      },
      response_context: %{model: "test-model", request: %{"input" => "hello"}}
    }
  end

  defp start_blocked_sse_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    test_pid = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        send(test_pid, :upstream_request_received)

        receive do
          :release_response ->
            body = "data: [DONE]\n\n"

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: text/event-stream\r\n",
                "content-length: #{byte_size(body)}\r\n",
                "\r\n",
                body
              ])

            :gen_tcp.close(socket)
            :gen_tcp.close(listen_socket)
        end
      end)

    {:ok, "http://127.0.0.1:#{port}/responses", server}
  end

  defp forward_stream_messages(test_pid) do
    receive do
      :stop ->
        :ok

      message ->
        send(test_pid, {:stream_message, message})
        forward_stream_messages(test_pid)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
