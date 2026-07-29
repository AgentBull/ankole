defmodule Ankole.AIGateway.ResponsesDispatchTest do
  use Ankole.AIGatewayCase

  import ExUnit.CaptureLog

  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Ecto.UUIDv7
  alias Ankole.SignalsGateway.ActorEvent
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
    refute Map.has_key?(request.body, "service_tier")
    assert request.body["prompt_cache_key"] == "cache-a"

    assert body["id"] == "resp_test"
    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "primary"
    assert model_ref["provider_id"] == "openai-responses-main"
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

  test "a retryable provider failure is attributed to its credential and rotates within the row" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600)

    base_url =
      start_upstream_server(fn request ->
        authorization = request.headers["authorization"]
        send(test_pid, {:pool_attempt, authorization})

        case authorization do
          "Bearer sk-first" ->
            {:json, 429,
             [{"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}],
             %{"error" => %{"code" => "rate_limited", "message" => "first key is limited"}}}

          "Bearer sk-second" ->
            {:json, 200,
             %{
               "id" => "resp_pool_rotation",
               "object" => "response",
               "status" => "completed",
               "output" => [],
               "usage" => %{}
             }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-pool-rotation",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               },
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-pool-rotation",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: %{"id" => "resp_pool_rotation"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    assert_receive {:pool_attempt, "Bearer sk-first"}
    assert_receive {:pool_attempt, "Bearer sk-second"}
    refute_receive {:pool_attempt, _authorization}

    assert {:ok, projection} = ProviderConfigs.get_provider("openai-pool-rotation")
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 429
    assert by_id["first"]["last_error_code"] == "rate_limited"
    assert by_id["second"]["status"] == "ok"
    assert by_id["first"]["request_count"] == 1
    assert by_id["second"]["request_count"] == 1
  end

  test "5xx rotation uses exponential backoff before each new credential" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        authorization = request.headers["authorization"]
        send(test_pid, {:pool_attempt, authorization})

        case authorization do
          "Bearer sk-third" ->
            {:json, 200,
             %{
               "id" => "resp_pool_backoff",
               "object" => "response",
               "status" => "completed",
               "output" => [],
               "usage" => %{}
             }}

          _credential ->
            {:json, 503,
             %{"error" => %{"code" => "provider_unavailable", "message" => "try another key"}}}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-pool-backoff",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"},
                   %{"id" => "third", "label" => "Third", "api_key" => "sk-third"}
                 ]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-pool-backoff",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: %{"id" => "resp_pool_backoff"}}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               credential_retry_base_ms: 100,
               credential_retry_jitter: & &1,
               credential_retry_sleep: fn milliseconds ->
                 send(test_pid, {:credential_retry_delay, milliseconds})
               end
             )

    assert_receive {:pool_attempt, "Bearer sk-first"}
    assert_receive {:credential_retry_delay, 100}
    assert_receive {:pool_attempt, "Bearer sk-second"}
    assert_receive {:credential_retry_delay, 200}
    assert_receive {:pool_attempt, "Bearer sk-third"}
    refute_receive {:pool_attempt, _authorization}

    assert {:ok, projection} = ProviderConfigs.get_provider("openai-pool-backoff")
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 503
    assert by_id["second"]["status"] == "exhausted"
    assert by_id["second"]["provider_status"] == 503
    assert by_id["third"]["status"] == "ok"
  end

  test "ChatGPT Cloudflare challenges preserve the safe header and fail with operator guidance" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 403, [{"cf-mitigated", "challenge"}],
         %{"error" => %{"code" => "forbidden", "message" => "challenge"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-cloudflare-challenge",
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
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "chatgpt-cloudflare-challenge",
               model: "gpt-5.6-sol"
             })

    assert {:error,
            {:universal_ai_request_failed,
             %{
               "code" => "chatgpt_cloudflare_challenge",
               "provider_status" => 403,
               "provider_headers" => [{"cf-mitigated", "challenge"}],
               "retryable" => false
             } = error}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    assert error["message"] =~ "originator and User-Agent"
    assert_receive {:gateway_request, request}
    assert request.path == "responses"
    refute_receive {:gateway_request, _request}

    assert {:ok, projection} =
             ProviderConfigs.get_provider("chatgpt-cloudflare-challenge")

    assert [entry] = projection["credential_pool"]["entries"]
    assert entry["status"] == "ok"
  end

  test "Jina multi-URL fetch does not reuse a credential cooled by an earlier URL" do
    %{principal: agent} = agent_fixture()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600) |> DateTime.to_unix()

    base_url =
      start_recording_upstream(self(), fn request ->
        case request.headers["authorization"] do
          "Bearer first-key" ->
            {:json, 429, [{"x-codex-primary-reset-at", Integer.to_string(reset_at)}],
             %{"error" => %{"code" => "rate_limit"}}}

          "Bearer second-key" ->
            {:json, 200,
             %{
               "data" => %{
                 "url" => request.body["url"],
                 "title" => "Fetched",
                 "content" => request.body["url"]
               }
             }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-reader-pool",
               provider_kind: "jina_reader",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "first-key"},
                   %{"id" => "second", "label" => "Second", "api_key" => "second-key"}
                 ]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    assert {:ok, %{body: %{"success" => true, "results" => results}}} =
             AIGateway.create_web_fetch(
               agent.uid,
               %{
                 "model" => "jina-reader-pool/default",
                 "urls" => ["https://example.com/one", "https://example.com/two"]
               },
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert Enum.map(results, & &1["url"]) == [
             "https://example.com/one",
             "https://example.com/two"
           ]

    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer first-key"}}}
    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer second-key"}}}
    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer second-key"}}}
    refute_receive {:gateway_request, _request}, 100
  end

  test "a single-entry pool retries once and then preserves a non-quota failure" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:single_pool_attempt, request.headers["authorization"]})

        {:json, 503,
         %{"error" => %{"code" => "provider_unavailable", "message" => "still unavailable"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-single-retry",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"id" => "only", "label" => "Only", "api_key" => "sk-only"}]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-single-retry",
               model: "gpt-5.5"
             })

    assert {:error,
            {:upstream_response_failed, 503,
             %{
               "error" => %{
                 "code" => "provider_unavailable",
                 "message" => "still unavailable"
               }
             }}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               credential_retry_base_ms: 0,
               credential_retry_jitter: & &1
             )

    assert_receive {:single_pool_attempt, "Bearer sk-only"}
    assert_receive {:single_pool_attempt, "Bearer sk-only"}
    refute_receive {:single_pool_attempt, _authorization}
  end

  test "one usable credential retries once and preserves a non-quota failure" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:single_usable_attempt, request.headers["authorization"]})

        {:json, 503,
         %{"error" => %{"code" => "provider_unavailable", "message" => "still unavailable"}}}
      end)

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-single-usable-retry",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "dead", "label" => "Dead", "api_key" => "sk-dead"},
                   %{"id" => "only", "label" => "Only usable", "api_key" => "sk-only"}
                 ]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    :ok = CredentialPool.mark_dead(provider.id, "dead")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-single-usable-retry",
               model: "gpt-5.5"
             })

    assert {:error,
            {:upstream_response_failed, 503,
             %{
               "error" => %{
                 "code" => "provider_unavailable",
                 "message" => "still unavailable"
               }
             }}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               credential_retry_base_ms: 0,
               credential_retry_jitter: & &1
             )

    assert_receive {:single_usable_attempt, "Bearer sk-only"}
    assert_receive {:single_usable_attempt, "Bearer sk-only"}
    refute_receive {:single_usable_attempt, _authorization}
  end

  test "unattributed failures mark no credential and stop after one pool lap" do
    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-unattributed-retry",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "openai-unattributed-retry/gpt-5.5"
             })

    context = %{
      runtime: Map.delete(runtime, "credential_id"),
      build: fn _runtime, _request -> {:ok, %{}} end,
      request: %{},
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      single_retry_used?: false,
      refresh_used?: false
    }

    reason =
      {:upstream_response_failed, 503, %{"error" => %{"code" => "provider_unavailable"}}, %{}}

    retry_opts = [
      credential_retry_base_ms: 0,
      credential_retry_jitter: &Function.identity/1
    ]

    assert {:ok, first_retry, %{}} =
             CredentialAttempts.retry_spec(context, %{}, reason, retry_opts)

    first_retry = update_in(first_retry.runtime, &Map.delete(&1, "credential_id"))

    assert {:ok, second_retry, %{}} =
             CredentialAttempts.retry_spec(first_retry, %{}, reason, retry_opts)

    second_retry = update_in(second_retry.runtime, &Map.delete(&1, "credential_id"))

    assert {:error, ^reason} =
             CredentialAttempts.retry_spec(second_retry, %{}, reason, retry_opts)

    statuses =
      CredentialPool.statuses(
        provider.id,
        provider.credential_pool["entries"]
      )

    assert statuses["first"]["status"] == "ok"
    assert statuses["second"]["status"] == "ok"
  end

  test "OpenRouter chat requests forward the prompt cache key" do
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
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-cache-key",
               model: "openai/gpt-5.6-sol"
             })

    assert {:ok, %{body: _body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "prompt_cache_key" => "job-thread-9"
             })

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.body["prompt_cache_key"] == "job-thread-9"

    assert {:ok, %{body: _noop_body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello again"
             })

    assert_receive {:gateway_request, keyless_request}
    refute Map.has_key?(keyless_request.body, "prompt_cache_key")
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
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-codex-encrypted",
               model: "gpt-5.4"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 encrypted_reasoning,
                 %{"type" => "message", "role" => "user", "content" => "continue"}
               ],
               "include" => ["reasoning.encrypted_content"],
               "prompt_cache_key" => "codex-thread-1",
               "store" => false
             })

    assert_receive {:gateway_request, request}
    assert request.body["include"] == ["reasoning.encrypted_content"]
    assert request.body["prompt_cache_key"] == "codex-thread-1"
    assert List.first(request.body["input"])["encrypted_content"] == "ENCRYPTED_CODEX_STATE"
    assert List.first(body["output"])["encrypted_content"] == "ENCRYPTED_CODEX_STATE"
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
                 "transport" => %{"http_versions" => ["h1"]}
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

  test "websocket responses require store true before continuation fields" do
    %{principal: agent} = agent_fixture()
    previous_response_id = "resp_#{Ecto.UUID.generate()}"
    conversation_id = "conv_#{Ecto.UUID.generate()}"

    assert {:error, :stateful_anchor_conflict} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true,
               "conversation" => conversation_id,
               "previous_response_id" => previous_response_id
             })

    for request <- [
          %{
            "model" => "primary",
            "input" => "hello",
            "previous_response_id" => previous_response_id
          },
          %{"model" => "primary", "input" => "hello", "conversation" => conversation_id},
          %{
            "model" => "primary",
            "input" => "hello",
            "store" => false,
            "conversation" => conversation_id
          }
        ] do
      assert {:error, :stateful_store_required} =
               AIGateway.open_websocket_stream(agent.uid, request)
    end

    refute_receive {:gateway_request, _request}
  end

  test "websocket store true without previous_response_id or conversation creates a managed conversation" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-auto-conversation",
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
               provider_id: "openai-stateful-auto-conversation",
               model: "gpt-5.5"
             })

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true,
               "metadata" => %{
                 "request_tag" => "kept",
                 "brain" => %{"visibility" => "public"}
               }
             })

    provider_request = request.response_context.request

    assert provider_request["store"] == false

    assert provider_request["metadata"] == %{
             "request_tag" => "kept",
             "brain" => %{"visibility" => "public"}
           }

    refute Map.has_key?(provider_request, "conversation")
    refute Map.has_key?(provider_request, "previous_response_id")

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "hello"}]
             }
           ] = provider_request["input"]

    conversation =
      Repo.one!(
        from(conversation in Conversation,
          where: conversation.subject_uid == ^agent.uid,
          where:
            fragment("?->>'managed_by_stateful_responses_api'", conversation.metadata) == "true"
        )
      )

    assert String.starts_with?(conversation.conversation_key, "stateful-responses-api:")

    assert conversation.metadata == %{
             "managed_by_stateful_responses_api" => true,
             "request_tag" => "kept",
             "brain" => %{"visibility" => "public"}
           }
  end

  test "websocket stateful requests reject wires that cannot replay Responses history" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-stateful-gate",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-claude"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "claude-stateful-gate",
               model: "claude-opus-4-6"
             })

    assert {:error, {:stateful_wire_unsupported, "claude", :anthropic_messages}} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true
             })

    # The same selector stays usable for stateless requests.
    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    refute_receive {:gateway_request, _request}
  end

  test "websocket stateful previous_response_id expands history without provider state fields" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-previous-websocket",
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
               provider_id: "openai-stateful-previous-websocket",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-previous-only")

    image_url = "data:image/png;base64,iVBORw0KGgo="

    request_items = [
      %{
        "id" => "msg_previous_user",
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "first user"},
          %{"type" => "input_image", "image_url" => image_url}
        ]
      }
    ]

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "dispatch-previous-a", request_items)

    terminal_items = [
      %{
        "id" => "msg_previous_assistant",
        "type" => "message",
        "status" => "completed",
        "role" => "assistant",
        "content" => [
          %{"type" => "output_text", "text" => "first assistant", "annotations" => []}
        ]
      }
    ]

    {:ok, first} = StatefulResponses.commit_complete(first, terminal_items)

    current_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "next user"}]
      }
    ]

    assert {:error, :invalid_anchor} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => first.id
             })

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "prompt_cache_key" => "cache-ws",
               "metadata" => %{
                 "actor_event_id" => "internal-event-id",
                 "kept" => "public"
               }
             })

    provider_request = request.response_context.request

    assert request.upstream.kind == :websocket_text
    history_input = Enum.map(first.content, &Map.delete(&1, "id"))
    assert provider_request["input"] == history_input ++ current_input

    assert get_in(provider_request, ["input", Access.at(0), "content", Access.at(1)]) == %{
             "type" => "input_image",
             "image_url" => image_url
           }

    refute Enum.any?(
             Enum.take(provider_request["input"], length(history_input)),
             &Map.has_key?(&1, "id")
           )

    refute Map.has_key?(provider_request, "service_tier")
    assert provider_request["prompt_cache_key"] == "cache-ws"
    refute Map.has_key?(provider_request, "previous_response_id")
    assert provider_request["store"] == false
    refute Map.has_key?(provider_request, "conversation")

    assert provider_request["metadata"] == %{
             "actor_event_id" => "internal-event-id",
             "kept" => "public"
           }

    assert {:ok, no_event_request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}"
             })

    assert no_event_request.response_context.request["input"] == history_input ++ current_input
    refute Map.has_key?(no_event_request.response_context.request, "metadata")

    assert {:ok, string_request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "next user as a string",
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "metadata" => %{"actor_event_id" => "internal-event-id-string"}
             })

    assert string_request.response_context.request["input"] ==
             history_input ++
               [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "next user as a string"}]
                 }
               ]
  end

  test "automatic stateful continuation closes tool calls interrupted before durable output" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-interrupted-tool",
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
               provider_id: "openai-stateful-interrupted-tool",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-interrupted-tool")

    original_input = [text_message("user", "run the long command")]

    {:ok, call_response} =
      start_stateful_message(
        agent.uid,
        conversation,
        "dispatch-interrupted-tool-call",
        original_input
      )

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_interrupted",
      "name" => "command",
      "arguments" => Ankole.JSON.encode!(%{"command" => "sleep 40"})
    }

    {:ok, call_response} = StatefulResponses.commit_complete(call_response, [function_call])
    retry_input = [text_message("user", "run the long command")]

    assert {:ok, prepared, run_attrs} =
             StatefulLifecycle.prepare_websocket_provider_request(agent.uid, %{
               "model" => "primary",
               "input" => retry_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "interrupted-tool-retry"}
             })

    [recovered_output | persisted_retry_input] = run_attrs.request_items

    assert recovered_output["type"] == "function_call_output"
    assert recovered_output["call_id"] == "call_interrupted"
    assert recovered_output["output"] =~ "tool_execution_interrupted"
    assert persisted_retry_input == retry_input

    assert run_attrs.metadata["recovered_interrupted_tool_call_ids"] == [
             "call_interrupted"
           ]

    assert prepared.response_context.request["input"] ==
             Enum.map(call_response.content, &Map.delete(&1, "id")) ++
               [recovered_output] ++ retry_input
  end

  test "provider projection drops legacy orphan outputs while preserving the raw row" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-orphan-projection",
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
               provider_id: "openai-stateful-orphan-projection",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-orphan-projection")

    {:ok, anchor} =
      start_stateful_message(agent.uid, conversation, "dispatch-orphan-anchor", [
        text_message("user", "stable request")
      ])

    {:ok, anchor} =
      StatefulResponses.commit_complete(anchor, [text_message("assistant", "stable answer")])

    orphan_output = %{
      "type" => "function_call_output",
      "call_id" => "call_legacy_orphan",
      "output" => "legacy side effect result"
    }

    {:ok, legacy_orphan_row} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        anchor,
        "dispatch-orphan-row",
        [orphan_output]
      )

    {:ok, legacy_orphan_row} = StatefulResponses.commit_complete(legacy_orphan_row, [])
    current_input = [text_message("user", "continue safely")]

    assert {:ok, prepared, run_attrs} =
             StatefulLifecycle.prepare_websocket_provider_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "orphan-projection-retry"}
             })

    projected_input = prepared.response_context.request["input"]

    refute Enum.any?(projected_input, fn item ->
             item["type"] == "function_call_output" and
               item["call_id"] == "call_legacy_orphan"
           end)

    assert run_attrs.metadata["provider_projection_tool_result_quarantine"] == %{
             "orphan_call_ids" => ["call_legacy_orphan"]
           }

    assert Repo.get!(Message, legacy_orphan_row.id).content == [orphan_output]
    assert run_attrs.request_items == current_input
  end

  test "provider projection drops structurally malformed calls and their outputs while preserving raw rows" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-malformed-call-projection",
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
               provider_id: "openai-stateful-malformed-call-projection",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-malformed-call-projection")

    {:ok, legacy_row} =
      start_stateful_message(agent.uid, conversation, "dispatch-malformed-call-row", [
        text_message("user", "legacy request")
      ])

    malformed_call = %{
      "type" => "function_call",
      "status" => "incomplete",
      "call_id" => "call_legacy_partial",
      "name" => "patch",
      "arguments" => "{\"path\":\"/tmp/repor"
    }

    malformed_output = %{
      "type" => "function_call_output",
      "call_id" => "call_legacy_partial",
      "output" => "legacy output that must not be replayed"
    }

    {:ok, legacy_row} =
      StatefulResponses.commit_complete(legacy_row, [malformed_call, malformed_output])

    assert {:ok, prepared, run_attrs} =
             StatefulLifecycle.prepare_websocket_provider_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "continue safely")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "malformed-call-projection-retry"}
             })

    projected_input = prepared.response_context.request["input"]

    refute Enum.any?(projected_input, fn item ->
             item["call_id"] == "call_legacy_partial"
           end)

    assert run_attrs.metadata["provider_projection_tool_result_quarantine"] == %{
             "non_executable_call_ids" => ["call_legacy_partial"]
           }

    assert Repo.get!(Message, legacy_row.id).content == [
             text_message("user", "legacy request"),
             malformed_call,
             malformed_output
           ]
  end

  test "websocket stateful instructions are request-scoped and are not inherited" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-instructions",
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
               provider_id: "openai-stateful-instructions",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-instructions-scope")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "instructions-a")

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [text_message("user", "first user")],
        metadata: %{
          "request_metadata" => %{"actor_event_id" => actor_event.id},
          "instructions" => "old instruction"
        }
      })

    {:ok, first} =
      StatefulResponses.commit_complete(first, [text_message("assistant", "first answer")])

    current_input = [text_message("user", "next user")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "metadata" => %{"actor_event_id" => "instructions-event"}
             })

    provider_request = request.response_context.request

    assert provider_request["input"] == first.content ++ current_input
    refute Map.has_key?(provider_request, "instructions")
  end

  test "websocket stateful max_tool_calls rejects invalid values" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-invalid-max-tool-calls")

    for invalid_value <- [-1, 1.5, "1"] do
      assert {:error, :invalid_max_tool_calls} =
               AIGateway.prepare_websocket_request(agent.uid, %{
                 "model" => "primary",
                 "input" => [text_message("user", "hello")],
                 "store" => true,
                 "conversation" => "conv_#{conversation.id}",
                 "max_tool_calls" => invalid_value,
                 "metadata" => %{"actor_event_id" => "invalid-max-tool-calls-event"}
               })
    end
  end

  test "websocket stateful conversation run stores latest visible leaf as durable anchor" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-conversation-anchor",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-conversation-anchor",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-conversation-anchor")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "conversation-anchor-a", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "conversation-anchor-b")

    current_input = [text_message("user", "second user")]

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => actor_event.id}
             })

    [run] =
      Repo.all(Message)
      |> Enum.filter(
        &(get_in(&1.metadata, ["request_metadata", "actor_event_id"]) == actor_event.id)
      )

    assert run.previous_message_id == first.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "socket-open errors persist stable failure facts without provider text" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-safe-socket-error")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "safe-socket-error", [
        text_message("user", "hello")
      ])

    assert :ok =
             StatefulLifecycle.commit_socket_open_error(
               %{message_id: message.id},
               {:invalid_upstream_response, 200,
                %{
                  "error" => %{
                    "code" => "invalid_shape",
                    "message" => "private provider body",
                    "type" => "provider_protocol_error"
                  }
                }}
             )

    stored_error = Repo.get!(Message, message.id).metadata["error"]

    assert stored_error == %{
             "code" => "invalid_upstream_response",
             "failure_kind" => "invalid_response",
             "message" => "The upstream provider returned an invalid response.",
             "provider_error_code" => "invalid_shape",
             "provider_error_type" => "provider_protocol_error",
             "provider_status" => 200,
             "retryable" => true,
             "stage" => "socket_open"
           }

    encoded_error = Ankole.JSON.encode!(stored_error)
    refute encoded_error =~ "private provider body"

    for legacy_key <- ~w(body reason status provider_body_excerpt) do
      refute Map.has_key?(stored_error, legacy_key)
    end

    assert {:ok,
            %{
              body: %{
                "error" => %{
                  "code" => "invalid_upstream_response",
                  "message" => "The upstream provider returned an invalid response."
                }
              }
            }} = StatefulLifecycle.retrieve_response(agent.uid, "resp_#{message.id}")
  end

  test "retrieve projects legacy stored error maps through the safe public contract" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-legacy-error-projection")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "legacy-error-projection", [
        text_message("user", "hello")
      ])

    assert :ok =
             StatefulLifecycle.commit_socket_open_error(
               %{message_id: message.id},
               {:upstream_response_failed, 502, %{}}
             )

    stored = Repo.get!(Message, message.id)

    legacy_error = %{
      "body" => "private provider body",
      "code" => "upstream_response_failed",
      "message" => "private provider message",
      "reason" => "private provider reason",
      "retryable" => true,
      "status" => 502
    }

    stored
    |> Ecto.Changeset.change(metadata: Map.put(stored.metadata, "error", legacy_error))
    |> Repo.update!()

    assert {:ok, %{body: %{"error" => public_error}}} =
             StatefulLifecycle.retrieve_response(agent.uid, "resp_#{message.id}")

    assert public_error == %{
             "code" => "upstream_response_failed",
             "failure_kind" => "provider_response",
             "message" => "The upstream provider request failed.",
             "provider_status" => 502,
             "retryable" => true
           }

    encoded_error = Ankole.JSON.encode!(public_error)
    refute encoded_error =~ "private provider"
    refute Map.has_key?(public_error, "body")
    refute Map.has_key?(public_error, "reason")
    refute Map.has_key?(public_error, "status")
  end

  test "websocket stateful conversation run stores checkpoint instead of projected tail as durable anchor" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-compaction-anchor",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-compaction-anchor",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-compaction-anchor")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compaction-anchor-a", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [])

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compaction-anchor-b", [
        text_message("user", "second user"),
        text_message("assistant", "second assistant")
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [])

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compaction-anchor-c", [
        text_message("user", "third user"),
        text_message("assistant", "third assistant")
      ])

    {:ok, m3} = StatefulResponses.commit_complete(m3, [])

    {:ok, compaction} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        m3,
        "first turn compressed",
        m2.content ++ m3.content
      )

    assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [
             compaction.id
           ]

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "compaction-anchor-d")

    current_input = [text_message("user", "fourth user")]

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => actor_event.id}
             })

    [run] =
      Repo.all(Message)
      |> Enum.filter(
        &(get_in(&1.metadata, ["request_metadata", "actor_event_id"]) == actor_event.id)
      )

    assert run.previous_message_id == compaction.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "compaction threshold follows model context ratio with a configurable cap" do
    _result = Compaction.delete_config()

    assert %{
             tokens: 100_000,
             context_length: 400_000,
             effective_context_length: 400_000,
             threshold: 0.50,
             max_threshold_tokens: 100_000
           } = Compaction.threshold_spec(%{"context_length" => 400_000}, %{})

    assert %{
             tokens: 64_000,
             effective_context_length: 70_000
           } =
             Compaction.threshold_spec(%{"context_length" => 100_000}, %{
               "max_output_tokens" => 30_000
             })

    with_compaction_config(threshold: 0.25, max_threshold_tokens: 200_000, tail_rows: 2)

    assert %{
             tokens: 100_000,
             context_length: 400_000,
             threshold: 0.25,
             max_threshold_tokens: 200_000
           } = Compaction.threshold_spec(%{"context_length" => 400_000}, %{})
  end

  test "websocket stateful memory pre-compaction nudge does not hijack empty continuations" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-memory-nudge-empty-continuation",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-memory-nudge-empty-continuation",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-memory-nudge-empty-continuation")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "memory-nudge-empty-anchor", [
        text_message("user", "tool result continuation anchor")
      ])

    {:ok, message} = StatefulResponses.commit_complete(message, [], usage(20))

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [],
               "store" => true,
               "previous_response_id" => "resp_#{message.id}",
               "metadata" => %{"actor_event_id" => "memory-nudge-empty-continuation-event"}
             })

    provider_input = request.response_context.request["input"]
    assert provider_input == message.content
    refute inspect(provider_input) =~ brain_pre_compaction_nudge_marker()
  end

  test "websocket stateful history auto-compacts before creating the provider request" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:json, 200,
         %{
           "id" => "resp_summary",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "## Active Task\nPrior two turns were compressed.",
                   "annotations" => []
                 }
               ]
             }
           ],
           "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-auto-compaction",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "openai-auto-compaction",
                 model: model
               })
    end

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-auto-compaction")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compact-a", [
        text_message("user", "first user message with enough detail"),
        text_message("assistant", "first assistant answer")
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], camel_usage(160_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compact-b", [
        text_message("user", "second user message with enough detail"),
        text_message("assistant", "second assistant answer")
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], camel_usage(160_000))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compact-c", [
        text_message("user", "third user message kept as tail"),
        text_message("assistant", "third assistant answer kept as tail")
      ])

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(320_004))

    current_input = [text_message("user", "new current request")]

    assert {:ok, request, stateful_context} =
             StatefulLifecycle.prepare_and_start_websocket_provider_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "auto-compact-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = summarizer_request.body["input"]

    assert summarizer_request.body["model"] == "gpt-compact-light"
    assert summarizer_request.body["store"] == false
    assert summarizer_request.body["max_output_tokens"] == 8_192
    assert summarizer_request.body["reasoning"] == %{"effort" => "low"}
    assert summarizer_input =~ "first user message with enough detail"
    assert summarizer_input =~ "first assistant answer"
    assert summarizer_input =~ "second user message with enough detail"
    assert summarizer_input =~ "second assistant answer"
    assert summarizer_input =~ "<recent_context_verbatim>"
    assert summarizer_input =~ "third user message kept as tail"
    assert summarizer_input =~ "third assistant answer kept as tail"
    assert summarizer_input =~ "new current request"

    [_, conversation_section] =
      Regex.run(~r/<conversation>\n(.*?)\n<\/conversation>/s, summarizer_input)

    refute conversation_section =~ "third user message kept as tail"
    refute conversation_section =~ "third assistant answer kept as tail"
    refute conversation_section =~ "new current request"

    provider_request = request.response_context.request
    [user_orig_1, user_orig_2, compaction_item | rest] = provider_request["input"]

    assert provider_request["store"] == false
    assert user_orig_1 == hd(m1.content)
    assert user_orig_2 == hd(m2.content)
    assert compaction_item["type"] == "compaction"

    assert compaction_item["encrypted_content"] ==
             "## Active Task\nPrior two turns were compressed."

    assert rest == m3.content ++ current_input

    [compaction] =
      Repo.all(Message)
      |> Enum.filter(&(&1.type == "checkpoint"))

    assert compaction.previous_message_id == m3.id
    assert compaction.metadata["auto"] == true
    assert get_in(compaction.metadata, ["summarizer", "usage", "total_tokens"]) == 18

    run = stateful_context.message
    assert run.status == "generating"
    assert run.previous_message_id == compaction.id

    assert get_in(run.metadata, ["auto_compaction", "response_id"]) ==
             "resp_#{compaction.id}"

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

    assert get_in(artifact.content, ["summary", "text"]) ==
             "## Active Task\nPrior two turns were compressed."

    assert Enum.drop(artifact.content["output"], 3) == m3.content
  end

  test "websocket stateful auto-compaction keeps function calls with protected tool results" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 2)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-compact-light"

        {:json, 200,
         %{
           "id" => "resp_summary_tool_tail",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "## Active Task\nOnly the first row was compressed.",
                   "annotations" => []
                 }
               ]
             }
           ],
           "usage" => %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-auto-compaction-tool-tail",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: "openai-auto-compaction-tool-tail",
                 model: model
               })
    end

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-auto-compaction-tool-tail")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "compact-tool-a", [
        text_message("user", "first user message that can be summarized"),
        text_message("assistant", "first assistant answer that can be summarized")
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], camel_usage(160_000))

    function_call = [
      %{
        "type" => "function_call",
        "call_id" => "call_keep_with_tail",
        "name" => "web_search",
        "arguments" => "{}"
      }
    ]

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "compact-tool-b", function_call)

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], camel_usage(160_000))

    tool_result = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_keep_with_tail",
        "output" => "search result"
      }
    ]

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "compact-tool-c", tool_result)

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(320_004))

    {:ok, m4} =
      start_linked_stateful_message(agent.uid, conversation, m3, "compact-tool-d", [
        text_message("assistant", "final answer after the tool result")
      ])

    {:ok, m4} = StatefulResponses.commit_complete(m4, [], camel_usage(320_008))

    current_input = [text_message("user", "new current request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "auto-compact-tool-tail-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = summarizer_request.body["input"]

    assert summarizer_input =~ "first user message that can be summarized"

    [_, conversation_section] =
      Regex.run(~r/<conversation>\n(.*?)\n<\/conversation>/s, summarizer_input)

    refute conversation_section =~ "call_keep_with_tail"
    refute conversation_section =~ "search result"

    provider_request = request.response_context.request
    [user_orig_1, compaction_item | rest] = provider_request["input"]

    assert user_orig_1 == hd(m1.content)
    assert compaction_item["type"] == "compaction"

    assert compaction_item["encrypted_content"] ==
             "## Active Task\nOnly the first row was compressed."

    assert rest == function_call ++ tool_result ++ m4.content ++ current_input

    [compaction] =
      Repo.all(Message)
      |> Enum.filter(&(&1.type == "checkpoint"))

    assert compaction.previous_message_id == m4.id
    assert compaction.metadata["auto"] == true

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

    assert get_in(artifact.content, ["summary", "text"]) ==
             "## Active Task\nOnly the first row was compressed."

    assert Enum.drop(artifact.content["output"], 2) == function_call ++ tool_result ++ m4.content
  end

  test "websocket stateful auto-compaction renders reasoning summaries without encrypted content" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, response_summary("## Active Task\nReasoning summary")}
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-reasoning-redaction", base_url)

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-reasoning-redaction")

    {:ok, m1} =
      start_stateful_message(
        agent.uid,
        conversation,
        "reasoning-redaction-a",
        [
          text_message("user", "reasoning carrier"),
          %{
            "type" => "reasoning",
            "encrypted_content" => "SECRETBLOB",
            "summary" => [%{"type" => "summary_text", "text" => "thought about x"}]
          }
        ]
      )

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], camel_usage(260_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "reasoning-redaction-tail", [
        text_message("user", "tail")
      ])

    {:ok, _m2} = StatefulResponses.commit_complete(m2, [], camel_usage(260_004))

    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "reasoning-redaction-event"}
             })

    assert_receive {:gateway_request, summarizer_request}
    summarizer_input = summarizer_request.body["input"]
    refute summarizer_input =~ "SECRETBLOB"
    assert summarizer_input =~ "thought about x"
  end

  test "websocket stateful auto-compaction retries once with tighter render budget on context errors" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    base_url =
      start_recording_upstream(self(), fn
        _request ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)

          case attempt do
            1 ->
              {:json, 400, %{"error" => %{"message" => "maximum context length exceeded"}}}

            _attempt ->
              {:json, 200, response_summary("## Active Task\nRetried summary")}
          end
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-context-retry", base_url,
      profiles: [{"primary", "gpt-main", 20_000}, {"light", "gpt-compact-light", 20_000}]
    )

    {conversation, _tail} =
      compactable_conversation!(
        agent,
        "dispatch-context-retry",
        String.duplicate("wide context ", 70_000)
      )

    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "context-retry-event"}
             })

    assert_receive {:gateway_request, first_request}
    assert_receive {:gateway_request, second_request}
    assert byte_size(second_request.body["input"]) < byte_size(first_request.body["input"])
  end

  test "websocket stateful auto-compaction skips light selector for high reasoning requests" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.body["model"] == "gpt-main"
        {:json, 200, response_summary("## Active Task\nPrimary high reasoning summary")}
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-high-reasoning", base_url,
      profiles: [{"primary", "gpt-main"}]
    )

    {conversation, _tail} = compactable_conversation!(agent, "dispatch-high-reasoning")

    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "reasoning" => %{"effort" => "high"},
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "high-reasoning-event"}
             })

    assert_receive {:gateway_request, primary_request}
    assert primary_request.body["model"] == "gpt-main"
    refute_receive {:gateway_request, _request}, 100
  end

  test "websocket stateful overflow returns an explicit error when truncation is disabled" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-overflow-disabled",
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
               provider_id: "openai-overflow-disabled",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-overflow-disabled")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "overflow-disabled", [
        media_message_with_memory_nudge(
          "https://files.example.test/#{String.duplicate("large", 40)}.png"
        )
      ])

    {:ok, _message} = StatefulResponses.commit_complete(message, [], usage(24))

    assert {:error,
            {:context_overflow,
             %{
               history_usage_tokens: history_usage_tokens,
               token_threshold: 10,
               truncation: "disabled",
               reason: "no_compaction_candidate"
             }}} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "overflow-disabled-event"}
             })

    assert history_usage_tokens > 10
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
    refute_receive {:gateway_request, _request}
  end

  test "websocket stateful usage reads the latest production-shaped provider snapshot" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 120_000, tail_rows: 2)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-production-usage-shape",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-production-usage-shape",
               model: "gpt-main",
               context_length: 1_050_000
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-production-usage-shape")

    usage_snapshots = [
      {14_289, 177},
      {15_487, 478},
      {16_220, 936},
      {18_251, 2_940},
      {20_736, 364},
      {22_412, 160},
      {22_595, 169},
      {23_499, 264}
    ]

    anchor =
      usage_snapshots
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {{input_tokens, output_tokens}, index}, previous ->
        call_id = "call_production_#{index}"

        response_items =
          if index == 6 do
            [
              text_message(
                "assistant",
                "latest text #{brain_pre_compaction_nudge_marker()}"
              )
            ]
          else
            [
              %{
                "type" => "function_call",
                "call_id" => call_id,
                "name" => "command",
                "arguments" => Ankole.JSON.encode!(%{"index" => index})
              }
            ]
          end

        {:ok, response} =
          if previous do
            start_linked_stateful_message(
              agent.uid,
              conversation,
              previous,
              "production-response-#{index}",
              response_items
            )
          else
            start_stateful_message(
              agent.uid,
              conversation,
              "production-response-#{index}",
              response_items
            )
          end

        {:ok, response} =
          StatefulResponses.commit_complete(
            response,
            [],
            provider_usage(input_tokens, output_tokens)
          )

        if index < 6 or index == 7 do
          {:ok, journal} =
            start_linked_stateful_message(
              agent.uid,
              conversation,
              response,
              "production-tool-result-#{index}",
              [
                %{
                  "type" => "function_call_output",
                  "call_id" => call_id,
                  "output" => "tool result #{index}"
                }
              ]
            )

          {:ok, journal} = StatefulResponses.commit_complete(journal, [], %{})
          journal
        else
          response
        end
      end)

    assert Enum.sum(Enum.map(usage_snapshots, fn {input, output} -> input + output end)) ==
             158_977

    assert List.last(usage_snapshots) |> then(fn {input, output} -> input + output end) ==
             23_763

    current_input = [text_message("user", "new request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{anchor.id}",
               "metadata" => %{"actor_event_id" => "production-usage-shape-event"}
             })

    provider_input = request.response_context.request["input"]
    assert List.last(provider_input) == List.last(current_input)
    assert length(provider_input) == 16
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
  end

  test "websocket stateful truncation expands the stable tail for current tool output" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-stable-tail",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-stable-tail",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-truncation-stable-tail")

    {:ok, call} =
      start_stateful_message(agent.uid, conversation, "stable-tail-call", [
        %{
          "type" => "function_call",
          "call_id" => "call_stable_tail",
          "name" => "lookup",
          "arguments" => Ankole.JSON.encode!(%{"query" => "stable"})
        }
      ])

    {:ok, call} = StatefulResponses.commit_complete(call, [], usage(170))

    {:ok, tail} =
      start_linked_stateful_message(agent.uid, conversation, call, "stable-tail-latest", [
        text_message(
          "assistant",
          "latest response #{brain_pre_compaction_nudge_marker()}"
        )
      ])

    {:ok, tail} = StatefulResponses.commit_complete(tail, [], usage(180))

    current_input = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_stable_tail",
        "output" => "stable result"
      }
    ]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => "truncation-stable-tail-event"}
             })

    provider_request = request.response_context.request
    assert provider_request["input"] == call.content ++ tail.content ++ current_input
  end

  test "websocket stateful truncation keeps the compaction checkpoint with the stable tail" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-checkpoint",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-checkpoint",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-truncation-checkpoint")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "truncation-checkpoint-first", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, first} = StatefulResponses.commit_complete(first, [], usage(120))

    {:ok, checkpoint} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        first,
        "earlier work compressed",
        first.content
      )

    {:ok, tail} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        checkpoint,
        "truncation-checkpoint-tail",
        [text_message("assistant", "latest response #{brain_pre_compaction_nudge_marker()}")]
      )

    {:ok, tail} = StatefulResponses.commit_complete(tail, [], usage(180))

    current_input = [text_message("user", "next question")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => "truncation-checkpoint-event"}
             })

    provider_request = request.response_context.request

    assert [%{"type" => "compaction", "encrypted_content" => "earlier work compressed"} | _rest] =
             provider_request["input"]

    stable_tail = tail.content ++ current_input
    assert Enum.take(provider_request["input"], -length(stable_tail)) == stable_tail
    assert Enum.count(Repo.all(Message), &(&1.type == "checkpoint")) == 1
  end

  test "websocket stateful truncation auto drops older non-compactable history without changing durable anchor" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-auto",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-auto",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-truncation-auto")

    media_url = "https://files.example.test/#{String.duplicate("large", 80)}.png"

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "truncate-media", [
        media_message(media_url)
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], usage(180))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "truncate-tail", [
        text_message("user", "tail user"),
        text_message("assistant", "tail assistant #{brain_pre_compaction_nudge_marker()}")
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], usage(200))

    current_input = [text_message("user", "new request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => "truncate-auto-event"}
             })

    provider_request = request.response_context.request
    assert provider_request["input"] == m2.content ++ current_input
    assert provider_request["truncation"] == "auto"
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
    refute_receive {:gateway_request, _request}

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "truncate-auto-durable")

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => actor_event.id}
             })

    assert [run] =
             Message
             |> Repo.all()
             |> Enum.filter(
               &(StatefulResponses.response_metadata(&1)["actor_event_id"] == actor_event.id)
             )

    assert run.status == "error"
    assert run.previous_message_id == m2.id
    assert run.content == current_input
    assert run.metadata["truncation"] == "auto"

    assert %{
             "dropped_message_count" => 1,
             "dropped_opaque_message_count" => 1,
             "dropped_opaque_messages" => [
               %{
                 "message_id" => dropped_message_id,
                 "response_id" => dropped_response_id,
                 "items" => [
                   %{
                     "type" => "input_image",
                     "role" => "user",
                     "refs" => %{"image_url" => ^media_url}
                   }
                 ]
               }
             ]
           } = run.metadata["auto_truncation"]

    assert dropped_message_id == m1.id
    assert dropped_response_id == "resp_#{m1.id}"
  end

  test "websocket stateful truncation auto does not start history with orphaned tool output" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 220, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-main"

        {:json, 200,
         %{
           "id" => "resp_empty_tool_summary",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 9, "output_tokens" => 0, "total_tokens" => 9}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-tool-output",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-tool-output",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-truncation-tool-output")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "tool-truncate-call", [
        %{
          "type" => "function_call",
          "call_id" => "call_truncated",
          "name" => "lookup",
          "arguments" => Ankole.JSON.encode!(%{"query" => String.duplicate("wide ", 120)})
        }
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "tool-truncate-output", [
        %{
          "type" => "function_call_output",
          "call_id" => "call_truncated",
          "output" => "tool output that must not become an orphaned prefix"
        }
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "tool-truncate-tail", [
        text_message("user", "latest tail #{brain_pre_compaction_nudge_marker()}")
      ])

    {:ok, _m3} = StatefulResponses.commit_complete(m3, [], usage(240))

    current_input = [text_message("user", "new request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => "truncate-orphan-fco-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    provider_input = request.response_context.request["input"]
    refute Enum.any?(provider_input, &(&1 in m1.content))
    refute Enum.any?(provider_input, &(&1 in m2.content))
    assert Enum.take(provider_input, -2) == m3.content ++ current_input
  end

  test "websocket stateful truncation auto falls back when summarizer fails" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        assert request.path == "v1/responses"
        assert request.body["model"] == "gpt-main"

        {:json, 200,
         %{
           "id" => "resp_empty_summary",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 9, "output_tokens" => 0, "total_tokens" => 9}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-summarizer-fail",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-truncation-summarizer-fail",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-truncation-summary-fail")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "summary-fail-a", [
        text_message("user", String.duplicate("first ", 20))
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], usage(120))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "summary-fail-b", [
        text_message("assistant", String.duplicate("second ", 20))
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], usage(120))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "summary-fail-c", [
        text_message("user", "latest tail #{brain_pre_compaction_nudge_marker()}")
      ])

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], usage(260))

    current_input = [text_message("user", "new request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "truncation" => "auto",
               "metadata" => %{"actor_event_id" => "truncate-summary-fail-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    provider_request = request.response_context.request
    refute Enum.any?(provider_request["input"], &(&1 in m1.content))
    assert Enum.take(provider_request["input"], -2) == m3.content ++ current_input
    refute Enum.any?(Repo.all(Message), &(&1.type == "checkpoint"))
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
            {:credential_pool_exhausted,
             %{
               "retry_at" => retry_at,
               "statuses" => statuses
             }}} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert_receive {:gateway_request, retry_request}
    assert retry_request.path == "chat/completions"
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
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
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
            :actor_event_id,
            :model,
            :api_resolver,
            :upstream_host,
            :request_bytes,
            :input_item_count,
            :tool_count,
            :function_call_output_count,
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
                  {:upstream_response_failed, 502,
                   %{
                     "error" => %{
                       "code" => "provider_unavailable",
                       "message" => "private provider message",
                       "type" => "server_error"
                     }
                   }}} =
                   AIGateway.open_sse_stream(agent.uid, %{
                     "model" => "primary",
                     "stream" => true,
                     "metadata" => %{"actor_event_id" => "actor-event-diagnostics"},
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
                       %{"role" => "user", "content" => "private prompt"}
                     ],
                     "tools" => [
                       %{
                         "type" => "function",
                         "name" => "view_image",
                         "parameters" => %{"type" => "object"}
                       }
                     ]
                   })
        end
      )

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"

    assert get_in(request.body, ["messages", Access.at(1), "content"]) ==
             "[Image output is attached in the next user message.]"

    assert log =~ "event=ai_gateway.response_failed"
    assert log =~ "actor_event_id=actor-event-diagnostics"
    assert log =~ "model=openai/gpt-5.5"
    assert log =~ "api_resolver=openai_chat_completions"
    assert log =~ "upstream_host=127.0.0.1"
    assert log =~ "input_item_count=3"
    assert log =~ "tool_count=1"
    assert log =~ "function_call_output_count=1"
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               },
               connection_options: %{
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
    assert request.response_context.request["store"] == false
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
    assert request.body["reasoning_effort"] == "high"
    refute Map.has_key?(request.body, "reasoningEffort")
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
                 "transport" => %{"http_versions" => ["h1"]}
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

  test "openai_compatible requires base URL and records protocol choices" do
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
    assert request.body["reasoning_effort"] == "high"
    refute Map.has_key?(request.body, "reasoningEffort")
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
    assert request.body["store"] == false
    assert request.body["reasoning"] == %{"effort" => "high"}
    refute Map.has_key?(request.body, "reasoningEffort")
    assert List.last(events)["type"] == "response.completed"
    assert v1_body["id"] == "resp_azure_v1"
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
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
                 "transport" => %{"http_versions" => ["h1"], "compression" => []}
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

  defp response_summary(text) do
    %{
      "id" => "resp_summary_#{System.unique_integer([:positive])}",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => text, "annotations" => []}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
    }
  end

  defp create_openai_compaction_provider!(agent, provider_id, base_url, opts \\ []) do
    profiles =
      Keyword.get(opts, :profiles, [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}])

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket",
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    for profile_entry <- profiles do
      {profile, model, context_length} =
        case profile_entry do
          {profile, model} -> {profile, model, nil}
          {profile, model, context_length} -> {profile, model, context_length}
        end

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(
                 agent.uid,
                 profile,
                 %{
                   provider_id: provider_id,
                   model: model
                 }
                 |> maybe_put("context_length", context_length)
               )
    end
  end

  defp compactable_conversation!(agent, conversation_key, extra_text \\ "") do
    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, conversation_key)

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "#{conversation_key}-a", [
        text_message(
          "user",
          "first user message with enough detail " <> String.duplicate("wide ", 80)
        ),
        text_message("assistant", "first assistant answer " <> extra_text)
      ])

    {:ok, m1} = StatefulResponses.commit_complete(m1, [], camel_usage(160_000))

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "#{conversation_key}-b", [
        text_message("user", "second user message with enough detail"),
        text_message("assistant", "second assistant answer " <> extra_text)
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], camel_usage(160_000))

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "#{conversation_key}-tail", [
        text_message("user", "tail user says stop doing X")
      ])

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(320_004))

    {conversation, m3}
  end

  defp start_stateful_message(agent_uid, conversation, source_event_id, request_items) do
    actor_event = actor_event_fixture(agent_uid, conversation.conversation_key, source_event_id)

    StatefulResponses.start_response_run(%{
      subject_uid: agent_uid,
      conversation_id: conversation.id,
      request_items: request_items,
      metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}}
    })
  end

  defp start_linked_stateful_message(
         agent_uid,
         conversation,
         previous,
         source_event_id,
         request_items
       ) do
    actor_event = actor_event_fixture(agent_uid, conversation.conversation_key, source_event_id)

    StatefulResponses.start_response_run(%{
      subject_uid: agent_uid,
      previous_response_id: "resp_#{previous.id}",
      request_items: request_items,
      metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}}
    })
  end

  defp text_message(role, text) do
    content_type = if role == "assistant", do: "output_text", else: "input_text"

    %{
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => content_type, "text" => text, "annotations" => []}]
    }
  end

  defp media_message(image_url) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_image", "image_url" => image_url}]
    }
  end

  defp media_message_with_memory_nudge(image_url) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [
        %{"type" => "input_image", "image_url" => image_url},
        %{
          "type" => "input_text",
          "text" => "[#{brain_pre_compaction_nudge_marker()}]"
        }
      ]
    }
  end

  defp brain_pre_compaction_nudge_marker, do: "ankole.brain.pre_compaction_nudge.v1"

  defp usage(total_tokens), do: %{"usage" => %{"total_tokens" => total_tokens}}

  defp camel_usage(total_tokens), do: %{"usage" => %{"totalTokens" => total_tokens}}

  defp provider_usage(input_tokens, output_tokens) do
    %{
      "usage" => %{
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "total_tokens" => input_tokens + output_tokens
      }
    }
  end

  defp with_compaction_config(config) do
    assert {:ok, _config} = Compaction.put_config(Map.new(config))

    on_exit(fn ->
      _result = Compaction.delete_config()
      :ok
    end)
  end

  defp insert_compaction_checkpoint(
         agent_uid,
         conversation,
         previous_message,
         summary_text,
         retained_items,
         metadata \\ %{}
       ) do
    with {:ok, artifact} <-
           CompactionArtifacts.insert_artifact(%{
             subject_uid: agent_uid,
             conversation_id: conversation.id,
             summary_text: summary_text,
             retained_items: retained_items,
             retention: %{
               "strategy" => "tail_rows",
               "requested" => 2,
               "actual" => length(retained_items)
             },
             usage: %{}
           }) do
      StatefulResponses.create_compaction_checkpoint(%{
        subject_uid: agent_uid,
        previous_response_id: "resp_#{previous_message.id}",
        artifact: artifact,
        metadata: metadata
      })
    end
  end

  defp actor_event_fixture(agent_uid, session_id, source_event_id) do
    now = DateTime.utc_now(:microsecond)

    attrs = %{
      agent_uid: agent_uid,
      binding_name: "test-binding",
      session_id: session_id,
      source_event_id: "#{source_event_id}-#{System.unique_integer([:positive])}",
      type: "im.message.addressed",
      available_at: now,
      queue_sequence: System.unique_integer([:positive]),
      input_state: "open",
      payload: %{"text" => source_event_id}
    }

    %ActorEvent{}
    |> ActorEvent.changeset(attrs)
    |> Repo.insert!()
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

  defp collect_sse_chunks(stream, events) do
    with :ok <- AIGateway.read_response_stream(stream, 1) do
      receive do
        {:ai_gateway_response_stream, ref, :events, batch, :continue}
        when ref == stream.ref ->
          collect_sse_chunks(stream, events ++ batch)

        {:ai_gateway_response_stream, ref, :events, batch, {:terminal, _outcome}}
        when ref == stream.ref ->
          {:ok, events ++ batch}
      after
        1_000 ->
          _ = AIGateway.cancel_response_stream(stream, "test_receive_timeout")
          {:error, :response_stream_receive_timeout}
      end
    else
      {:error, reason} -> {:error, reason}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
