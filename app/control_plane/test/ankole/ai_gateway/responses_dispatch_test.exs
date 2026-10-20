defmodule Ankole.AIGateway.ResponsesDispatchTest do
  alias Ankole.AIGateway.CompactionRequests
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures

  alias Ankole.AIGateway.CredentialPool

  import ExUnit.CaptureLog

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "responses dispatch rejects stateful HTTP fields before provider dispatch" do
    %{principal: agent} = agent_fixture()

    for {field, request} <- [
          {"previous_response_id",
           %{"model" => "primary", "input" => "hello", "previous_response_id" => "resp_old"}},
          {"conversation",
           %{"model" => "primary", "input" => "hello", "conversation" => "conv_old"}},
          {"store", %{"model" => "primary", "input" => "hello", "store" => true}}
        ] do
      assert {:error, {:stateful_http_field_forbidden, ^field}} =
               AIGateway.create_response(agent.uid, request)

      assert {:error, {:stateful_http_field_forbidden, ^field}} =
               AIGateway.open_sse_stream(agent.uid, Map.put(request, "stream", true))
    end

    refute_receive {:gateway_request, _request}
  end

  test "responses dispatch applies provider options" do
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-responses-main",
               model: "gpt-5.5",
               provider_options: %{
                 "reasoningEffort" => "minimal",
                 "serviceTier" => "fast"
               }
             })

    assert {:ok, %{body: body, model_ref: model_ref}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "stream" => true,
               "store" => false,
               "service_tier" => "agent_computer",
               "prompt_cache_key" => "cache-a"
             })

    assert_receive {:gateway_request, request}
    assert request.method == :post
    assert request.path == "v1/responses"
    assert request.headers["authorization"] == "Bearer sk-openai"
    assert request.body["model"] == "gpt-5.5"
    assert request.body["stream"] == false
    assert request.body["input"] == "hello"
    assert request.body["store"] == false
    assert request.body["reasoning"] == %{"effort" => "minimal"}
    refute Map.has_key?(request.body, "reasoningEffort")
    assert request.body["service_tier"] == "fast"
    assert request.body["prompt_cache_key"] == "cache-a"

    assert body["id"] == "resp_test"
    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "primary"
    assert model_ref["provider_id"] == "openai-responses-main"
  end

  test "openai-compatible Responses preserves namespaced replay without current tools" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_compaction_replay",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-compaction-replay"
    )

    assert {:ok, %{body: %{"id" => "resp_compaction_replay"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "tools" => nil,
               "client_metadata" => %{
                 "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
               },
               "input" => [
                 %{"type" => "additional_tools", "role" => "developer", "tools" => []},
                 %{
                   "type" => "custom_tool_call",
                   "call_id" => "call_apply_patch",
                   "namespace" => "functions",
                   "name" => "apply_patch",
                   "input" => "*** Begin Patch"
                 },
                 %{
                   "type" => "custom_tool_call_output",
                   "call_id" => "call_apply_patch",
                   "output" => "Done!"
                 }
               ]
             })

    assert_receive {:gateway_request, request}
    assert request.body["store"] == false
    assert request.body["tools"] == []

    # The default connection does not declare official OpenAI tool support, so
    # the replay survives in the emulated function space instead of verbatim.
    [provider_call, provider_output] = request.body["input"]
    assert provider_call["type"] == "function_call"
    assert provider_call["namespace"] == "functions"
    assert provider_call["name"] == "apply_patch"
    assert provider_call["arguments"] == Ankole.JSON.encode!(%{"input" => "*** Begin Patch"})
    assert provider_output["type"] == "function_call_output"
    assert provider_output["call_id"] == provider_call["call_id"]
  end

  test "openai-compatible Responses passes the hosted web_search declaration through" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_hosted_web_search",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-hosted-search"
    )

    assert {:ok, %{body: %{"id" => "resp_hosted_web_search"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "current weather in Berlin",
               "tools" => [%{"type" => "web_search"}]
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == [%{"type" => "web_search"}]
  end

  test "ChatGPT complete responses collect SSE and strip unsupported request fields" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         openai_response_stream_events(
           "resp_chatgpt_complete",
           "gpt-5.6-sol",
           "stream collected"
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-complete-response",
               provider_kind: "chatgpt_subscription",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "enterprise",
                     "label" => "Enterprise",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "chatgpt-complete-response",
               model: "gpt-5.6-sol"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "max_output_tokens" => 1_024,
               "truncation" => "auto"
             })

    assert_receive {:gateway_request, request}
    assert request.path == "responses"
    assert request.headers["accept"] == "text/event-stream"
    assert request.body["stream"] == true
    refute Map.has_key?(request.body, "max_output_tokens")
    refute Map.has_key?(request.body, "truncation")

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "stream collected"
  end

  test "tool_choice none allows a positive budget with mixed effect owners during preparation" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "must not dispatch during preparation"}}}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-mixed-tool-budget-none"
    )

    assert {:ok, %{driver: :response_stream}} =
             ResponsesPreparation.prepare(agent.uid, %{
               "model" => "primary",
               "input" => "Do not run tools.",
               "tools" => [
                 %{
                   "type" => "function",
                   "name" => "lookup",
                   "allowed_callers" => ["programmatic"],
                   "parameters" => %{"type" => "object", "properties" => %{}}
                 },
                 %{"type" => "programmatic_tool_calling"},
                 %{"type" => "web_search"}
               ],
               "tool_choice" => "none",
               "max_tool_calls" => 1
             })

    refute_receive {:gateway_request, _request}
  end

  test "native image generation passes through, persists non-stream bytes, and accounts usage" do
    %{principal: agent} = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, [{"x-codex-primary-used-percent", "18"}],
         %{
           "id" => "resp_native_image",
           "object" => "response",
           "status" => "completed",
           "model" => "gpt-5.6-sol",
           "output" => [native_image_item(image_id)],
           "usage" => %{"input_tokens" => 11, "output_tokens" => 4, "total_tokens" => 15},
           "tool_usage" => %{
             "image_gen" => %{"input_tokens" => 7, "output_tokens" => 2, "total_tokens" => 9}
           }
         }}
      end)

    provider_id = create_native_image_provider!(agent, base_url, "non-stream")

    assert {:ok, %{body: response}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Generate a small image.",
               "tools" => [%{"type" => "image_generation", "output_format" => "png"}],
               "tool_choice" => %{"type" => "image_generation"}
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == [%{"type" => "image_generation", "output_format" => "png"}]
    assert request.body["tool_choice"] == %{"type" => "image_generation"}
    assert get_in(response, ["output", Access.at(0), "result"]) == native_png_base64()
    assert get_in(response, ["tool_usage", "image_gen", "total_tokens"]) == 9

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.uid, image_id, payload?: true)

    assert artifact.payload == Base.decode64!(native_png_base64())

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    [entry] = projection["credential_pool"]["entries"]
    assert entry["rate_limits"]["x-codex-primary-used-percent"] == "18"
    assert get_in(entry, ["usage", "model", "total_tokens"]) == 15
    assert get_in(entry, ["usage", "image_gen", "total_tokens"]) == 9
  end

  test "native image stream persists bytes before completion and keeps separate tool usage" do
    %{principal: agent} = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    image_item = native_image_item(image_id)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         [
           %{
             "type" => "response.created",
             "sequence_number" => 0,
             "response" => %{
               "id" => "resp_native_image_stream",
               "object" => "response",
               "status" => "in_progress",
               "output" => []
             }
           },
           %{
             "type" => "response.image_generation_call.completed",
             "sequence_number" => 1,
             "item_id" => image_id,
             "output_index" => 0
           },
           %{
             "type" => "response.output_item.done",
             "sequence_number" => 2,
             "output_index" => 0,
             "item" => image_item
           },
           %{
             "type" => "response.completed",
             "sequence_number" => 3,
             "response" => %{
               "id" => "resp_native_image_stream",
               "object" => "response",
               "status" => "completed",
               "model" => "gpt-5.6-sol",
               "output" => [image_item],
               "usage" => %{"input_tokens" => 13, "output_tokens" => 5, "total_tokens" => 18},
               "tool_usage" => %{
                 "image_gen" => %{
                   "input_tokens" => 8,
                   "output_tokens" => 3,
                   "total_tokens" => 11
                 }
               }
             }
           }
         ]}
      end)

    provider_id = create_native_image_provider!(agent, base_url, "stream")

    assert {:ok, events} =
             open_sse_events(agent.uid, %{
               "model" => "primary",
               "input" => "Generate a streamed image.",
               "tools" => [%{"type" => "image_generation", "output_format" => "png"}]
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == [%{"type" => "image_generation", "output_format" => "png"}]

    completed_index =
      Enum.find_index(events, &(&1["type"] == "response.image_generation_call.completed"))

    done_index = Enum.find_index(events, &(&1["type"] == "response.output_item.done"))
    terminal_index = Enum.find_index(events, &(&1["type"] == "response.completed"))
    assert completed_index < done_index
    assert done_index < terminal_index

    terminal = Enum.at(events, terminal_index)
    assert get_in(terminal, ["response", "tool_usage", "image_gen", "total_tokens"]) == 11

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.uid, image_id, payload?: true)

    assert artifact.payload == Base.decode64!(native_png_base64())

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    [entry] = projection["credential_pool"]["entries"]
    assert get_in(entry, ["usage", "model", "total_tokens"]) == 18
    assert get_in(entry, ["usage", "image_gen", "total_tokens"]) == 11
  end

  test "OpenRouter chat requests keep prompt cache and session identifiers separate" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "chatcmpl_cache_key",
           "object" => "chat.completion",
           "created" => 1_764_967_971,
           "model" => request.body["model"],
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant", "content" => "ok"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-cache-key",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-cache-key",
               model: "openai/gpt-5.6-sol"
             })

    assert {:ok, %{body: _body}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "hello",
                 "prompt_cache_key" => "shared-prefix",
                 "session_id" => "body-session"
               },
               request_context: %{"headers" => %{"x-session-id" => "header-session"}}
             )

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.body["prompt_cache_key"] == "shared-prefix"
    assert request.body["session_id"] == "body-session"

    assert {:ok, %{body: _header_body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello from a header"},
               request_context: %{"headers" => %{"x-session-id" => "header-session"}}
             )

    assert_receive {:gateway_request, header_request}
    assert header_request.body["session_id"] == "header-session"
    refute Map.has_key?(header_request.body, "prompt_cache_key")

    max_session_id = String.duplicate("s", 256)

    assert {:ok, %{body: _max_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello at the session limit",
               "session_id" => max_session_id
             })

    assert_receive {:gateway_request, max_request}
    assert max_request.body["session_id"] == max_session_id

    assert {:ok, %{body: _noop_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello again"
             })

    assert_receive {:gateway_request, keyless_request}
    refute Map.has_key?(keyless_request.body, "prompt_cache_key")
    refute Map.has_key?(keyless_request.body, "session_id")
  end

  test "OpenRouter rejects invalid explicit session identifiers before dispatch" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-session",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-invalid-session",
               model: "openai/gpt-5.6-sol"
             })

    for {value, code} <- [
          {"", "invalid_value"},
          {"   ", "invalid_value"},
          {String.duplicate("s", 257), "invalid_value"},
          {123, "invalid_type"}
        ] do
      assert {:error,
              %OpenAIError{
                status: 400,
                param: "session_id",
                code: ^code
              }} =
               AIGateway.create_response(agent.uid, %{
                 "model" => "primary",
                 "input" => "hello",
                 "session_id" => value
               })
    end

    refute_receive {:gateway_request, _request}
  end

  test "OpenRouter chat requests annotate Anthropic models for prompt caching" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "chatcmpl_cache_control",
           "object" => "chat.completion",
           "created" => 1_764_967_971,
           "model" => request.body["model"],
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant", "content" => "ok"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-cache-control",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    for model <- ["anthropic/claude-opus-5", "~anthropic/claude-opus-latest"] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openrouter-cache-control",
                 model: model
               })

      assert {:ok, %{body: _body}} =
               AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

      assert_receive {:gateway_request, request}
      assert request.body["model"] == model
      assert request.body["cache_control"] == %{"type" => "ephemeral"}
    end

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-cache-control",
               model: "openai/gpt-5.6-sol"
             })

    assert {:ok, %{body: _openai_body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, openai_request}
    refute Map.has_key?(openai_request.body, "cache_control")
  end

  test "stateless responses preserve the Codex encrypted reasoning round trip" do
    %{principal: agent} = agent_fixture()

    encrypted_reasoning = %{
      "id" => "rs_codex_encrypted",
      "type" => "reasoning",
      "encrypted_content" => "ENCRYPTED_CODEX_STATE",
      "summary" => []
    }

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_codex_encrypted",
           "object" => "response",
           "status" => "completed",
           "output" => [encrypted_reasoning],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-codex-encrypted",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-codex-encrypted",
               model: "gpt-5.4"
             })

    assert {:ok, %{body: first_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "start",
               "include" => ["reasoning.encrypted_content"],
               "prompt_cache_key" => "codex-thread-1",
               "store" => false
             })

    assert_receive {:gateway_request, first_request}
    assert first_request.body["include"] == ["reasoning.encrypted_content"]
    assert first_request.body["prompt_cache_key"] == "codex-thread-1"

    [wrapped_reasoning] = first_body["output"]
    assert wrapped_reasoning == encrypted_reasoning

    assert {:ok, %{body: second_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 wrapped_reasoning,
                 %{"type" => "message", "role" => "user", "content" => "continue"}
               ],
               "include" => ["reasoning.encrypted_content"],
               "store" => false
             })

    assert_receive {:gateway_request, second_request}

    assert List.first(second_request.body["input"])["encrypted_content"] ==
             "ENCRYPTED_CODEX_STATE"

    assert List.first(second_body["output"])["encrypted_content"] ==
             "ENCRYPTED_CODEX_STATE"
  end

  test "chat providers round-trip AIGateway encrypted tool parameters" do
    %{principal: agent} = agent_fixture()
    secret = "delegate the private investigation"

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "chatcmpl_encrypted_tool",
           "object" => "chat.completion",
           "created" => 1_764_967_971,
           "model" => request.body["model"],
           "choices" => [
             %{
               "index" => 0,
               "message" => %{
                 "role" => "assistant",
                 "content" => nil,
                 "tool_calls" => [
                   %{
                     "id" => "call_encrypted_tool",
                     "type" => "function",
                     "function" => %{
                       "name" => "collaboration__spawn_agent",
                       "arguments" =>
                         Ankole.JSON.encode!(%{
                           "message" => secret,
                           "task_name" => "research"
                         })
                     }
                   }
                 ]
               },
               "finish_reason" => "tool_calls"
             }
           ],
           "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-encrypted-tool",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-encrypted-tool",
               model: "openai/gpt-5.5"
             })

    tools = [
      %{
        "type" => "namespace",
        "name" => "collaboration",
        "description" => "Codex collaboration tools",
        "tools" => [
          %{
            "type" => "function",
            "name" => "spawn_agent",
            "description" => "Spawn a subagent",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string", "encrypted" => true},
                "task_name" => %{"type" => "string"}
              },
              "required" => ["message", "task_name"]
            }
          }
        ]
      }
    ]

    assert {:ok, %{body: first_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "start",
               "tools" => tools
             })

    assert_receive {:gateway_request, first_request}
    provider_tool = get_in(first_request.body, ["tools", Access.at(0), "function"])
    assert provider_tool["name"] == "collaboration__spawn_agent"
    refute Map.has_key?(provider_tool["parameters"]["properties"]["message"], "encrypted")

    [call] = first_body["output"]
    assert call["namespace"] == "collaboration"
    assert call["name"] == "spawn_agent"
    encoded_arguments = Ankole.JSON.decode!(call["arguments"])
    assert encoded_arguments["task_name"] == "research"

    assert String.starts_with?(
             encoded_arguments["message"],
             "ankole-aigateway-opaque-v1:"
           )

    refute Ankole.JSON.encode!(first_body) =~ secret

    assert {:ok, %{body: _second_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 call,
                 %{
                   "type" => "function_call_output",
                   "call_id" => call["call_id"],
                   "output" => "spawned"
                 }
               ],
               "tools" => tools
             })

    assert_receive {:gateway_request, second_request}

    replayed_call =
      second_request.body["messages"]
      |> Enum.find(&Map.has_key?(&1, "tool_calls"))
      |> get_in(["tool_calls", Access.at(0), "function", "arguments"])
      |> Ankole.JSON.decode!()

    assert replayed_call == %{"message" => secret, "task_name" => "research"}
    refute Ankole.JSON.encode!(second_request.body) =~ "ankole-aigateway-opaque-v1:"
  end

  test "an OpenAI-compatible Provider receives the caller's identity headers" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_identity",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_compatible_responses_provider!(agent.uid, base_url, "compatible-identity")

    codex_headers = %{
      "originator" => "codex_cli_rs",
      "user-agent" => "codex_cli_rs/0.147.0 (Linux Unknown; aarch64)",
      "session-id" => "cron:019ff28d-29f0-78e0-b235-09182d5861b8",
      "session_id" => "01a00000-0000-7000-8000-000000000001",
      "thread-id" => "01a00000-0000-7000-8000-000000000002",
      "x-client-request-id" => "01a00000-0000-7000-8000-000000000003",
      "x-codex-window-id" => "01a00000-0000-7000-8000-000000000004:0",
      "version" => "0.147.0"
    }

    assert {:ok, _response} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               request_context: %{"headers" => codex_headers}
             )

    assert_receive {:gateway_request, request}
    headers = Map.new(request.headers, fn {name, value} -> {String.downcase(name), value} end)

    # The Provider decides what to do with the caller's identity; AIGateway only
    # stops it from being dropped at this boundary.
    assert headers["originator"] == "codex_cli_rs"
    assert headers["user-agent"] =~ "codex_cli_rs/0.147.0"
    assert headers["session-id"] == codex_headers["session-id"]
    assert headers["session_id"] == codex_headers["session_id"]
    assert headers["thread-id"] == codex_headers["thread-id"]
    assert headers["x-client-request-id"] == codex_headers["x-client-request-id"]
    assert headers["x-codex-window-id"] == codex_headers["x-codex-window-id"]
    assert headers["version"] == "0.147.0"
  end

  test "a Provider request carries no identity headers the caller did not send" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_no_identity",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_compatible_responses_provider!(agent.uid, base_url, "compatible-no-identity")

    assert {:ok, _response} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    headers = Map.new(request.headers, fn {name, value} -> {String.downcase(name), value} end)

    refute Map.has_key?(headers, "originator")
    refute Map.has_key?(headers, "x-codex-window-id")
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
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
    assert request.body["reasoning"] == %{"effort" => "minimal"}
    refute Map.has_key?(request.body, "reasoningEffort")
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
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
    assert request.body["reasoning"] == %{"effort" => "medium"}
    refute Map.has_key?(request.body, "reasoningEffort")
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-upstream-error",
               model: "openai/gpt-5.5"
             })

    assert {:error,
            {:credential_pool_exhausted,
             %{
               "retry_at" => retry_at,
               "statuses" => statuses
             }}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert_receive {:gateway_request, retry_request}
    assert retry_request.body == request.body
    refute_receive {:gateway_request, _request}
    assert is_binary(retry_at)
    assert [%{"provider_status" => 429, "status" => "exhausted"}] = Map.values(statuses)
  end

  test "stream provider failures log bounded request shape and provider classification" do
    %{principal: agent} = agent_fixture()
    image_data_url = "data:image/png;base64,private-image-data"

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 502,
         %{
           "error" => %{
             "code" => "provider_unavailable",
             "message" => "private provider message",
             "type" => "server_error"
           }
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-stream-diagnostics",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-stream-diagnostics",
               model: "openai/gpt-5.5"
             })

    log =
      capture_log(
        [
          level: :error,
          metadata: [
            :event,
            :signal_id,
            :model,
            :api_resolver,
            :upstream_host,
            :request_bytes,
            :input_item_count,
            :tool_count,
            :function_call_output_count,
            :custom_tool_call_output_count,
            :input_image_count,
            :inline_image_chars,
            :error_code,
            :provider_status,
            :provider_error_code,
            :provider_error_type,
            :retryable
          ]
        ],
        fn ->
          assert {:error,
                  %Ankole.AIGateway.ProviderFailure{
                    kind: :status_rejected,
                    provider_status: 502,
                    provider_body: %{
                      "error" => %{
                        "code" => "provider_unavailable",
                        "message" => "private provider message",
                        "type" => "server_error"
                      }
                    }
                  }} =
                   AIGateway.open_sse_stream(agent.uid, %{
                     "model" => "primary",
                     "stream" => true,
                     "metadata" => %{"signal_id" => "actor-event-diagnostics"},
                     "input" => [
                       %{
                         "type" => "function_call",
                         "call_id" => "call_image",
                         "name" => "view_image",
                         "arguments" => ~s({"path":"/tmp/private.png"})
                       },
                       %{
                         "type" => "function_call_output",
                         "call_id" => "call_image",
                         "output" => [
                           %{"type" => "input_image", "image_url" => image_data_url}
                         ]
                       },
                       %{
                         "type" => "custom_tool_call",
                         "call_id" => "call_patch",
                         "name" => "apply_patch",
                         "input" =>
                           "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n"
                       },
                       %{
                         "type" => "custom_tool_call_output",
                         "call_id" => "call_patch",
                         "output" => "Done!"
                       },
                       %{"role" => "user", "content" => "private prompt"}
                     ],
                     "tools" => [
                       %{
                         "type" => "function",
                         "name" => "view_image",
                         "parameters" => %{"type" => "object"}
                       },
                       %{
                         "type" => "custom",
                         "name" => "apply_patch",
                         "description" => "Apply one patch.",
                         "format" => %{"type" => "text"}
                       }
                     ]
                   })
        end
      )

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"

    assert get_in(request.body, ["messages", Access.at(1), "content"]) ==
             "[Image output is attached in the next user message.]"

    assert Enum.any?(request.body["tools"], fn tool ->
             get_in(tool, ["function", "name"]) == "apply_patch" and
               get_in(tool, ["function", "parameters", "required"]) == ["input"]
           end)

    assert Enum.any?(request.body["messages"], fn message ->
             get_in(message, ["tool_calls", Access.at(0), "function", "name"]) == "apply_patch"
           end)

    assert Enum.any?(request.body["messages"], fn message ->
             message["role"] == "tool" and message["tool_call_id"] == "call_patch" and
               message["content"] == "Done!"
           end)

    assert log =~ "event=ai_gateway.response_failed"
    refute log =~ "signal_id=actor-event-diagnostics"
    assert log =~ "model=openai/gpt-5.5"
    assert log =~ "api_resolver=openai_chat_completions"
    assert log =~ "upstream_host=127.0.0.1"
    assert log =~ "input_item_count=5"
    assert log =~ "tool_count=2"
    assert log =~ "function_call_output_count=1"
    assert log =~ "custom_tool_call_output_count=1"
    assert log =~ "input_image_count=1"
    assert log =~ "inline_image_chars=#{byte_size(image_data_url)}"
    assert log =~ "error_code=upstream_response_failed"
    assert log =~ "provider_status=502"
    assert log =~ "provider_error_code=provider_unavailable"
    assert log =~ "provider_error_type=server_error"
    assert log =~ "retryable=true"
    refute log =~ "private provider message"
    refute log =~ "private prompt"
    refute log =~ "private-image-data"
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-invalid-upstream-body",
               model: "openai/gpt-5.5"
             })

    assert {:error,
            %Ankole.AIGateway.ProviderFailure{
              kind: :invalid_response,
              provider_status: 200,
              provider_body: %{"body" => ["not", "a", "map"]}
            }} =
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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
    assert request.body["reasoning"] == %{"effort" => "high"}
    refute Map.has_key?(request.body, "reasoningEffort")
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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

    tenant_id = Repo.tenant_id!()

    results =
      agents
      |> Task.async_stream(
        fn {agent_uid, input} ->
          Repo.put_tenant_id(tenant_id)

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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
                 "transport" => %{}
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

    tenant_id = Repo.tenant_id!()

    results =
      agents
      |> Task.async_stream(
        fn {agent_uid, input} ->
          Repo.put_tenant_id(tenant_id)

          assert {:ok, events} =
                   open_sse_events(agent_uid, %{"model" => "primary", "input" => input})

          if String.starts_with?(input, "bad-") do
            refute Enum.any?(events, &(&1["type"] == "error"))
            assert [failed] = Enum.filter(events, &(&1["type"] == "response.failed"))

            # The kernel reports this failure with the OpenAI error type
            # `server_error`. That type is not a provider capacity alias.
            assert %{"code" => "invalid_provider_event", "retryable" => false} =
                     failed["response"]["error"]

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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-upstream-websocket",
               model: "gpt-5.5",
               provider_options: %{"serviceTier" => "flex"}
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
    assert request.response_context.request["store"] == false
    assert request.response_context.provider_options["service_tier"] == "flex"
    assert request.response_context.stream == true
  end

  test "openai-compatible responses can prepare an optional upstream WebSocket stream" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-upstream-websocket",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               },
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compatible-upstream-websocket",
               model: "compatible-reasoning-model",
               provider_options: %{"serviceTier" => "provider-native-tier"}
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "primary"
             })

    runtime =
      Map.put(runtime, "request_context", %{
        "downstream_transport" => "websocket",
        "headers" => %{"session-id" => "cron:upstream-websocket-session"}
      })

    assert {:ok, request} =
             Providers.build_response_request(
               runtime,
               %{"model" => "primary", "input" => "hello"},
               stream?: true
             )

    assert request.upstream.method == "GET"
    assert request.upstream.kind == :websocket_text
    assert request.upstream.url == "wss://compatible.test/v1/responses"

    assert Map.new(request.upstream.headers)["Session-Id"] ==
             "cron:upstream-websocket-session"

    assert request.api_resolver == :openai_responses
    refute Map.has_key?(request, :body)
    assert request.response_context.model == "compatible-reasoning-model"
    assert request.response_context.request["input"] == "hello"
    assert request.response_context.provider_options["service_tier"] == "provider-native-tier"
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "gemini-key"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "google-ai-studio-openai",
               model: "gemini-2.5-pro"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "metadata" => %{"trace" => "abc"}
             })

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.headers["authorization"] == "Bearer gemini-key"
    assert request.headers["x-goog-api-client"] == "ankole-ai-gateway/0.1"
    assert request.body["model"] == "gemini-2.5-pro"
    assert request.body["reasoning_effort"] == "high"
    refute Map.has_key?(request.body, "reasoningEffort")
    refute Map.has_key?(request.body, "metadata")
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "gemini-key"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "google-ai-studio-reasoning",
               model: "gemini-2.5-pro"
             })

    assert {:error,
            {:provider_options,
             {:invalid_value, "reasoningEffort", "minimal", ["low", "medium", "high"]}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "provider_options" => %{"reasoningEffort" => "minimal"}
             })

    refute_receive {:gateway_request, _request}, 100
  end

  test "openai_compatible requires a base URL and sends its request" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-no-url",
               provider_kind: "openai_compatible",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "compatible-key"}]
               }
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
               provider_kind: "openai_compatible",
               base_url: http1_base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "compatible-key"}]
               },
               connection_options: %{
                 "transport" => %{}
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

    assert runtime["connection_options"]["transport"] == %{}

    assert {:ok, %{body: http1_body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.body["reasoning_effort"] == "high"
    refute Map.has_key?(request.body, "reasoningEffort")

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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "anthropic-key"}]
               },
               connection_options: %{
                 "transport" => %{}
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
    assert request.body["output_config"] == %{"effort" => "high"}
    refute Map.has_key?(request.body, "effort")

    assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}] =
             request.body["messages"]

    assert_standard_stream(events)
    assert body["model"] == "claude-sonnet-4-5"

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello claude"

    assert body["usage"]["total_tokens"] == 5
  end

  for {error_type, status, code, retryable} <- [
        {"overloaded_error", 529, "provider_status_rejected", true},
        {"invalid_request_error", 400, "invalid_prompt", false},
        {"rate_limit_error", 429, "provider_status_rejected", true}
      ] do
    @tag claude_stream_error: {error_type, status, code, retryable}
    test "claude provider fails the response for a mid-stream #{error_type}", context do
      {error_type, status, code, retryable} = context.claude_stream_error
      %{principal: agent} = agent_fixture()

      base_url =
        start_recording_upstream(self(), fn _request ->
          error_event = %{
            "type" => "error",
            "error" => %{"type" => error_type, "message" => "Anthropic #{error_type}"}
          }

          {:sse, 200, Enum.take(anthropic_stream_events(), 3) ++ [error_event], false}
        end)

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: "claude-stream-error",
                 provider_kind: "claude",
                 base_url: base_url,
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "anthropic-key"}]
                 },
                 connection_options: %{"transport" => %{}}
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "claude-stream-error",
                 model: "claude-sonnet-4-5"
               })

      assert {:ok, events} =
               open_sse_events(agent.uid, %{"model" => "primary", "input" => "hello"})

      assert Enum.map(events, & &1["type"]) == [
               "response.created",
               "response.output_item.added",
               "response.content_part.added",
               "response.output_text.delta",
               "response.failed"
             ]

      assert %{
               "code" => ^code,
               "message" => "Anthropic " <> ^error_type,
               "retryable" => ^retryable,
               "failure_kind" => "provider_response",
               "provider_status" => ^status,
               "provider_error_type" => ^error_type
             } = terminal_response_body!(events)["error"]

      assert {:ok, provider} = ProviderConfigs.get_provider("claude-stream-error")
      [credential] = provider["credential_pool"]["entries"]
      assert credential["status"] == if(status == 429, do: "exhausted", else: "ok")
      assert_receive {:gateway_request, _request}
      refute_receive {:gateway_request, _request}
    end
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
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "api_key" => "sk-openrouter",
                     "auth_mode" => "auth_token"
                   }
                 ]
               },
               connection_options: %{
                 "transport" => %{},
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
    assert request.body["output_config"] == %{"effort" => "max"}
    refute Map.has_key?(request.body, "effort")

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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "azure-key"}]
               },
               connection_options: %{
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment",
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-deployment",
               model: "gpt-5.5",
               provider_options: %{"serviceTier" => "fast", "textVerbosity" => "low"}
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "openai/deployments/gpt-deployment/chat/completions"
    assert request.query_string == "api-version=2025-04-01-preview"
    assert request.headers["api-key"] == "azure-key"
    refute Map.has_key?(request.headers, "authorization")
    refute Map.has_key?(request.body, "model")
    assert request.body["reasoning_effort"] == "high"
    assert request.body["service_tier"] == "fast"
    assert request.body["verbosity"] == "low"
    refute Map.has_key?(request.body, "reasoningEffort")
    refute Map.has_key?(request.body, "textVerbosity")
    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) == "azure"

    assert {:ok, _openai_path_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-path-base",
               provider_kind: "azure_openai",
               base_url: "#{base_url}/openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "Bearer prefixed-token"}]
               },
               connection_options: %{
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment",
                 "transport" => %{}
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
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "api_key" => "Bearer entra-token",
                     "auth_scheme" => "bearer"
                   }
                 ]
               },
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-v1",
               model: "gpt-5.5",
               provider_options: %{
                 "reasoningSummary" => "detailed",
                 "serviceTier" => "provider-native-tier",
                 "textVerbosity" => "high"
               }
             })

    assert {:ok, events} =
             open_sse_events(agent.uid, %{"model" => "primary", "input" => "hello"})

    v1_body = terminal_response_body!(events)

    assert_receive {:gateway_request, request}
    assert request.path == "openai/v1/responses"
    assert request.headers["authorization"] == "Bearer entra-token"
    refute Map.has_key?(request.headers, "api-key")
    assert request.body["model"] == "gpt-5.5"
    assert request.body["store"] == false
    assert request.body["reasoning"] == %{"effort" => "high", "summary" => "detailed"}
    assert request.body["service_tier"] == "provider-native-tier"
    assert request.body["text"] == %{"verbosity" => "high"}
    refute Map.has_key?(request.body, "reasoningEffort")
    refute Map.has_key?(request.body, "reasoningSummary")
    refute Map.has_key?(request.body, "textVerbosity")
    assert List.last(events)["type"] == "response.completed"
    assert v1_body["id"] == "resp_azure_v1"
  end

  test "standalone compact preserves provider-native output in one version 3 artifact" do
    %{principal: agent} = agent_fixture()
    prefer_provider_compaction!(agent.uid)

    native_output = [
      %{"type" => "message", "role" => "user", "content" => "retained"},
      %{
        "type" => "compaction",
        "encrypted_content" => "provider-opaque-state",
        "unknown" => %{"preserved" => true}
      }
    ]

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert List.last(request.body["input"]) == %{"type" => "compaction_trigger"}
        assert request.body["model"] == "gpt-5.6"
        assert request.body["stream"] == true

        {:sse, 200,
         openai_compaction_stream_events("resp_native_success", native_output, %{
           "total_tokens" => 42
         })}
      end)

    configure_openai_responses_provider!(
      agent.uid,
      base_url,
      "openai-native-compact-success"
    )

    input = [text_message("user", "compact this history")]

    assert {:ok, body} =
             CompactionRequests.compact_response(agent.uid, %{
               "model" => "primary",
               "input" => input,
               "store" => false
             })

    # The Provider answers on the normal Responses wire now, so its retained
    # items arrive normalized. The compaction item stays verbatim, including the
    # Provider extension AIGateway does not understand.
    assert [%{"type" => "message", "role" => "user"}, compaction_item] = body["output"]
    assert compaction_item == List.last(native_output)
    assert_receive {:gateway_request, %{path: "v1/responses"}}

    artifact =
      Repo.all(CompactionArtifact)
      |> Enum.find(&(Map.get(&1.content, "version") == 3))

    assert artifact.content["source"] == "upstream"
    assert [%{"type" => "message"}, ^compaction_item] = artifact.content["output"]
    assert artifact.content["binding"]["model"] == "gpt-5.6"
    assert is_binary(artifact.content["binding"]["provider_row_id"])
    refute inspect(artifact.content["output"]) =~ "ankole:compact:v1:"
  end

  defp create_native_image_provider!(agent, base_url, suffix) do
    provider_id =
      "openai-native-image-#{suffix}-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "native-image",
                     "label" => "Native image",
                     "api_key" => "sk-native-image"
                   }
                 ]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-5.6-sol"
             })

    provider_id
  end

  defp native_image_item(image_id) do
    %{
      "id" => image_id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => native_png_base64(),
      "revised_prompt" => "A tiny native image"
    }
  end

  defp native_png_base64 do
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
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
