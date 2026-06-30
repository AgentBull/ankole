defmodule Ankole.AIGateway.ResponsesDispatchTest do
  use Ankole.AIGatewayCase

  import AnkoleWeb.AIGatewayControllerTestHelpers, only: [decode_sse_events: 1]

  alias Ankole.AIGateway.Providers
  alias Ankole.Kernel.UniversalAIClient

  test "responses dispatch strips previous_response_id and applies provider options" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_test",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-responses-main",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-responses-main",
               model: "gpt-5.5",
               provider_options: %{"reasoningEffort" => "minimal"}
             })

    assert {:ok, %{body: body, model_ref: model_ref}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "previous_response_id" => "resp_old",
               "stream" => true
             })

    assert_receive {:gateway_request, request}
    assert request.method == :post
    assert request.path == "v1/responses"
    assert request.headers["authorization"] == "Bearer sk-openai"
    assert request.body["model"] == "gpt-5.5"
    assert request.body["stream"] == false
    assert request.body["input"] == "hello"
    assert request.body["reasoningEffort"] == "minimal"
    refute Map.has_key?(request.body, "previous_response_id")

    assert body["id"] == "resp_test"
    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "primary"
    assert model_ref["provider_id"] == "openai-responses-main"
  end

  test "explicit provider selectors can carry request-scoped provider options" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_explicit_provider_options",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-explicit-options",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, %{body: body, model_ref: model_ref}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "openai-explicit-options/gpt-5.5",
               "input" => "hello",
               "provider_options" => %{"reasoningEffort" => "minimal"}
             })

    assert_receive {:gateway_request, request}
    assert request.path == "v1/responses"
    assert request.body["model"] == "gpt-5.5"
    assert request.body["input"] == "hello"
    assert request.body["reasoningEffort"] == "minimal"
    refute Map.has_key?(request.body, "provider_options")

    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "openai-explicit-options/gpt-5.5"
    assert model_ref["provider_id"] == "openai-explicit-options"
  end

  test "request-scoped provider options override profile defaults" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_profile_options_override",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-profile-options-override",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-profile-options-override",
               model: "gpt-5.5",
               provider_options: %{"reasoningEffort" => "minimal"}
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "provider_options" => %{"reasoningEffort" => "medium"}
             })

    assert_receive {:gateway_request, request}
    assert request.body["reasoningEffort"] == "medium"
    refute Map.has_key?(request.body, "provider_options")
    assert body["model"] == "gpt-5.5"
  end

  test "explicit provider selectors reject unknown provider options" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_unreachable",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-explicit-invalid-options",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:error, {:provider_options, {:unknown_keys, ["thinking"]}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "openai-explicit-invalid-options/gpt-5.5",
               "input" => "hello",
               "provider_options" => %{"thinking" => %{"type" => "enabled"}}
             })

    refute_receive {:gateway_request, _request}, 100
  end

  test "responses return structured errors for upstream non-2xx instead of successful bodies" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 429,
         %{
           "error" => %{
             "code" => "rate_limited",
             "message" => "provider rate limit",
             "type" => "too_many_requests"
           }
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-upstream-error",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-upstream-error",
               model: "openai/gpt-5.5"
             })

    assert {:error,
            {:upstream_response_failed, 429,
             %{
               "error" => %{
                 "code" => "rate_limited",
                 "message" => "provider rate limit",
                 "type" => "too_many_requests"
               }
             }}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
  end

  test "responses reject 2xx upstream bodies that are not JSON objects" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request -> {:json, 200, ["not", "a", "map"]} end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-upstream-body",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-invalid-upstream-body",
               model: "openai/gpt-5.5"
             })

    assert {:error, {:invalid_upstream_response, 200, ["not", "a", "map"]}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
  end

  test "chat completions providers receive Responses text.format as response_format" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], ~s({"answer":"ok"}))}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-json-schema",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-json-schema",
               model: "openai/gpt-5.5"
             })

    schema = %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "additionalProperties" => false
    }

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "return json",
               "extra_body" => %{
                 "enable_thinking" => false,
                 "provider" => %{"sort" => "throughput"}
               },
               "text" => %{
                 "format" => %{
                   "type" => "json_schema",
                   "name" => "ambient_intervention_decision",
                   "description" => "Decision schema",
                   "strict" => true,
                   "schema" => schema
                 }
               }
             })

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"

    assert request.body["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "ambient_intervention_decision",
               "description" => "Decision schema",
               "strict" => true,
               "schema" => schema
             }
           }

    assert request.body["enable_thinking"] == false
    assert request.body["provider"] == %{"sort" => "throughput"}
    refute Map.has_key?(request.body, "extra_body")

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             ~s({"answer":"ok"})
  end

  test "chat completions dispatch preserves user multimodal image_url content" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], "image")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-multimodal-dispatch",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-multimodal-dispatch",
               model: "openai/gpt-5.4-nano"
             })

    image_url = "data:image/png;base64,iVBORw0KGgo="

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [
                     %{"type" => "input_text", "text" => "Describe the image in one word."},
                     %{"type" => "input_image", "image_url" => image_url}
                   ]
                 }
               ]
             })

    assert_receive {:gateway_request, request}

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "Describe the image in one word."},
                 %{"type" => "image_url", "image_url" => %{"url" => ^image_url}}
               ]
             }
           ] = request.body["messages"]

    assert body["status"] == "completed"
  end

  test "openrouter provider exposes defaults and sends attribution headers" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], "hello")}
      end)

    assert Providers.OpenRouter.provider_definition().base_url == "https://openrouter.ai/api/v1"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-default-url",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-default-url",
               model: "openai/gpt-5.5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.headers["authorization"] == "Bearer sk-openrouter"
    assert request.headers["http-referer"] == "https://github.com/agentbull/ankole"
    assert request.headers["x-title"] == "Ankole"
    assert request.headers["x-openrouter-title"] == "Ankole"
    assert request.body["reasoningEffort"] == "high"
    assert body["model"] == "openai/gpt-5.5"
  end

  test "streaming responses use native UniversalAIClient transport and resolver" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:sse, 200, chat_stream_chunks(request, "native hello")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-native-stream",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-native-stream",
               model: "openai/gpt-5.5"
             })

    assert {:ok, events} =
             open_sse_events(agent.uid, %{"model" => "primary", "input" => "hello"})

    body = terminal_response_body!(events)

    assert_receive {:gateway_request, request}
    assert request.body["model"] == "openai/gpt-5.5"
    assert request.body["stream"] == true

    assert_standard_stream(events)

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "native hello"

    assert body["usage"]["total_tokens"] == 5
  end

  test "multiple agents stream concurrently through native UniversalAIClient without cross-talk" do
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn request ->
        input = request_input_text(request)
        {:sse, 200, chat_stream_chunks(request, "echo:#{input}")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-native-concurrent",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    agents =
      for index <- 1..8 do
        %{principal: agent} = agent_fixture()
        input = "agent-input-#{index}"

        assert {:ok, _profile} =
                 ModelProfiles.put_model_profile(agent.uid, "primary", %{
                   provider_id: "openrouter-native-concurrent",
                   model: "openai/gpt-5.5"
                 })

        {agent.uid, input}
      end

    results =
      agents
      |> Task.async_stream(
        fn {agent_uid, input} ->
          assert {:ok, events} =
                   open_sse_events(agent_uid, %{"model" => "primary", "input" => input})

          body = terminal_response_body!(events)

          {input, get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"])}
        end,
        max_concurrency: length(agents),
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Map.new(results) ==
             Map.new(agents, fn {_agent_uid, input} -> {input, "echo:#{input}"} end)

    assert agents
           |> length()
           |> collect_gateway_requests([])
           |> Enum.map(&request_input_text/1)
           |> Enum.sort() == Enum.map(agents, fn {_agent_uid, input} -> input end) |> Enum.sort()
  end

  test "concurrent native streams isolate malformed upstream SSE failures" do
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn request ->
        input = request_input_text(request)

        if String.starts_with?(input, "bad-") do
          {:raw, 200, "text/event-stream", "data: {not-json}\n\n"}
        else
          {:sse, 200, chat_stream_chunks(request, "ok:#{input}")}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-native-chaos",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    agents =
      for index <- 1..6 do
        %{principal: agent} = agent_fixture()
        input = if rem(index, 3) == 0, do: "bad-#{index}", else: "good-#{index}"

        assert {:ok, _profile} =
                 ModelProfiles.put_model_profile(agent.uid, "primary", %{
                   provider_id: "openrouter-native-chaos",
                   model: "openai/gpt-5.5"
                 })

        {agent.uid, input}
      end

    results =
      agents
      |> Task.async_stream(
        fn {agent_uid, input} ->
          assert {:ok, events} =
                   open_sse_events(agent_uid, %{"model" => "primary", "input" => input})

          if String.starts_with?(input, "bad-") do
            assert Enum.any?(events, &(&1["type"] == "error"))
            assert Enum.any?(events, &(&1["type"] == "response.failed"))
            {input, :failed}
          else
            body = terminal_response_body!(events)
            text = get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"])
            {input, text}
          end
        end,
        max_concurrency: length(agents),
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Map.new(results) ==
             Map.new(agents, fn
               {_agent_uid, "bad-" <> _rest = input} -> {input, :failed}
               {_agent_uid, input} -> {input, "ok:#{input}"}
             end)

    assert agents
           |> length()
           |> collect_gateway_requests([])
           |> Enum.map(&request_input_text/1)
           |> Enum.sort() == Enum.map(agents, fn {_agent_uid, input} -> input end) |> Enum.sort()
  end

  test "openai responses can prepare an upstream WebSocket response.create stream" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-upstream-websocket",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-upstream-websocket",
               model: "gpt-5.5"
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "primary"
             })

    assert {:ok, request} =
             Providers.build_response_request(
               runtime,
               %{
                 "model" => "primary",
                 "input" => "hello",
                 "stream_options" => %{"include_usage" => true},
                 "background" => true
               },
               stream?: true
             )

    assert request.upstream.method == "GET"
    assert request.upstream.kind == :websocket_text
    assert request.upstream.url == "wss://api.openai.test/v1/responses"
    assert request.api_resolver == :openai_responses
    refute Map.has_key?(request, :body)
    refute Map.has_key?(request, :websocket_initial_messages)
    assert request.response_context.model == "gpt-5.5"
    assert request.response_context.request["input"] == "hello"
    assert request.response_context.stream == true
  end

  test "google ai studio openai provider uses compatibility auth and headers" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn
        %{path: "chat/completions"} = request ->
          {:json, 200, chat_completion_body(request.body["model"], "gemini")}

        %{path: "models/gemini-embedding-2-preview:embedContent"} ->
          {:json, 200,
           %{
             "embedding" => %{"values" => [0.1, 0.2]}
           }}
      end)

    assert Providers.GoogleAIStudioOpenAI.provider_definition().base_url ==
             "https://generativelanguage.googleapis.com/v1beta/openai"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "google-ai-studio-openai",
               provider_kind: "google_ai_studio_openai",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "gemini-key",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "google-ai-studio-openai",
               model: "gemini-2.5-pro"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.headers["authorization"] == "Bearer gemini-key"
    assert request.headers["x-goog-api-client"] == "ankole-ai-gateway/0.1"
    assert request.body["model"] == "gemini-2.5-pro"
    assert request.body["reasoningEffort"] == "high"
    assert body["model"] == "gemini-2.5-pro"

    assert {:ok, %{body: embedding_body}} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "google-ai-studio-openai/gemini-embedding-2-preview",
               "input" => "hello",
               "provider_options" => %{
                 "taskType" => "RETRIEVAL_DOCUMENT",
                 "outputDimensionality" => 2
               }
             })

    assert_receive {:gateway_request, request}
    assert request.path == "models/gemini-embedding-2-preview:embedContent"
    refute Map.has_key?(request.headers, "authorization")
    assert request.headers["x-goog-api-key"] == "gemini-key"
    assert request.headers["x-goog-api-client"] == "ankole-ai-gateway/0.1"
    assert request.body["model"] == "models/gemini-embedding-2-preview"
    assert request.body["content"] == %{"parts" => [%{"text" => "hello"}]}

    assert request.body["embedContentConfig"] == %{
             "outputDimensionality" => 2,
             "taskType" => "RETRIEVAL_DOCUMENT"
           }

    refute Map.has_key?(request.body, "provider_options")
    assert embedding_body["model"] == "gemini-embedding-2-preview"
    assert [%{"embedding" => [0.1, 0.2], "index" => 0}] = embedding_body["data"]
  end

  test "google ai studio rejects reasoning efforts outside Gemini's supported subset" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], "gemini")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "google-ai-studio-reasoning",
               provider_kind: "google_ai_studio_openai",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "gemini-key",
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "google-ai-studio-reasoning",
               model: "gemini-2.5-pro"
             })

    assert {:error, {:reasoning_effort, {:unsupported, "minimal", ["high", "low", "medium"]}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "provider_options" => %{"reasoningEffort" => "minimal"}
             })

    refute_receive {:gateway_request, _request}, 100
  end

  test "openai-compatible requires base URL and records protocol choices" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-no-url",
               provider_kind: "openai-compatible",
               connection_options: %{"api_key" => "compatible-key"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-compatible-no-url",
               model: "local-model"
             })

    assert {:error, :missing_base_url} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    http1_base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, chat_completion_body("local-model", "http1")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-http1",
               provider_kind: "openai-compatible",
               base_url: http1_base_url,
               connection_options: %{
                 "api_key" => "compatible-key",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-compatible-http1",
               model: "local-model"
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "primary"
             })

    assert runtime["connection_options"]["transport"]["http_versions"] == ["h1"]

    assert {:ok, %{body: http1_body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"

    assert get_in(http1_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "http1"
  end

  test "claude provider converts messages API auth, body, and SSE events" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200, anthropic_stream_events(), false}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-stream",
               provider_kind: "claude",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "anthropic-key",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "claude-stream",
               model: "claude-sonnet-4-5"
             })

    assert {:ok, events} =
             open_sse_events(agent.uid, %{"model" => "primary", "input" => "hello"})

    body = terminal_response_body!(events)

    assert_receive {:gateway_request, request}
    assert request.path == "v1/messages"
    assert request.headers["x-api-key"] == "anthropic-key"
    assert request.headers["anthropic-version"] == "2023-06-01"
    assert request.body["model"] == "claude-sonnet-4-5"
    assert request.body["stream"] == true
    assert request.body["effort"] == "high"

    assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}] =
             request.body["messages"]

    assert_standard_stream(events)
    assert body["model"] == "claude-sonnet-4-5"

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello claude"

    assert body["usage"]["total_tokens"] == 5
  end

  test "claude provider can target OpenRouter anthropic-compatible messages endpoint" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "msg_openrouter_claude",
           "model" => request.body["model"],
           "content" => [%{"type" => "text", "text" => "hello via openrouter"}],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 3}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-openrouter-compatible",
               provider_kind: "claude",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "auth_mode" => "auth_token",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 },
                 "messages_path" => "messages"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "claude-openrouter-compatible",
               model: "anthropic/claude-sonnet-4.5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "max_output_tokens" => 32,
               "provider_options" => %{"reasoningEffort" => "xhigh"}
             })

    assert_receive {:gateway_request, request}
    assert request.path == "messages"
    assert request.headers["authorization"] == "Bearer sk-openrouter"
    refute Map.has_key?(request.headers, "x-api-key")
    assert request.headers["anthropic-version"] == "2023-06-01"
    assert request.body["model"] == "anthropic/claude-sonnet-4.5"
    assert request.body["max_tokens"] == 32
    assert request.body["effort"] == "max"

    assert body["model"] == "anthropic/claude-sonnet-4.5"

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello via openrouter"
  end

  test "azure openai provider supports deployment api-key auth and v1 bearer responses" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        cond do
          request.path == "openai/v1/responses" ->
            {:sse, 200, openai_response_stream_events("resp_azure_v1", "gpt-5.5", "v1")}

          request.headers["api-key"] == "azure-key" ->
            {:json, 200, chat_completion_body("gpt-deployment", "azure")}

          true ->
            {:json, 200, chat_completion_body("gpt-deployment", "azure path")}
        end
      end)

    assert {:ok, _deployment_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-deployment",
               provider_kind: "azure_openai",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "azure-key",
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-deployment",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "openai/deployments/gpt-deployment/chat/completions"
    assert request.query_string == "api-version=2025-04-01-preview"
    assert request.headers["api-key"] == "azure-key"
    refute Map.has_key?(request.headers, "authorization")
    refute Map.has_key?(request.body, "model")
    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) == "azure"

    assert {:ok, _openai_path_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-path-base",
               provider_kind: "azure_openai",
               base_url: "#{base_url}/openai",
               connection_options: %{
                 "api_key" => "Bearer prefixed-token",
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-path-base",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: path_body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "openai/deployments/gpt-deployment/chat/completions"
    assert request.headers["authorization"] == "Bearer prefixed-token"
    refute Map.has_key?(request.headers, "api-key")
    refute Map.has_key?(request.body, "model")

    assert get_in(path_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "azure path"

    assert {:ok, _v1_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-v1",
               provider_kind: "azure_openai",
               base_url: "#{base_url}/openai/v1",
               connection_options: %{
                 "api_key" => "Bearer entra-token",
                 "endpoint_kind" => "responses",
                 "auth_scheme" => "bearer",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-v1",
               model: "gpt-5.5"
             })

    assert {:ok, events} =
             open_sse_events(agent.uid, %{"model" => "primary", "input" => "hello"})

    v1_body = terminal_response_body!(events)

    assert_receive {:gateway_request, request}
    assert request.path == "openai/v1/responses"
    assert request.headers["authorization"] == "Bearer entra-token"
    refute Map.has_key?(request.headers, "api-key")
    assert request.body["model"] == "gpt-5.5"
    assert List.last(events)["type"] == "response.completed"
    assert v1_body["id"] == "resp_azure_v1"
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
  end

  defp collect_gateway_requests(0, requests), do: requests

  defp collect_gateway_requests(remaining, requests) do
    receive do
      {:gateway_request, request} ->
        collect_gateway_requests(remaining - 1, [request | requests])
    after
      1_000 ->
        flunk("timed out waiting for gateway request")
    end
  end

  defp request_input_text(%{body: %{"messages" => messages}}) when is_list(messages) do
    messages
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} -> message_content_text(content)
      _message -> nil
    end)
    |> case do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp request_input_text(_request), do: ""

  defp message_content_text(content) when is_binary(content), do: content

  defp message_content_text(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _part -> nil
    end)
  end

  defp message_content_text(_content), do: nil

  defp open_sse_events(agent_uid, request) do
    with {:ok, stream, _meta} <- AIGateway.open_sse_stream(agent_uid, request) do
      collect_sse_chunks(stream, [])
    end
  end

  defp collect_sse_chunks(stream, chunks) do
    with :ok <- UniversalAIClient.read(stream, 1) do
      receive do
        {:universal_ai_client, ref, :chunk, _seq, :sse, chunk} when ref == stream.ref ->
          chunks = [chunk | chunks]

          case terminal_sse_events(chunks) do
            [] -> collect_sse_chunks(stream, chunks)
            events -> {:ok, events}
          end

        {:universal_ai_client, ref, :done, _summary} when ref == stream.ref ->
          {:ok, decode_sse_chunks(chunks)}

        {:universal_ai_client, ref, :error, error} when ref == stream.ref ->
          {:error, error}

        {:universal_ai_client, ref, :aborted} when ref == stream.ref ->
          {:error, :stream_aborted}
      after
        1_000 ->
          _ = UniversalAIClient.cancel(stream)
          {:error, :native_stream_receive_timeout}
      end
    else
      {:error, _reason} ->
        case terminal_sse_events(chunks) do
          [] -> {:error, :native_stream_closed_before_terminal}
          events -> {:ok, events}
        end
    end
  end

  defp decode_sse_chunks(chunks) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> decode_sse_events()
  end

  defp terminal_sse_events(chunks) do
    events = decode_sse_chunks(chunks)

    case Enum.any?(
           events,
           &(Map.get(&1, "type") in [
               "response.completed",
               "response.failed",
               "response.incomplete"
             ])
         ) do
      true -> events
      false -> []
    end
  end

  defp terminal_response_body!(events) do
    assert %{"response" => body} =
             Enum.find(
               events,
               &(Map.get(&1, "type") in [
                   "response.completed",
                   "response.failed",
                   "response.incomplete"
                 ])
             )

    body
  end

  defp chat_stream_chunks(request, content) do
    id = "chatcmpl_native_#{System.unique_integer([:positive])}"
    model = request.body["model"] || "native-model"

    [
      chat_chunk(id, model, %{"role" => "assistant"}, nil),
      chat_chunk(id, model, %{"content" => content}, nil),
      Map.put(chat_chunk(id, model, %{}, "stop"), "usage", %{
        "prompt_tokens" => 2,
        "completion_tokens" => 3,
        "total_tokens" => 5
      })
    ]
  end

  defp chat_chunk(id, model, delta, finish_reason) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => 1_764_967_971,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  defp assert_standard_stream(events) do
    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]

    assert Enum.map(events, & &1["sequence_number"]) == Enum.to_list(0..7)
  end
end
