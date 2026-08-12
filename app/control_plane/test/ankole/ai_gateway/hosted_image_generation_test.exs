defmodule Ankole.AIGateway.HostedImageGenerationTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.StatefulResponses

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "maps a hosted OpenRouter rate limit to the public 429 envelope" do
    error =
      ImageGeneration.normalize_execution_error(
        {:universal_ai_request_failed,
         %{"code" => "provider_status_rejected", "provider_status" => 429}}
      )

    assert error.status == 429
    assert error.type == "rate_limit_error"
    assert error.code == "rate_limit_exceeded"
    assert error.param == nil
  end

  test "maps OpenRouter image-reference failures to the stable user error" do
    error =
      ImageGeneration.normalize_execution_error(
        {:upstream_response_failed, 400,
         %{"error_type" => "image_download_failed", "message" => "private URL detail"}}
      )

    assert error.status == 400
    assert error.type == "image_generation_user_error"
    assert error.code == "image_download_failed"
    refute error.message =~ "private URL detail"

    kernel_error =
      ImageGeneration.normalize_execution_error(
        {:universal_ai_request_failed, %{"code" => "moderation_blocked"}}
      )

    assert kernel_error.status == 400
    assert kernel_error.type == "image_generation_user_error"
    assert kernel_error.code == "moderation_blocked"
  end

  test "leaves non-image tool choices on the ordinary Responses fast path" do
    assert {:ok, nil} =
             ImageGeneration.prepare("agent_test", %{
               "tools" => [%{"type" => "custom", "name" => "run_code"}],
               "tool_choice" => %{"type" => "custom", "name" => "run_code"}
             })

    assert {:error, error} =
             ImageGeneration.prepare("agent_test", %{
               "tools" => [%{"type" => "function", "name" => "lookup"}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert error.param == "tool_choice"
    assert error.code == "invalid_value"
  end

  test "native image execution ignores a configured hosted fallback" do
    %{principal: agent} = agent_fixture()
    request = %{"tools" => [%{"type" => "image_generation", "output_format" => "png"}]}

    assert {:ok, nil} =
             ImageGeneration.prepare(agent.uid, request,
               main_runtime: %{"provider_kind" => "openai"}
             )

    provider_id = "unused-image-fallback-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "http://127.0.0.1:1/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Unused", "api_key" => "sk-unused"}]
               }
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, provider_id, "images/models"},
        [%{"id" => "openai/gpt-image-1"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, "images/models/openai/gpt-image-1/endpoints"},
        [
          %{
            "provider_slug" => "openai",
            "provider_tag" => "openai/gpt-image-1:openai",
            "supported_parameters" => %{}
          }
        ],
        60_000
      )

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: provider_id,
               model: "openai/gpt-image-1"
             })

    assert {:ok, nil} =
             ImageGeneration.prepare(agent.uid, request,
               main_runtime: %{"provider_kind" => "openai"}
             )

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", nil)

    assert {:error, error} =
             ImageGeneration.prepare(agent.uid, request,
               main_runtime: %{"provider_kind" => "openrouter"}
             )

    assert error.param == "tools[0].type"
    assert error.code == "unsupported_value"
    assert error.message =~ "image_generate model profile"
    assert error.message =~ "native image generation"
  end

  test "hosted image fallback keeps a configured main-model WebSocket" do
    %{principal: agent} = agent_fixture()
    suffix = System.unique_integer([:positive])
    main_provider_id = "compatible-hosted-websocket-#{suffix}"
    image_provider_id = "image-hosted-websocket-#{suffix}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: main_provider_id,
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "upstream_transport" => "websocket"
               },
               credential_pool: %{
                 "entries" => [%{"label" => "Main", "api_key" => "sk-main"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: main_provider_id,
               model: "compatible-main-model",
               provider_options: %{"serviceTier" => "fast"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: image_provider_id,
               provider_kind: "openrouter",
               base_url: "http://127.0.0.1:1/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Image", "api_key" => "sk-image"}]
               }
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, image_provider_id, "images/models"},
        [%{"id" => "openai/gpt-image-2"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, image_provider_id, "images/models/openai/gpt-image-2/endpoints"},
        [
          %{
            "provider_slug" => "openai",
            "provider_tag" => "openai/gpt-image-2:openai",
            "supported_parameters" => %{}
          }
        ],
        60_000
      )

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: image_provider_id,
               model: "openai/gpt-image-2"
             })

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "Run one tool.",
               "metadata" => %{"actor_event_id" => "hosted-websocket-event"},
               "tools" => [
                 %{"type" => "function", "name" => "command", "parameters" => %{}},
                 %{"type" => "image_generation"}
               ]
             })

    assert request.upstream.kind == :websocket_text
    assert request.upstream.method == "GET"
    assert request.upstream.url == "wss://compatible.test/v1/responses"
    assert request.response_context.stream == true
    assert request.response_context.provider_options["service_tier"] == "fast"
    refute Map.has_key?(request.response_context.request, "metadata")

    assert request.hosted_tools.public_request["metadata"] == %{
             "actor_event_id" => "hosted-websocket-event"
           }

    assert request.hosted_tools.image_generation["selected_model"] == "openai/gpt-image-2"
    refute Map.has_key?(request, :body)
  end

  test "requires JPEG or WebP when image output compression is set" do
    %{principal: agent} = agent_fixture()

    for tool <- [
          %{"type" => "image_generation", "output_compression" => 80},
          %{
            "type" => "image_generation",
            "output_compression" => 80,
            "output_format" => "png"
          }
        ] do
      assert {:error, error} =
               ImageGeneration.prepare(agent.uid, %{"tools" => [tool]},
                 main_runtime: %{"provider_kind" => "openai"}
               )

      assert error.param == "tools[0].output_compression"
      assert error.code == "invalid_value"

      assert error.message ==
               "output_compression requires output_format to be 'jpeg' or 'webp'."
    end

    for output_format <- ["jpeg", "webp"] do
      assert {:ok, nil} =
               ImageGeneration.prepare(
                 agent.uid,
                 %{
                   "tools" => [
                     %{
                       "type" => "image_generation",
                       "output_compression" => 80,
                       "output_format" => output_format
                     }
                   ]
                 },
                 main_runtime: %{"provider_kind" => "openai"}
               )
    end
  end

  @tag timeout: 30_000
  test "official OpenAI SDK crosses the real Files, Responses, SSE, and WebSocket gateway" do
    %{principal: agent} = agent_fixture()

    upstream_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => true,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{
                     "input_references" => %{"type" => "range", "min" => 0, "max" => 16}
                   }
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            main_model_response(request.body)

          {:post, "api/v1/images"} ->
            image_upstream_response(request.body)
        end
      end)

    _provider_id = configure_openrouter_profiles(agent.uid, upstream_url, "official-sdk")
    assert {:ok, token} = AIGatewayTokens.mint_for_agent(agent.uid)

    server_spec =
      Supervisor.child_spec(
        {Bandit,
         plug: AnkoleWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        shutdown: 1_000
      )

    server = start_supervised!(server_spec)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    agent_computer = Path.expand("../../../../agent_computer", __DIR__)

    {output, 0} =
      System.cmd("bun", ["test/fixtures/image-generation-official-sdk.ts"],
        cd: agent_computer,
        stderr_to_stdout: true,
        env: [
          {"ANKOLE_AI_GATEWAY_BASE_URL", "http://127.0.0.1:#{port}/api/v1/ai-gateway"},
          {"ANKOLE_AI_GATEWAY_API_KEY", token.api_key}
        ]
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Ankole.JSON.decode!()

    assert result["file_id"] =~ ~r/^file_[0-9a-f-]{36}$/
    assert result["image_id"] =~ ~r/^ig_[0-9a-f-]{36}$/
    assert result["websocket_reused_image_id"] =~ ~r/^ig_[0-9a-f-]{36}$/

    assert Enum.take(result["stream_events"], 8) == [
             "response.created",
             "response.in_progress",
             "response.output_item.added",
             "response.image_generation_call.in_progress",
             "response.image_generation_call.generating",
             "response.image_generation_call.partial_image",
             "response.image_generation_call.completed",
             "response.output_item.done"
           ]

    assert List.last(result["stream_events"]) == "response.completed"
  end

  test "executes image_generation inside AIGateway without leaking the private tool" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => ["moderation"],
                   "supported_parameters" => %{
                     "quality" => %{
                       "type" => "enum",
                       "values" => ["auto", "low", "medium", "high"]
                     },
                     "input_references" => %{"type" => "range", "min" => 0, "max" => 16}
                   }
                 },
                 %{
                   "provider_slug" => "openai-backup",
                   "provider_tag" => "openai/gpt-image-2:openai-backup",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => ["moderation"],
                   "supported_parameters" => %{
                     "quality" => %{
                       "type" => "enum",
                       "values" => ["auto", "low", "medium", "high"]
                     },
                     "input_references" => %{"type" => "range", "min" => 0, "max" => 16}
                   }
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            send(test_pid, {:main_request, request.body})
            main_model_response(request.body)

          {:post, "api/v1/images"} ->
            send(test_pid, {:image_request, request.body})

            {:json, 200,
             %{
               "data" => [
                 %{
                   "b64_json" => @png_base64,
                   "media_type" => "image/png",
                   "revised_prompt" => "A moonlit lake with deep blue reflections"
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
             }}
        end
      end)

    provider_id = "openrouter-hosted-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/api/v1",
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => []}
               },
               credential_pool: %{
                 "entries" => [%{"label" => "Hosted test", "api_key" => "sk-hosted-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "test/main-model"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: provider_id,
               model: "openai/gpt-image-2"
             })

    assert {:ok, %{body: response}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Generate a quiet lake at night.",
               "tools" => [
                 %{
                   "type" => "image_generation",
                   "model" => "openai/gpt-image-2",
                   "quality" => "high",
                   "moderation" => "low"
                 }
               ],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert response["id"] =~ ~r/^resp_[0-9a-f]{32}$/
    assert response["model"] == "test/main-model"
    assert response["status"] == "completed"
    refute Map.has_key?(response, "hosted_tool_metadata")

    assert [image, message] = response["output"]
    assert image["id"] =~ ~r/^ig_[0-9a-f-]{36}$/
    assert image["type"] == "image_generation_call"
    assert image["status"] == "completed"
    assert image["result"] == @png_base64
    assert image["revised_prompt"] == "A moonlit lake with deep blue reflections"
    refute Map.has_key?(image, "mime_type")
    assert message["type"] == "message"

    encoded_response = Ankole.JSON.encode!(response)
    refute encoded_response =~ "__ankole_hosted_image_generation"
    refute encoded_response =~ "call_private_image"

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.uid, image["id"], payload?: true)

    assert artifact.payload == Base.decode64!(@png_base64)
    assert artifact.expires_at

    assert_receive {:main_request, first_main}
    assert_receive {:image_request, image_request}
    assert_receive {:main_request, second_main}

    hidden_tool =
      Enum.find(first_main["tools"], fn tool ->
        String.starts_with?(tool["function"]["name"], "__ankole_hosted_image_generation")
      end)

    assert hidden_tool["type"] == "function"
    refute Enum.any?(first_main["tools"], &(&1["type"] == "image_generation"))
    refute Ankole.JSON.encode!(first_main) =~ "openrouter:image_generation"

    assert image_request["model"] == "openai/gpt-image-2"
    assert image_request["prompt"] == "A moonlit lake in a calm, cinematic style"
    assert image_request["quality"] == "high"
    assert image_request["n"] == 1

    assert image_request["provider"] == %{
             "only" => [
               "openai/gpt-image-2:openai",
               "openai/gpt-image-2:openai-backup"
             ],
             "allow_fallbacks" => true,
             "require_parameters" => true,
             "options" => %{
               "openai" => %{"moderation" => "low"},
               "openai-backup" => %{"moderation" => "low"}
             }
           }

    assert Enum.any?(second_main["messages"], fn message ->
             message["role"] == "tool" and message["tool_call_id"] == "call_private_image"
           end)
  end

  test "non-stream hosted image failure does not replay after Provider output" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(&hosted_pool_retry_response(&1, test_pid, false))

    provider_id =
      configure_openrouter_profiles(agent.uid, base_url, "pool-non-stream", pooled_entries())

    assert {:error,
            %{
              status: 429,
              type: "rate_limit_error",
              code: "rate_limit_exceeded"
            }} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "Generate an image after rotating the limited account.",
                 "tools" => [%{"type" => "image_generation"}],
                 "tool_choice" => %{"type" => "image_generation"}
               },
               credential_retry_sleep: fn delay -> send(test_pid, {:image_retry_delay, delay}) end,
               credential_retry_jitter: &Function.identity/1
             )

    assert_receive {:hosted_main_attempt, "Bearer sk-image-first"}
    assert_receive {:hosted_image_attempt, "Bearer sk-image-first"}
    refute_receive {:image_retry_delay, _delay}
    refute_receive {:hosted_main_attempt, _authorization}
    refute_receive {:hosted_image_attempt, _authorization}

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 429
    assert by_id["second"]["status"] == "ok"
    refute get_in(by_id["first"], ["usage", "image_gen"])
    refute get_in(by_id["second"], ["usage", "image_gen"])
  end

  test "stream hosted image failure does not replay after Provider output" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(&hosted_pool_retry_response(&1, test_pid, true))

    provider_id =
      configure_openrouter_profiles(agent.uid, base_url, "pool-stream", pooled_entries())

    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "Generate a streamed image after rotating the limited account.",
                 "tools" => [%{"type" => "image_generation", "partial_images" => 1}],
                 "tool_choice" => %{"type" => "image_generation"}
               },
               credential_retry_sleep: fn delay -> send(test_pid, {:image_retry_delay, delay}) end,
               credential_retry_jitter: &Function.identity/1
             )

    events = collect_response_events(stream, [])
    types = Enum.map(events, & &1["type"])

    assert Enum.count(types, &(&1 == "response.created")) == 1
    assert Enum.count(types, &(&1 == "response.in_progress")) == 1
    assert Enum.count(types, &(&1 == "response.failed")) == 1
    refute Enum.any?(types, &String.starts_with?(&1, "response.image_generation_call."))
    refute "response.completed" in types

    response_ids =
      events
      |> Enum.flat_map(fn event ->
        [get_in(event, ["response", "id"]), event["response_id"]]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert [_one_response_id] = response_ids
    assert_receive {:hosted_main_attempt, "Bearer sk-image-first"}
    assert_receive {:hosted_image_attempt, "Bearer sk-image-first"}
    refute_receive {:image_retry_delay, _delay}
    refute_receive {:hosted_main_attempt, _authorization}
    refute_receive {:hosted_image_attempt, _authorization}

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 429
    assert by_id["second"]["status"] == "ok"
    refute get_in(by_id["first"], ["usage", "image_gen"])
    refute get_in(by_id["second"], ["usage", "image_gen"])
  end

  test "hosted composition rotates a failing main provider without touching the image pool" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{}
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            authorization = request.headers["authorization"]
            send(test_pid, {:main_pool_attempt, authorization})

            case authorization do
              "Bearer sk-main-first" ->
                {:json, 429,
                 %{
                   "error" => %{
                     "code" => "rate_limited",
                     "message" => "first main account is limited"
                   }
                 }}

              "Bearer sk-main-second" ->
                main_model_response(request.body)
            end

          {:post, "api/v1/images"} ->
            authorization = request.headers["authorization"]
            send(test_pid, {:image_pool_attempt, authorization})
            image_upstream_response(request.body)
        end
      end)

    main_provider_id = "openrouter-hosted-main-#{System.unique_integer([:positive])}"
    image_provider_id = "openrouter-hosted-image-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: main_provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/api/v1",
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => []}
               },
               credential_pool: %{
                 "entries" => [
                   %{"id" => "main-first", "label" => "Main first", "api_key" => "sk-main-first"},
                   %{
                     "id" => "main-second",
                     "label" => "Main second",
                     "api_key" => "sk-main-second"
                   }
                 ]
               }
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: image_provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/api/v1",
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => []}
               },
               credential_pool: %{
                 "entries" => [
                   %{"id" => "image-only", "label" => "Image only", "api_key" => "sk-image-only"}
                 ]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: main_provider_id,
               model: "test/main-model"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: image_provider_id,
               model: "openai/gpt-image-2"
             })

    assert {:ok, %{body: response}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "Generate an image after rotating the main account.",
                 "tools" => [%{"type" => "image_generation"}],
                 "tool_choice" => %{"type" => "image_generation"}
               },
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert [%{"type" => "image_generation_call", "result" => @png_base64}, _message] =
             response["output"]

    assert_receive {:main_pool_attempt, "Bearer sk-main-first"}
    assert_receive {:main_pool_attempt, "Bearer sk-main-second"}
    assert_receive {:image_pool_attempt, "Bearer sk-image-only"}
    assert_receive {:main_pool_attempt, "Bearer sk-main-second"}
    refute_receive {:main_pool_attempt, _authorization}
    refute_receive {:image_pool_attempt, _authorization}

    assert {:ok, main_projection} = ProviderConfigs.get_provider(main_provider_id)
    main_by_id = Map.new(main_projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert main_by_id["main-first"]["status"] == "exhausted"
    assert main_by_id["main-first"]["provider_status"] == 429
    assert main_by_id["main-second"]["status"] == "ok"

    assert {:ok, image_projection} = ProviderConfigs.get_provider(image_provider_id)
    [image_entry] = image_projection["credential_pool"]["entries"]
    assert image_entry["id"] == "image-only"
    assert image_entry["status"] == "ok"
    assert get_in(image_entry, ["usage", "image_gen", "total_tokens"]) == 3
  end

  test "streams official partial-image events and persists before output_item.done" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    telemetry_handler = "hosted-stream-owner-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:ankole, :ai_gateway, :hosted_image_generation],
        fn _event, measurements, metadata, pid ->
          send(pid, {:hosted_stream_telemetry, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => true,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{}
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            main_model_response(request.body)

          {:post, "api/v1/images"} ->
            send(test_pid, {:streaming_image_request, request.body})

            {:sse, 200,
             [
               %{
                 "type" => "image_generation.partial_image",
                 "partial_image_index" => 0,
                 "b64_json" => @png_base64
               },
               %{
                 "type" => "image_generation.completed",
                 "b64_json" => @png_base64,
                 "media_type" => "image/png",
                 "revised_prompt" => "A streamed moonlit lake",
                 "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
               }
             ]}
        end
      end)

    provider_id = configure_openrouter_profiles(agent.uid, base_url, "stream")
    assert is_binary(provider_id)

    assert {:ok, stream, meta} =
             AIGateway.open_sse_stream(agent.uid, %{
               "model" => "primary",
               "input" => "Generate a streaming lake image.",
               "max_tool_calls" => 1,
               "stream" => true,
               "tools" => [%{"type" => "image_generation", "partial_images" => 1}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert (meta["api_resolver"] || meta[:api_resolver]) == "hosted_responses"

    events = collect_response_events(stream, [])
    event_types = Enum.map(events, & &1["type"])

    assert Enum.filter(event_types, &String.starts_with?(&1, "response.image_generation_call")) ==
             [
               "response.image_generation_call.in_progress",
               "response.image_generation_call.generating",
               "response.image_generation_call.partial_image",
               "response.image_generation_call.completed"
             ]

    partial = Enum.find(events, &(&1["type"] == "response.image_generation_call.partial_image"))
    assert partial["partial_image_index"] == 0
    assert partial["partial_image_b64"] == @png_base64

    sequences = Enum.map(events, & &1["sequence_number"])
    assert sequences == Enum.to_list(0..(length(sequences) - 1))

    done =
      Enum.find(events, fn event ->
        event["type"] == "response.output_item.done" and
          get_in(event, ["item", "type"]) == "image_generation_call"
      end)

    assert done["item"]["result"] == @png_base64

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.uid, done["item"]["id"], payload?: true)

    assert artifact.payload == Base.decode64!(@png_base64)

    assert_receive {:hosted_stream_telemetry, _measurements, %{result: "success"}}, 1_000
    refute_receive {:hosted_stream_telemetry, _measurements, _metadata}, 100

    assert_receive {:streaming_image_request, image_request}
    assert image_request["stream"] == true
    refute Map.has_key?(image_request, "partial_images")
    assert image_request["n"] == 1

    encoded_events = Ankole.JSON.encode!(events)
    refute encoded_events =~ "__ankole_hosted_image_generation"
    refute encoded_events =~ "call_private_image"
  end

  test "stream persistence failure cancels the owner and emits one failed terminal" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    telemetry_handler = "hosted-stream-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:ankole, :ai_gateway, :hosted_image_generation],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:hosted_stream_failure_telemetry, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => true,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{}
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            main_model_response(request.body)

          {:post, "api/v1/images"} ->
            {:sse, 200,
             [
               %{
                 "type" => "image_generation.completed",
                 "b64_json" => "not-base64",
                 "media_type" => "image/png"
               }
             ]}
        end
      end)

    _provider_id = configure_openrouter_profiles(agent.uid, base_url, "stream-failure")

    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(agent.uid, %{
               "model" => "primary",
               "input" => "Generate an invalid image.",
               "stream" => true,
               "tools" => [%{"type" => "image_generation"}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert %{telemetry_spec: %{hosted_tools: %{image_generation: %{}}}} =
             :sys.get_state(stream.pid)

    events = collect_response_events(stream, [])

    terminal_events =
      Enum.filter(
        events,
        &(&1["type"] in ["response.completed", "response.failed", "response.incomplete"])
      )

    assert [%{"type" => "response.failed"} = failed] = terminal_events
    assert get_in(failed, ["response", "error", "code"]) == "upstream_error"

    monitor = Process.monitor(stream.pid)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000

    assert_receive {:hosted_stream_failure_telemetry, %{result: "failure"}}, 1_000
    refute_receive {:hosted_stream_failure_telemetry, _metadata}, 100
  end

  test "hosted provider failures keep a safe status for Worker retry classification" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{}
                 }
               ]
             }}

          {:post, "api/v1/chat/completions"} ->
            send(test_pid, :hosted_route_main_attempt)
            main_model_response(request.body)

          {:post, "api/v1/images"} ->
            send(test_pid, :hosted_route_image_attempt)
            {:json, 503, %{"error" => %{"message" => "private provider detail"}}}
        end
      end)

    provider_id = configure_openrouter_profiles(agent.uid, base_url, "provider-failure")

    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(agent.uid, %{
               "model" => "primary",
               "input" => "Generate an image.",
               "stream" => true,
               "tools" => [%{"type" => "image_generation"}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    events = collect_response_events(stream, [])

    assert [%{"response" => %{"error" => error}}] =
             Enum.filter(events, &(&1["type"] == "response.failed"))

    assert error["provider_status"] == 503
    assert error["retryable"] == true
    assert error["code"] == "upstream_error"
    refute Ankole.JSON.encode!(events) =~ "private provider detail"

    assert_receive :hosted_route_main_attempt
    assert_receive :hosted_route_image_attempt
    refute_receive :hosted_route_main_attempt
    refute_receive :hosted_route_image_attempt

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    assert [%{"status" => "ok"}] = projection["credential_pool"]["entries"]
  end

  test "stateful history keeps an image call id and resolves it before an edit" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:get, "api/v1/models"} ->
            {:json, 200, %{"data" => []}}

          {:get, "api/v1/images/models"} ->
            {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

          {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
            {:json, 200,
             %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{
                     "input_references" => %{"type" => "range", "min" => 0, "max" => 16}
                   }
                 }
               ]
             }}
        end
      end)

    _provider_id = configure_openrouter_profiles(agent.uid, base_url, "stateful-edit")

    assert {:ok, conversation} =
             Conversations.ensure_conversation(agent.uid, "stateful-image-edit")

    assert {:ok, message} =
             StatefulResponses.start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: conversation.id,
               request_items: [%{"role" => "user", "content" => "draw a lake"}]
             })

    image_id = "ig_#{Ankole.Ecto.UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(agent.uid, image_id, @png_base64, "image/png",
               message_id: message.id
             )

    stored_image = %{
      "id" => image_id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => nil,
      "revised_prompt" => "a quiet lake"
    }

    assert {:ok, _message} = StatefulResponses.commit_complete(message, [stored_image])

    assert {:ok, prepared} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "change the sky to night",
               "store" => true,
               "previous_response_id" => "resp_#{message.id}",
               "tools" => [%{"type" => "image_generation", "action" => "edit"}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert [reference] =
             get_in(prepared, [
               :hosted_tools,
               :image_generation,
               "resolved_references"
             ])

    assert get_in(prepared, [:upstream, :timeout, :total_ms]) == 1_800_000
    assert get_in(prepared, [:limits, :max_response_bytes]) == 128 * 1024 * 1024
    assert get_in(prepared, [:limits, :max_sse_event_bytes]) == 128 * 1024 * 1024
    assert get_in(prepared, [:limits, :max_websocket_text_bytes]) == 128 * 1024 * 1024

    assert reference["id"] == image_id
    assert reference["image_url"] == "data:image/png;base64,#{@png_base64}"
  end

  defp main_model_response(body) do
    if Enum.any?(body["messages"], &(&1["role"] == "tool")) do
      {:json, 200, chat_completion_body("test/main-model", "The image is ready.")}
    else
      hidden_tool =
        body["tools"]
        |> Enum.find(
          &String.starts_with?(&1["function"]["name"], "__ankole_hosted_image_generation")
        )

      hidden_name = get_in(hidden_tool, ["function", "name"])
      properties = get_in(hidden_tool, ["function", "parameters", "properties"])
      action = properties |> get_in(["action", "enum"]) |> List.first()
      reference_refs = get_in(properties, ["input_image_refs", "items", "enum"]) || []
      selected_refs = if action == "edit", do: Enum.take(reference_refs, 1), else: []

      {:json, 200,
       %{
         "id" => "chatcmpl_private_image",
         "object" => "chat.completion",
         "created" => 1_764_967_971,
         "model" => "test/main-model",
         "choices" => [
           %{
             "index" => 0,
             "message" => %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "call_private_image",
                   "type" => "function",
                   "function" => %{
                     "name" => hidden_name,
                     "arguments" =>
                       Ankole.JSON.encode!(%{
                         "prompt" => "A moonlit lake in a calm, cinematic style",
                         "action" => action,
                         "input_image_refs" => selected_refs
                       })
                   }
                 }
               ]
             },
             "finish_reason" => "tool_calls"
           }
         ],
         "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3, "total_tokens" => 13}
       }}
    end
  end

  defp image_upstream_response(%{"stream" => true}) do
    {:sse, 200,
     [
       %{
         "type" => "image_generation.partial_image",
         "partial_image_index" => 0,
         "b64_json" => @png_base64
       },
       %{
         "type" => "image_generation.completed",
         "b64_json" => @png_base64,
         "media_type" => "image/png",
         "revised_prompt" => "A streamed image",
         "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
       }
     ]}
  end

  defp image_upstream_response(_request) do
    {:json, 200,
     %{
       "data" => [
         %{
           "b64_json" => @png_base64,
           "media_type" => "image/png",
           "revised_prompt" => "An edited image"
         }
       ],
       "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
     }}
  end

  defp configure_openrouter_profiles(
         agent_uid,
         base_url,
         suffix,
         entries \\ [%{"label" => "Hosted test", "api_key" => "sk-hosted-test"}]
       ) do
    provider_id =
      "openrouter-hosted-#{suffix}-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/api/v1",
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => []}
               },
               credential_pool: %{
                 "entries" => entries
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: provider_id,
               model: "test/main-model"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "image_generate", %{
               provider_id: provider_id,
               model: "openai/gpt-image-2"
             })

    provider_id
  end

  defp pooled_entries do
    [
      %{
        "id" => "first",
        "label" => "First image credential",
        "api_key" => "sk-image-first"
      },
      %{
        "id" => "second",
        "label" => "Second image credential",
        "api_key" => "sk-image-second"
      }
    ]
  end

  defp hosted_pool_retry_response(request, test_pid, stream?) do
    case {request.method, request.path} do
      {:get, "api/v1/models"} ->
        {:json, 200, %{"data" => []}}

      {:get, "api/v1/images/models"} ->
        {:json, 200, %{"data" => [%{"id" => "openai/gpt-image-2"}]}}

      {:get, "api/v1/images/models/openai/gpt-image-2/endpoints"} ->
        {:json, 200,
         %{
           "endpoints" => [
             %{
               "provider_slug" => "openai",
               "provider_tag" => "openai/gpt-image-2:openai",
               "supports_streaming" => stream?,
               "allowed_passthrough_parameters" => [],
               "supported_parameters" => %{}
             }
           ]
         }}

      {:post, "api/v1/chat/completions"} ->
        send(test_pid, {:hosted_main_attempt, request.headers["authorization"]})
        main_model_response(request.body)

      {:post, "api/v1/images"} ->
        authorization = request.headers["authorization"]
        send(test_pid, {:hosted_image_attempt, authorization})

        case authorization do
          "Bearer sk-image-first" ->
            reset_at = DateTime.utc_now(:second) |> DateTime.add(600) |> DateTime.to_unix()

            {:json, 429, [{"x-codex-primary-reset-at", Integer.to_string(reset_at)}],
             %{"error" => %{"code" => "rate_limited", "message" => "first image account limited"}}}

          "Bearer sk-image-second" when stream? ->
            {:sse, 200,
             [
               %{
                 "type" => "image_generation.partial_image",
                 "partial_image_index" => 0,
                 "b64_json" => @png_base64
               },
               %{
                 "type" => "image_generation.completed",
                 "b64_json" => @png_base64,
                 "media_type" => "image/png",
                 "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
               }
             ]}

          "Bearer sk-image-second" ->
            image_upstream_response(request)
        end
    end
  end

  defp collect_response_events(stream, acc) do
    read_result = AIGateway.read_response_stream(stream, 1)

    receive do
      {:ai_gateway_response_stream, ref, :events, events, :continue}
      when ref == stream.ref ->
        collect_response_events(stream, acc ++ events)

      {:ai_gateway_response_stream, ref, :events, events, {:terminal, _outcome}}
      when ref == stream.ref ->
        acc ++ events
    after
      5_000 ->
        flunk("timed out waiting for hosted image stream after #{inspect(read_result)}")
    end
  end
end
