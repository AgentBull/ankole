defmodule Ankole.AIGateway.ResponsesDispatchTest do
  use Ankole.AIGatewayCase

  test "responses dispatch strips previous_response_id and applies provider options" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-responses-main",
               provider_kind: "openai",
               credential: "sk-openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-responses-main",
               model: "gpt-5.5",
               provider_options: %{"reasoningEffort" => "minimal"}
             })

    http_client = fn request ->
      assert request.method == :post
      assert request.url == "https://api.openai.test/v1/responses"
      assert request.http_protocol == "http2"
      assert request.headers["authorization"] == "Bearer sk-openai"
      assert request.body["model"] == "gpt-5.5"
      assert request.body["stream"] == false
      assert request.body["input"] == "hello"
      assert request.body["reasoningEffort"] == "minimal"
      refute Map.has_key?(request.body, "previous_response_id")

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "resp_test",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }
       }}
    end

    assert {:ok, %{body: body, model_ref: model_ref}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "hello",
                 "previous_response_id" => "resp_old",
                 "stream" => true
               },
               http_client: http_client
             )

    assert body["id"] == "resp_test"
    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "primary"
    assert model_ref["provider_id"] == "openai-responses-main"
  end

  test "responses return structured errors for upstream non-2xx instead of successful bodies" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-upstream-error",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-upstream-error",
               model: "openai/gpt-5.5"
             })

    http_client = fn request ->
      assert request.url == "https://openrouter.ai/api/v1/chat/completions"

      {:ok,
       %{
         status: 429,
         body: %{
           "error" => %{
             "code" => "rate_limited",
             "message" => "provider rate limit",
             "type" => "too_many_requests"
           }
         }
       }}
    end

    assert {:error,
            {:upstream_response_failed, 429,
             %{
               "error" => %{
                 "code" => "rate_limited",
                 "message" => "provider rate limit",
                 "type" => "too_many_requests"
               }
             }}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: http_client
             )
  end

  test "chat completions dispatch preserves user multimodal image_url content" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-multimodal-dispatch",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-multimodal-dispatch",
               model: "openai/gpt-5.4-nano"
             })

    image_url = "data:image/png;base64,iVBORw0KGgo="

    assert {:ok, %{body: body}} =
             AIGateway.create_response(
               agent.uid,
               %{
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
               },
               http_client: fn request ->
                 assert request.path == "chat/completions"

                 assert [
                          %{
                            "role" => "user",
                            "content" => [
                              %{"type" => "text", "text" => "Describe the image in one word."},
                              %{"type" => "image_url", "image_url" => %{"url" => ^image_url}}
                            ]
                          }
                        ] = request.body["messages"]

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "id" => "chatcmpl_mm",
                      "object" => "chat.completion",
                      "created" => 1_764_967_971,
                      "model" => request.body["model"],
                      "choices" => [
                        %{
                          "index" => 0,
                          "message" => %{"role" => "assistant", "content" => "image"},
                          "finish_reason" => "stop"
                        }
                      ],
                      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
                    }
                  }}
               end
             )

    assert body["status"] == "completed"
  end

  test "openrouter provider owns its default URL and attribution headers" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-default-url",
               provider_kind: "openrouter",
               credential: "sk-openrouter"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-default-url",
               model: "openai/gpt-5.5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url == "https://openrouter.ai/api/v1/chat/completions"
                 assert request.http_protocol == "http2"
                 assert request.headers["authorization"] == "Bearer sk-openrouter"
                 assert request.headers["HTTP-Referer"] == "https://github.com/agentbull/ankole"
                 assert request.headers["X-Title"] == "Ankole"
                 assert request.headers["X-OpenRouter-Title"] == "Ankole"
                 {:ok, %{status: 200, body: chat_completion_body(request.body["model"], "hello")}}
               end
             )

    assert body["model"] == "openai/gpt-5.5"
    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) == "hello"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-http1",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               connection_options: %{"http_protocol" => "http1"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-http1",
               model: "openai/gpt-5.5"
             })

    assert {:ok, %{body: http1_body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url == "https://openrouter.ai/api/v1/chat/completions"
                 assert request.http_protocol == "http1"
                 {:ok, %{status: 200, body: chat_completion_body(request.body["model"], "http1")}}
               end
             )

    assert get_in(http1_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "http1"
  end

  test "google ai studio openai provider uses the concrete compatibility URL and bearer auth" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "google-ai-studio-openai",
               provider_kind: "google_ai_studio_openai",
               credential: "gemini-key"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "google-ai-studio-openai",
               model: "gemini-2.5-pro"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url ==
                          "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

                 assert request.http_protocol == "http2"
                 assert request.headers["authorization"] == "Bearer gemini-key"
                 assert request.headers["x-goog-api-client"] == "ankole-ai-gateway/0.1"
                 assert request.body["model"] == "gemini-2.5-pro"

                 {:ok,
                  %{status: 200, body: chat_completion_body(request.body["model"], "gemini")}}
               end
             )

    assert body["model"] == "gemini-2.5-pro"
  end

  test "openai-compatible requires an operator-supplied base URL" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-no-url",
               provider_kind: "openai-compatible",
               credential: "compatible-key"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-compatible-no-url",
               model: "local-model"
             })

    assert {:error, :missing_base_url} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn _request -> flunk("missing base_url must not dispatch") end
             )
  end

  test "openai-compatible defaults to HTTP/1 and allows explicit protocol override" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-http1",
               provider_kind: "openai-compatible",
               credential: "compatible-key",
               base_url: "https://compatible.test/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-compatible-http1",
               model: "local-model"
             })

    assert {:ok, %{body: http1_body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url == "https://compatible.test/v1/chat/completions"
                 assert request.http_protocol == "http1"
                 {:ok, %{status: 200, body: chat_completion_body("local-model", "http1")}}
               end
             )

    assert get_in(http1_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "http1"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-http2",
               provider_kind: "openai-compatible",
               credential: "compatible-key",
               base_url: "https://compatible.test/v1",
               connection_options: %{
                 "http_protocol" => "http2"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-compatible-http2",
               model: "local-model"
             })

    assert {:ok, %{body: http2_body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url == "https://compatible.test/v1/chat/completions"
                 assert request.http_protocol == "http2"
                 {:ok, %{status: 200, body: chat_completion_body("local-model", "http2")}}
               end
             )

    assert get_in(http2_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "http2"
  end

  test "claude provider converts messages API auth, body, and SSE events" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-stream",
               provider_kind: "claude",
               credential: "anthropic-key"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "claude-stream",
               model: "claude-sonnet-4-5"
             })

    assert {:ok, events, %{body: body}} =
             AIGateway.response_events(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_stream_client: fn request, state, handler ->
                 assert request.url == "https://api.anthropic.com/v1/messages"
                 assert request.http_protocol == "http2"
                 assert request.headers["x-api-key"] == "anthropic-key"
                 assert request.headers["anthropic-version"] == "2023-06-01"
                 assert request.body["model"] == "claude-sonnet-4-5"
                 assert request.body["stream"] == true

                 assert [
                          %{
                            "role" => "user",
                            "content" => [%{"type" => "text", "text" => "hello"}]
                          }
                        ] =
                          request.body["messages"]

                 stream_sse_messages(anthropic_stream_events(), state, handler)
               end
             )

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

    assert body["model"] == "claude-sonnet-4-5"

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello claude"

    assert body["usage"]["total_tokens"] == 5
  end

  test "azure openai provider supports deployment api-key auth and v1 bearer responses" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _deployment_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-deployment",
               provider_kind: "azure_openai",
               credential: "azure-key",
               base_url: "https://ankole-test.openai.azure.com",
               connection_options: %{
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-deployment",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url ==
                          "https://ankole-test.openai.azure.com/openai/deployments/gpt-deployment/chat/completions?api-version=2025-04-01-preview"

                 assert request.http_protocol == "http2"
                 assert request.headers["api-key"] == "azure-key"
                 refute Map.has_key?(request.headers, "authorization")
                 refute Map.has_key?(request.body, "model")
                 {:ok, %{status: 200, body: chat_completion_body("gpt-deployment", "azure")}}
               end
             )

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) == "azure"

    assert {:ok, _openai_path_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-path-base",
               provider_kind: "azure_openai",
               credential: "Bearer prefixed-token",
               base_url: "https://ankole-test.openai.azure.com/openai",
               connection_options: %{
                 "api_version" => "2025-04-01-preview",
                 "deployment" => "gpt-deployment"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-path-base",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: path_body}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_client: fn request ->
                 assert request.url ==
                          "https://ankole-test.openai.azure.com/openai/deployments/gpt-deployment/chat/completions?api-version=2025-04-01-preview"

                 assert request.headers["authorization"] == "Bearer prefixed-token"
                 refute Map.has_key?(request.headers, "api-key")
                 refute Map.has_key?(request.body, "model")
                 {:ok, %{status: 200, body: chat_completion_body("gpt-deployment", "azure path")}}
               end
             )

    assert get_in(path_body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "azure path"

    assert {:ok, _v1_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-openai-v1",
               provider_kind: "azure_openai",
               credential_mode: "auth_token",
               credential: "Bearer entra-token",
               base_url: "https://ankole-test.openai.azure.com/openai/v1",
               connection_options: %{
                 "endpoint_kind" => "responses",
                 "auth_scheme" => "bearer"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "azure-openai-v1",
               model: "gpt-5.5"
             })

    assert {:ok, events, %{body: v1_body}} =
             AIGateway.response_events(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               http_stream_client: fn request, state, handler ->
                 assert request.url == "https://ankole-test.openai.azure.com/openai/v1/responses"
                 assert request.headers["authorization"] == "Bearer entra-token"
                 refute Map.has_key?(request.headers, "api-key")
                 assert request.body["model"] == "gpt-5.5"

                 stream_sse_messages(
                   openai_response_stream_events("resp_azure_v1", "gpt-5.5", "v1"),
                   state,
                   handler
                 )
               end
             )

    assert List.last(events)["type"] == "response.completed"
    assert v1_body["id"] == "resp_azure_v1"
  end
end
