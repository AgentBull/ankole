defmodule AnkoleWeb.AIGatewayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  import Ankole.AIGatewayCase,
    only: [chat_completion_stream_events: 2, start_upstream_server: 1]

  import AnkoleWeb.AIGatewayControllerTestHelpers
  import ExUnit.CaptureLog

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ResponseStream.State, as: ResponseStreamState
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Security.SSRFFilter
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.Repo
  alias Ankole.AIGateway.Tokens

  defmodule NativeResponsesUpstreamPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "POST", request_path: "/v1/responses"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Ankole.JSON.decode!(body)
      send(opts[:test_pid], {:native_controller_upstream_request, request})

      case opts[:mode] do
        :error_then_close ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          error_event = %{
            "type" => "error",
            "sequence_number" => 0,
            "error" => %{
              "type" => "server_error",
              "code" => "upstream_stream_break",
              "message" => "provider stream broke"
            }
          }

          {:ok, conn} =
            Plug.Conn.chunk(conn, "data: #{Ankole.JSON.encode!(error_event)}\n\n")

          conn

        :rate_limit ->
          conn
          |> put_resp_header(
            "x-codex-primary-reset-at",
            Integer.to_string(opts[:reset_at_unix])
          )
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            Ankole.JSON.encode!(%{
              "error" => %{"message" => "native upstream rate limit"}
            })
          )

        _mode ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          "resp_native_controller"
          |> AnkoleWeb.AIGatewayControllerTestHelpers.response_sse_events(
            "gpt-5.5",
            "hello native controller"
          )
          |> Enum.reduce(conn, fn event, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Ankole.JSON.encode!(event)}\n\n")
            conn
          end)
          |> then(fn conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
            conn
          end)
      end
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Ankole.JSON.encode!(%{"error" => %{"message" => "not found"}}))
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:ankole, Ankole.AIGateway) end)
    :ok
  end

  test "AIGateway routes reject non-agent bearer access", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-an-agent-token")
      |> post(~p"/api/v1/ai-gateway/responses", %{"model" => "primary", "input" => "hello"})

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "Codex binding routes the semantic model through the frozen selector and options", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, Ankole.AIGatewayCase.chat_completion_body("openai/gpt-5.6-sol", "done")}
      end)

    provider_id = "codex-binding-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    binding =
      %{
        "selector" => "#{provider_id}/openai/gpt-5.6-sol",
        "provider_options" => %{
          "reasoningEffort" => "xhigh",
          "textVerbosity" => "low"
        },
        "supports_parallel_tool_calls" => true,
        "input_modalities" => ["text"]
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("x-ankole-aigateway-model-binding", binding)
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "gpt-5.6-sol",
        "input" => "hello",
        "provider_options" => %{
          "reasoningEffort" => "minimal",
          "textVerbosity" => "high"
        },
        "reasoning" => %{"effort" => "minimal"}
      })

    assert json_response(conn, 200)["status"] == "completed"
    assert_receive {:gateway_request, upstream_request}
    assert upstream_request.body["model"] == "openai/gpt-5.6-sol"
    assert upstream_request.body["reasoning"] == %{"effort" => "xhigh"}
    assert upstream_request.body["textVerbosity"] == "low"
    assert upstream_request.body["parallel_tool_calls"] == true
  end

  test "responses retrieve returns an agent-scoped stored response resource", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    input_item = %{
      "id" => "msg_retrieve_input",
      "type" => "message",
      "status" => "completed",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "Ping"}]
    }

    first_output_item = %{
      "id" => "msg_retrieve_first_output",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Pong", "annotations" => []}]
    }

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "retrieve-response-controller")

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [input_item],
        metadata: %{
          "model" => "gpt-test",
          "request_metadata" => %{"visible" => "yes"}
        }
      })

    assert {:ok, first} =
             StatefulResponses.commit_complete(first, [first_output_item], %{
               "usage" => response_usage_fixture()
             })

    second_input_item = %{
      "id" => "call_retrieve_output",
      "type" => "function_call_output",
      "status" => "completed",
      "call_id" => "call_retrieve",
      "output" => "tool result"
    }

    second_output_item = %{
      "id" => "msg_retrieve_second_output",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Done", "annotations" => []}]
    }

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        previous_response_id: "resp_#{first.id}",
        request_items: [second_input_item],
        metadata: %{
          "model" => "gpt-test",
          "request_metadata" => %{"visible" => "yes"}
        }
      })

    assert {:ok, second} =
             StatefulResponses.commit_complete(second, [second_output_item], %{
               "usage" => %{
                 "inputTokens" => 7,
                 "outputTokens" => 5,
                 "totalTokens" => 12,
                 "input_tokens_details" => %{"cached_tokens" => 3},
                 "output_tokens_details" => %{"reasoning_tokens" => 2}
               },
               "provider_metadata" => %{"id" => "provider_resp_second", "model" => "gpt-test"},
               "stop_reason" => "stop"
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/resp_#{second.id}")

    body = json_response(conn, 200)
    assert_openresponses_response_resource(body)
    assert body["id"] == "resp_#{second.id}"
    assert body["previous_response_id"] == "resp_#{first.id}"
    assert body["conversation"]["id"] == "conv_#{conversation.id}"
    assert body["model"] == "gpt-test"
    assert body["metadata"] == %{"visible" => "yes"}
    assert body["input"] == [second_input_item]
    assert body["output"] == [second_output_item]
    assert body["provider_metadata"] == %{"id" => "provider_resp_second", "model" => "gpt-test"}

    assert body["usage"] == %{
             "input_tokens" => 7,
             "output_tokens" => 5,
             "total_tokens" => 12,
             "input_tokens_details" => %{"cached_tokens" => 3},
             "output_tokens_details" => %{"reasoning_tokens" => 2}
           }

    assert body["tool_results"] == [
             %{
               "id" => "call_retrieve_output",
               "status" => "completed",
               "call_id" => "call_retrieve",
               "output" => "tool result"
             }
           ]

    assert body["stop_reason"] == "stop"
  end

  test "responses retrieve keeps role-only request input out of output", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    input_item = %{"role" => "user", "content" => "Hello"}

    output_item = %{
      "id" => "msg_retrieve_role_only_output",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Hi", "annotations" => []}]
    }

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "retrieve-role-only-input")

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [input_item],
        metadata: %{"model" => "gpt-test"}
      })

    assert {:ok, message} =
             StatefulResponses.commit_complete(message, [output_item], %{
               "usage" => response_usage_fixture()
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/resp_#{message.id}")

    body = json_response(conn, 200)
    assert body["input"] == [input_item]
    assert body["output"] == [output_item]
  end

  test "responses retrieve does not expose another agent's stored response", %{conn: conn} do
    %{principal: owner} = agent_fixture()
    %{principal: intruder} = agent_fixture()
    assert {:ok, intruder_key} = Tokens.mint_for_agent(intruder.uid)

    {:ok, conversation} =
      Conversations.ensure_conversation(owner.uid, "retrieve-response-cross-agent")

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        subject_uid: owner.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "id" => "msg_cross_agent_input",
            "type" => "message",
            "status" => "completed",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "secret"}]
          }
        ],
        metadata: %{"model" => "gpt-test"}
      })

    assert {:ok, message} =
             StatefulResponses.commit_complete(
               message,
               [
                 %{
                   "id" => "msg_cross_agent_output",
                   "type" => "message",
                   "status" => "completed",
                   "role" => "assistant",
                   "content" => [
                     %{"type" => "output_text", "text" => "hidden", "annotations" => []}
                   ]
                 }
               ],
               %{"usage" => response_usage_fixture()}
             )

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{intruder_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/resp_#{message.id}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "responses retrieve returns in_progress for generating rows and rejects temporary ids", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "retrieve-response-not-terminal")

    {:ok, generating} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "id" => "msg_generating_input",
            "type" => "message",
            "status" => "completed",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "still running"}]
          }
        ],
        metadata: %{"model" => "gpt-test"}
      })

    generating
    |> Ecto.Changeset.change(
      content:
        generating.content ++
          [
            %{
              "id" => "msg_partial_output",
              "type" => "message",
              "status" => "in_progress",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "partial"}]
            }
          ]
    )
    |> Repo.update!()

    generating_conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/resp_#{generating.id}")

    assert %{
             "id" => "resp_" <> _,
             "object" => "response",
             "status" => "in_progress",
             "input" => [
               %{
                 "id" => "msg_generating_input",
                 "content" => [%{"text" => "still running", "type" => "input_text"}]
               }
             ],
             "output" => []
           } = json_response(generating_conn, 200)

    tmp_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/tmp_resp_#{Ecto.UUID.generate()}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(tmp_conn, 404)

    raw_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get("/api/v1/ai-gateway/responses/#{generating.id}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(raw_conn, 404)
  end

  test "responses delete and cancel endpoints are not implemented", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    response_id = "resp_#{Ecto.UUID.generate()}"

    delete_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> delete("/api/v1/ai-gateway/responses/#{response_id}")

    assert response(delete_conn, 404)

    cancel_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post("/api/v1/ai-gateway/responses/#{response_id}/cancel", %{})

    assert response(cancel_conn, 404)
  end

  test "models endpoint returns OpenRouter-shaped selectors for an agent token", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-models",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"supported_parameters" => "tools"})

    assert %{"data" => models} = json_response(conn, 200)
    assert primary = Enum.find(models, &(&1["id"] == "primary"))
    assert explicit = Enum.find(models, &(&1["id"] == "openai-models/gpt-4o-mini"))

    assert primary["canonical_slug"] == explicit["id"]
    assert get_in(primary, ["architecture", "output_modalities"]) == ["text"]
    assert "tools" in primary["supported_parameters"]
    assert primary["context_length"] == 128_000
    assert get_in(primary, ["top_provider", "max_completion_tokens"]) == 16_384
    assert Map.has_key?(primary, "pricing")
    assert Map.has_key?(primary, "top_provider")
  end

  test "models endpoint exposes custom aliases only to their Agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-custom-alias",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: "AGENT_LOCAL_ALIAS_MARKER",
               provider_id: "openai-custom-alias",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"q" => "AGENT_LOCAL_ALIAS_MARKER"})

    assert %{"data" => agent_models} = json_response(conn, 200)

    assert %{
             "id" => "kimi",
             "name" => "kimi",
             "description" => "AGENT_LOCAL_ALIAS_MARKER",
             "canonical_slug" => "openai-custom-alias/gpt-4o-mini"
           } = Enum.find(agent_models, &(&1["id"] == "kimi"))

    assert {:ok, other_api_key} = Tokens.mint_for_agent(other_agent.uid)

    other_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{other_api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"q" => "AGENT_LOCAL_ALIAS_MARKER"})

    assert %{"data" => other_models} = json_response(other_conn, 200)
    refute Enum.any?(other_models, &(&1["id"] == "kimi"))

    admin_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{admin_access_token()}")
      |> get(~p"/api/v1/ai-gateway/models", %{"q" => "AGENT_LOCAL_ALIAS_MARKER"})

    assert %{"data" => admin_models} = json_response(admin_conn, 200)
    refute Enum.any?(admin_models, &(&1["id"] == "kimi"))
  end

  test "Codex models manifest keeps the runtime slug on standard Responses", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-models",
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: "chatgpt-models",
               model: "gpt-5.6-sol"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"client_version" => "0.147.0"})

    assert %{"models" => models} = json_response(conn, 200)
    assert runtime = Enum.find(models, &(&1["slug"] == "gpt-5.6-sol"))
    assert runtime["supports_search_tool"]
    assert runtime["use_responses_lite"] == false
  end

  test "models endpoint lists LLM aliases and no retired embedding or rerank aliases", %{
    conn: conn
  } do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-models-all-capabilities",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models-all-capabilities",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models")

    assert %{"data" => models} = json_response(conn, 200)
    selectors = MapSet.new(models, & &1["id"])

    assert MapSet.member?(selectors, "primary")

    # Embedding and rerank are instance-global Brain models, not Agent
    # profile aliases; only explicit provider/model selectors reach them.
    refute MapSet.member?(selectors, "embedding.default")
    refute MapSet.member?(selectors, "rerank.default")
  end

  test "web tool endpoints use provider-backed AIGateway profiles", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn
        %{path: "v1/search"} ->
          {:json, 200,
           %{
             "results" => [
               %{
                 "title" => "Ankole Web",
                 "url" => "https://example.com/ankole",
                 "excerpts" => ["AIGateway web search"]
               }
             ]
           }}

        %{path: "v1/extract"} ->
          {:json, 200,
           %{
             "results" => [
               %{
                 "title" => "Ankole Web",
                 "url" => "https://example.com/ankole",
                 "excerpts" => ["Extracted page text"]
               }
             ]
           }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-main",
               provider_kind: "parallel",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "parallel-web-main",
               model: "default"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "parallel-web-main",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole web",
        "limit" => 2
      })

    assert %{
             "success" => true,
             "query" => "ankole web",
             "results" => [%{"title" => "Ankole Web", "snippet" => "AIGateway web search"}]
           } = json_response(conn, 200)

    assert_receive {:gateway_request, search_request}
    assert search_request.path == "v1/search"
    assert search_request.headers["x-api-key"] == "parallel-key"
    assert search_request.body["objective"] == "ankole web"
    assert search_request.body["advanced_settings"]["max_results"] == 2
    refute Map.has_key?(search_request.body, "model")

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_fetch", %{
        "model" => "web_fetch.default",
        "urls" => ["https://example.com/ankole"]
      })

    assert %{
             "success" => true,
             "results" => [
               %{"url" => "https://example.com/ankole", "text" => "Extracted page text"}
             ]
           } = json_response(conn, 200)

    assert_receive {:gateway_request, extract_request}
    assert extract_request.path == "v1/extract"
    assert extract_request.body["urls"] == ["https://example.com/ankole"]
    refute Map.has_key?(extract_request.body, "model")
  end

  test "web_fetch rejects non-public URLs before provider dispatch when SSRF filtering is on",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-private-url",
               provider_kind: "parallel",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "parallel-web-private-url",
               model: "default"
             })

    assert {:ok, _value} =
             AppConfigure.put_global(SSRFFilter.definition(), true)

    on_exit(fn -> AppConfigureCache.clear_for_test() end)

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    for url <- [
          "https://127.0.0.1/private",
          "https://10.0.0.8/internal",
          "https://192.168.1.20/console",
          "https://intranet.localhost/app"
        ] do
      conn =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{api_key.api_key}")
        |> post(~p"/api/v1/ai-gateway/web_fetch", %{
          "model" => "web_fetch.default",
          "urls" => [url]
        })

      assert %{"error" => %{"code" => "invalid_urls"}} = json_response(conn, 400)
    end
  end

  test "web_fetch allows private-network URLs by default and dispatches to the provider",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn
        %{path: "v1/extract"} ->
          {:json, 200,
           %{
             "results" => [
               %{
                 "title" => "Intranet Wiki",
                 "url" => "https://192.168.10.20/wiki",
                 "excerpts" => ["Intranet page text"]
               }
             ]
           }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-intranet",
               provider_kind: "parallel",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "parallel-web-intranet",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_fetch", %{
        "model" => "web_fetch.default",
        "urls" => ["https://192.168.10.20/wiki"]
      })

    assert %{
             "success" => true,
             "results" => [%{"url" => "https://192.168.10.20/wiki"}]
           } = json_response(conn, 200)

    assert_receive {:gateway_request, extract_request}
    assert extract_request.path == "v1/extract"
    assert extract_request.body["urls"] == ["https://192.168.10.20/wiki"]
  end

  test "web_fetch rejects cloud metadata endpoints even when the private-network block is off",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-metadata-url",
               provider_kind: "parallel",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "parallel-web-metadata-url",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    for url <- [
          "https://metadata.google.internal/computeMetadata/v1/",
          "https://169.254.169.254/latest/meta-data/",
          "https://[fd00:ec2::254]/latest/meta-data/",
          "https://[fe80::1]/admin"
        ] do
      conn =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{api_key.api_key}")
        |> post(~p"/api/v1/ai-gateway/web_fetch", %{
          "model" => "web_fetch.default",
          "urls" => [url]
        })

      assert %{"error" => %{"code" => "invalid_urls"}} = json_response(conn, 400)
    end
  end

  test "web_search can use Jina Search as a provider-backed profile", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn %{path: "search"} ->
        {:json, 200,
         %{
           "results" => [
             %{
               "title" => "Ankole Search",
               "url" => "https://example.com/search",
               "mainContent" => "Jina search result body"
             }
           ]
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-search-web-main",
               provider_kind: "jina_search",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "jina-key"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "jina-search-web-main",
               model: "default",
               provider_options: %{"gl" => "us", "hl" => "en"}
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole web",
        "limit" => 3
      })

    assert %{
             "success" => true,
             "query" => "ankole web",
             "results" => [%{"title" => "Ankole Search", "snippet" => "Jina search result body"}]
           } = json_response(conn, 200)

    assert_receive {:gateway_request, search_request}
    assert search_request.path == "search"
    assert search_request.headers["authorization"] == "Bearer jina-key"
    assert search_request.headers["content-type"] == "application/json"
    assert search_request.body["q"] == "ankole web"
    assert search_request.body["num"] == 3
    assert search_request.body["gl"] == "us"
    assert search_request.body["hl"] == "en"
    refute Map.has_key?(search_request.body, "model")
  end

  test "web_search uses the AgentBull Cloud v1 API with Bearer authentication", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn %{path: "web-search/v1/search"} ->
        {:json, 200,
         %{
           "query" => "ankole web",
           "sources" => ["volc", "serper", "exa"],
           "timeRange" => "1w",
           "top" => 3,
           "perSourceCandidateTarget" => 5,
           "totalFetched" => 2,
           "totalDeduped" => 1,
           "totalReturned" => 1,
           "items" => [
             %{
               "title" => "Ankole Cloud Search",
               "url" => "https://example.com/ankole",
               "snippet" => "AgentBull Cloud search result",
               "publishedAt" => "2026-08-11T00:00:00Z",
               "primarySource" => "exa",
               "sources" => ["exa"],
               "rerankScore" => 0.9
             }
           ]
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "agentbull-cloud-main",
               provider_kind: "agentbull_cloud",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "agentbull-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "agentbull-cloud-main",
               model: "default",
               provider_options: %{
                 "sources" => "all",
                 "timeRange" => "1w",
                 "skip_cache" => true
               }
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole web",
        "limit" => 3
      })

    assert %{
             "success" => true,
             "query" => "ankole web",
             "results" => [
               %{
                 "title" => "Ankole Cloud Search",
                 "url" => "https://example.com/ankole",
                 "snippet" => "AgentBull Cloud search result",
                 "published_at" => "2026-08-11T00:00:00Z",
                 "score" => 0.9
               }
             ]
           } = json_response(conn, 200)

    assert_receive {:gateway_request, search_request}
    assert search_request.path == "web-search/v1/search"
    assert search_request.headers["authorization"] == "Bearer agentbull-key"
    assert search_request.headers["content-type"] == "application/json"
    assert search_request.body["q"] == "ankole web"
    assert search_request.body["top"] == 3
    assert search_request.body["sources"] == "all"
    assert search_request.body["timeRange"] == "1w"
    assert search_request.body["skip_cache"] == true
    refute Map.has_key?(search_request.body, "model")
  end

  test "failed synchronous provider requests log safe routing diagnostics", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn %{path: "web-search/v1/search"} ->
        {:json, 422,
         %{
           "error" => %{
             "code" => "response_validation_failed",
             "message" => "private upstream response",
             "type" => "server_error"
           }
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "agentbull-web-diagnostics",
               provider_kind: "agentbull_cloud",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "agentbull-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "agentbull-web-diagnostics",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    log =
      capture_log(
        [
          level: :warning,
          metadata: [
            :event,
            :capability,
            :provider_id,
            :provider_kind,
            :model,
            :api_resolver,
            :upstream_host,
            :duration_ms,
            :error_code,
            :provider_status,
            :provider_error_code,
            :provider_error_type,
            :retryable
          ]
        ],
        fn ->
          conn =
            conn
            |> put_req_header("authorization", "Bearer #{api_key.api_key}")
            |> post(~p"/api/v1/ai-gateway/web_search", %{
              "model" => "web_search.default",
              "query" => "private query",
              "limit" => 3
            })

          assert %{
                   "error" => %{
                     "code" => "upstream_response_failed",
                     "message" => "private upstream response"
                   }
                 } =
                   json_response(conn, 422)
        end
      )

    assert_receive {:gateway_request, request}
    assert request.path == "web-search/v1/search"
    assert log =~ "event=ai_gateway.request_failed"
    assert log =~ "capability=web_search"
    assert log =~ "provider_id=agentbull-web-diagnostics"
    assert log =~ "provider_kind=agentbull_cloud"
    assert log =~ "model=default"
    assert log =~ "api_resolver=agentbull_web_search"
    assert log =~ "upstream_host=127.0.0.1"
    assert log =~ "error_code=upstream_response_failed"
    assert log =~ "provider_status=422"
    assert log =~ "provider_error_code=response_validation_failed"
    assert log =~ "provider_error_type=server_error"
    refute log =~ "retryable=true"
    refute log =~ "private query"
    refute log =~ "private upstream response"
  end

  test "an invalid upstream success body returns a safe bad gateway error", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, ["private-upstream-body"]}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-controller-body",
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
               provider_id: "openrouter-invalid-controller-body",
               model: "openai/gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello"
      })

    assert %{
             "error" => %{
               "code" => "invalid_upstream_response",
               "message" => "upstream provider returned an invalid response"
             }
           } = json_response(conn, 502)

    refute response(conn, 502) =~ "private-upstream-body"
  end

  test "web_search preserves transport failure after a credential retry", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "agentbull-web-transport-failure",
               provider_kind: "agentbull_cloud",
               base_url: "http://127.0.0.1:1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "agentbull-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "agentbull-web-transport-failure",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole",
        "limit" => 3
      })

    assert %{"error" => %{"code" => "upstream_transport_failed"}} =
             json_response(conn, 502)
  end

  test "web_search validates query and limit before provider dispatch", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-invalid-request",
               provider_kind: "parallel",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "parallel-web-invalid-request",
               model: "default"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => ""
      })

    assert %{"error" => %{"code" => "missing_query"}} = json_response(conn, 400)

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole",
        "limit" => 101
      })

    assert %{"error" => %{"code" => "invalid_limit"}} = json_response(conn, 400)
  end

  test "models endpoint lists duplicate configured providers and skips admin aliases", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()

    for provider_id <- ["openai-models-duplicate-a", "openai-models-duplicate-b"] do
      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
                 }
               })
    end

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models-duplicate-a",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"q" => "gpt-4o-mini"})

    assert %{"data" => agent_models} = json_response(conn, 200)
    agent_selectors = MapSet.new(agent_models, & &1["id"])

    assert MapSet.member?(agent_selectors, "openai-models-duplicate-a/gpt-4o-mini")
    assert MapSet.member?(agent_selectors, "openai-models-duplicate-b/gpt-4o-mini")
    assert MapSet.member?(agent_selectors, "primary")

    admin_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{admin_access_token()}")
      |> get(~p"/api/v1/ai-gateway/models", %{"q" => "gpt-4o-mini"})

    assert %{"data" => admin_models} = json_response(admin_conn, 200)
    admin_selectors = MapSet.new(admin_models, & &1["id"])

    assert MapSet.member?(admin_selectors, "openai-models-duplicate-a/gpt-4o-mini")
    assert MapSet.member?(admin_selectors, "openai-models-duplicate-b/gpt-4o-mini")
    refute MapSet.member?(admin_selectors, "primary")
  end

  test "admin console JWT can access AIGateway with explicit provider model selectors", %{
    conn: conn
  } do
    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_fixture(request.body)}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-admin-access",
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

    api_key = admin_access_token()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "openrouter-admin-access/openai/gpt-5.5",
        "input" => "hello"
      })

    assert body = json_response(conn, 200)
    assert body["model"] == "openai/gpt-5.5"
    assert body["status"] == "completed"

    assert_receive {:gateway_request, request}
    assert request.path == "chat/completions"
    assert request.body["model"] == "openai/gpt-5.5"
  end

  test "responses endpoint supports v1 SSE with an agent AIGateway token", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200, response_sse_events("resp_sse", "gpt-5.5", "hello from sse")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-sse-main",
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
               provider_id: "openai-sse-main",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => true,
        "max_tool_calls" => 2,
        "stream_options" => %{"include_usage" => true},
        "service_tier" => "priority"
      })

    assert response = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    events = decode_sse_events(response)

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
    assert response =~ "event: response.output_text.delta"
    assert response =~ "event: response.completed"
    assert response =~ "data: [DONE]"
    assert response =~ ~s("type":"response.completed")
    assert response =~ ~s("id":"resp_sse")
    assert_sse_event_names_match_body_types(response)

    assert_receive {:gateway_request, request}
    assert request.path == "v1/responses"
    assert request.body["stream"] == true
    assert request.body["max_tool_calls"] == 2
    assert request.body["stream_options"] == %{"include_usage" => true}
    assert request.body["store"] == false
    refute Map.has_key?(request.body, "service_tier")

    assert %{"type" => "response.completed", "response" => body} = List.last(events)
    assert_openresponses_response_resource(body)
    assert body["previous_response_id"] == nil
  end

  test "HTTP SSE accepts mixed tool owners when tool_choice is none", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200, response_sse_events("resp_mixed_tool_budget_none", "gpt-5.5", "No tool ran.")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-http-mixed-tool-budget-none",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-http-mixed-tool-budget-none",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
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
        "max_tool_calls" => 1,
        "stream" => true
      })

    response = response(conn, 200)
    assert response =~ "event: response.completed"

    assert_receive {:gateway_request, request}
    assert request.path == "v1/responses"
    assert request.body["tool_choice"] == "none"
    assert request.body["max_tool_calls"] == 1
  end

  test "native Responses rejects an invalid tool name before provider dispatch" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "must not reach upstream"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-invalid-tool-name-http",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-invalid-tool-name-http",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      api_key.api_key
      |> gateway_conn()
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "Run the tool.",
        "tools" => [
          %{
            "type" => "function",
            "name" => "get.price",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ]
      })

    assert %{
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_tool_contract",
               "param" => nil,
               "message" => message
             }
           } = json_response(conn, 400)

    assert message == "The Responses tool declaration or tool-call history is invalid."
    refute response(conn, 400) =~ "invalid_responses_identifier"
    refute response(conn, 400) =~ "get.price"
    refute_receive {:gateway_request, _request}
  end

  test "HTTP SSE ignores later built-ins and preserves the provider terminal" do
    state =
      ResponseStreamState.new(
        "agent-test",
        %{"max_tool_calls" => 1},
        %{"api_resolver" => "openai_chat_completions"}
      )

    {:ok, state, [_created], :continue} =
      ResponseStreamState.observe(
        state,
        %{
          "type" => "response.created",
          "sequence_number" => 0,
          "response" => %{"id" => "resp_http_limit", "status" => "in_progress"}
        },
        0
      )

    {:ok, state, [_added], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.added", "search_1", 0, 1),
        1
      )

    {:ok, state, [], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.added", "search_2", 1, 2),
        2
      )

    {:ok, state, [_done], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.done", "search_1", 0, 3),
        3
      )

    {:ok, state, [], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.done", "search_2", 1, 4),
        4
      )

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 5,
      "response" => %{
        "id" => "resp_http_limit",
        "object" => "response",
        "status" => "completed",
        "output" => [
          %{"id" => "search_1", "status" => "completed", "type" => "web_search_call"},
          %{"id" => "search_2", "status" => "completed", "type" => "web_search_call"}
        ]
      }
    }

    {:ok, _state, [completed], {:terminal, outcome, :keep_upstream}} =
      ResponseStreamState.observe(state, terminal, 5)

    assert %{
             "type" => "response.completed",
             "sequence_number" => 5,
             "response" => %{
               "id" => "resp_http_limit",
               "status" => "completed",
               "output" => [
                 %{"id" => "search_1", "status" => "completed", "type" => "web_search_call"}
               ]
             }
           } = completed

    assert outcome.public_items == [
             %{"id" => "search_1", "status" => "completed", "type" => "web_search_call"}
           ]
  end

  test "HTTP SSE provider terminal in the current chunk wins over local fallback" do
    state =
      ResponseStreamState.new(
        "agent-test",
        %{},
        %{"api_resolver" => "anthropic_messages"}
      )

    {:ok, state, [_added], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.added", "search_1", 0, 0),
        0
      )

    {:ok, state, [_added], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.added", "search_2", 1, 1),
        1
      )

    {:ok, state, [_done], :continue} =
      ResponseStreamState.observe(
        state,
        output_item_event("response.output_item.done", "search_1", 0, 2),
        2
      )

    {:ok, _state, [terminal], {:terminal, _outcome, :keep_upstream}} =
      ResponseStreamState.observe(
        state,
        %{
          "type" => "response.completed",
          "sequence_number" => 3,
          "response" => %{
            "id" => "resp_provider_won",
            "status" => "completed",
            "output" => []
          }
        },
        3
      )

    assert terminal["type"] == "response.completed"
  end

  test "responses endpoint rejects stateful fields on HTTP and SSE", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    for {field, request} <- [
          {"previous_response_id",
           %{"model" => "primary", "input" => "hello", "previous_response_id" => "resp_old"}},
          {"conversation",
           %{"model" => "primary", "input" => "hello", "conversation" => "conv_old"}},
          {"store", %{"model" => "primary", "input" => "hello", "store" => true}},
          {"previous_response_id",
           %{
             "model" => "primary",
             "input" => "hello",
             "stream" => true,
             "previous_response_id" => "resp_old"
           }}
        ] do
      conn =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{api_key.api_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/ai-gateway/responses", request)

      assert %{
               "error" => %{
                 "code" => "stateful_responses_require_websocket",
                 "message" => message
               }
             } =
               json_response(conn, 400)

      assert message =~ field
    end
  end

  test "native streaming route waits for upstream ready before sending SSE", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    server =
      start_supervised!(
        {Bandit,
         plug: {NativeResponsesUpstreamPlug, test_pid: self()},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-native-controller-sse",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
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
               provider_id: "openai-native-controller-sse",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => true
      })

    assert_receive {:native_controller_upstream_request, upstream_request}
    assert upstream_request["stream"] == true
    assert upstream_request["model"] == "gpt-5.5"

    assert response = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert response =~ "event: response.completed"
    assert response =~ "data: [DONE]"
    assert response =~ ~s("id":"resp_native_controller")
    assert_sse_event_names_match_body_types(response)
  end

  test "native streaming route returns ordinary JSON when upstream fails before ready", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600)

    server =
      start_supervised!(
        {Bandit,
         plug:
           {NativeResponsesUpstreamPlug,
            test_pid: self(), mode: :rate_limit, reset_at_unix: DateTime.to_unix(reset_at)},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-native-controller-pre-ready-error",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
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
               provider_id: "openai-native-controller-pre-ready-error",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => true
      })

    assert_receive {:native_controller_upstream_request, upstream_request}
    assert upstream_request["stream"] == true
    refute_receive {:native_controller_upstream_request, _retried_request}

    assert %{
             "error" => %{
               "type" => "usage_limit_reached",
               "code" => "credential_pool_exhausted",
               "message" => message,
               "resets_at" => resets_at,
               "details_json" => %{"retry_at" => retry_at}
             }
           } =
             json_response(conn, 429)

    assert resets_at == DateTime.to_unix(reset_at)
    assert {:ok, parsed_retry_at, _offset} = DateTime.from_iso8601(retry_at)
    assert DateTime.compare(parsed_retry_at, reset_at) == :eq
    assert message =~ "All credentials in this provider pool are unavailable."
    assert get_resp_header(conn, "x-codex-primary-reset-at") == [Integer.to_string(resets_at)]
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds in 0..600
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    refute response(conn, 429) =~ "data: [DONE]"
  end

  test "a provider error before close yields only the canonical Responses terminal", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    server =
      start_supervised!(
        {Bandit,
         plug: {NativeResponsesUpstreamPlug, test_pid: self(), mode: :error_then_close},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-sse-error",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
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
               provider_id: "openai-sse-error",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => true
      })

    response = response(conn, 200)
    assert_sse_event_names_match_body_types(response)
    assert_receive {:native_controller_upstream_request, upstream_request}
    assert upstream_request["stream"] == true

    events = decode_sse_events(response)
    refute Enum.any?(events, &(&1["type"] == "error"))
    assert Enum.count(events, &(&1["type"] == "response.failed")) == 1

    refute response =~ "event: error"
    assert response =~ "data: [DONE]"
  end

  test "responses endpoint returns JSON when stream is absent or false", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_json",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-json-main",
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
               provider_id: "openai-json-main",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => false
      })

    assert body = json_response(conn, 200)
    assert body["id"] == "resp_json"
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    refute response(conn, 200) =~ "data: [DONE]"

    assert_receive {:gateway_request, request}
    assert request.path == "v1/responses"
    assert request.body["stream"] == false
    assert request.body["store"] == false
  end

  test "responses endpoint covers upstream OpenResponses stateless HTTP templates" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn request ->
        {:json, 200, chat_completion_fixture(request.body)}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-openresponses-compliance",
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
               provider_id: "openrouter-openresponses-compliance",
               model: "openai/gpt-5.5"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    for {id, request, validator} <- stateless_openresponses_templates() do
      conn =
        api_key.api_key
        |> gateway_conn()
        |> post(~p"/api/v1/ai-gateway/responses", request)

      body = json_response(conn, 200)
      assert_openresponses_response_resource(body)
      assert body["status"] == "completed"
      assert body["model"] == "openai/gpt-5.5"
      assert length(body["output"]) > 0

      assert_receive {:gateway_request, upstream_request}
      assert upstream_request.path == "chat/completions"
      assert upstream_request.body["model"] == "openai/gpt-5.5"
      refute Map.has_key?(upstream_request.body, "previous_response_id")

      validator.(id, body, upstream_request)
    end
  end

  test "responses path upgrades raw WebSocket requests with an agent token", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      %{
        conn
        | host: "www.example.com",
          req_headers: [{"host", "www.example.com"} | conn.req_headers]
      }
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("connection", "Upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")
      |> get(~p"/api/v1/ai-gateway/responses")

    assert conn.state == :upgraded

    assert_receive {_ref, :upgrade,
                    {:websocket,
                     {AnkoleWeb.AIGatewayResponsesSocket,
                      %{subject_uid: subject_uid, subject_type: subject_type}, opts}}}

    assert subject_uid == agent.uid
    assert subject_type == "agent"
    assert opts[:timeout] == 300_000
  end

  test "responses WebSocket freezes the decoded Codex binding in connection state", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{"reasoningEffort" => "xhigh"},
        "supports_parallel_tool_calls" => true,
        "input_modalities" => ["text"]
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    conn =
      %{
        conn
        | host: "www.example.com",
          req_headers: [{"host", "www.example.com"} | conn.req_headers]
      }
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("x-ankole-aigateway-model-binding", encoded)
      |> put_req_header("connection", "Upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")
      |> get(~p"/api/v1/ai-gateway/responses")

    assert conn.state == :upgraded

    assert_receive {_ref, :upgrade,
                    {:websocket,
                     {AnkoleWeb.AIGatewayResponsesSocket,
                      %{
                        subject_uid: subject_uid,
                        subject_type: "agent",
                        codex_model_binding: binding
                      }, _opts}}}

    assert subject_uid == agent.uid

    assert binding == %{
             "selector" => "openrouter/openai/gpt-5.6-sol",
             "provider_options" => %{"reasoningEffort" => "xhigh"},
             "supports_parallel_tool_calls" => true,
             "input_modalities" => ["text"]
           }
  end

  test "response output phase fixture from upstream compliance remains schema-compatible" do
    body = %{
      "id" => "resp_phase_schema",
      "object" => "response",
      "created_at" => 1_764_967_971,
      "completed_at" => 1_764_967_972,
      "status" => "completed",
      "incomplete_details" => nil,
      "model" => "test-model",
      "previous_response_id" => nil,
      "instructions" => nil,
      "output" => [
        %{
          "id" => "msg_phase_commentary",
          "type" => "message",
          "status" => "completed",
          "role" => "assistant",
          "phase" => "commentary",
          "content" => [
            %{"type" => "output_text", "text" => "I am checking the answer.", "annotations" => []}
          ]
        },
        %{
          "id" => "msg_phase_final",
          "type" => "message",
          "status" => "completed",
          "role" => "assistant",
          "phase" => "final_answer",
          "content" => [
            %{"type" => "output_text", "text" => "The answer is four.", "annotations" => []}
          ]
        }
      ],
      "error" => nil,
      "tools" => [],
      "tool_choice" => "auto",
      "truncation" => "disabled",
      "parallel_tool_calls" => true,
      "text" => %{"format" => %{"type" => "text"}},
      "top_p" => 1,
      "presence_penalty" => 0,
      "frequency_penalty" => 0,
      "top_logprobs" => 0,
      "temperature" => 1,
      "reasoning" => %{"effort" => nil, "summary" => nil},
      "user" => nil,
      "usage" => response_usage_fixture(),
      "provider_metadata" => %{},
      "tool_results" => [],
      "stop_reason" => nil,
      "max_output_tokens" => nil,
      "max_tool_calls" => nil,
      "store" => true,
      "background" => false,
      "service_tier" => nil,
      "metadata" => %{},
      "safety_identifier" => nil,
      "prompt_cache_key" => nil,
      "input" => [],
      "next_response_ids" => [],
      "context_edits" => [],
      "prompt_cache_retention" => nil,
      "conversation" => nil
    }

    assert_openresponses_response_resource(body)
    assert Enum.any?(body["output"], &(&1["phase"] == "commentary"))
    assert Enum.any?(body["output"], &(&1["phase"] == "final_answer"))
  end

  test "compact endpoint covers OpenResponses standalone compact compliance", %{conn: _conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        cond do
          request.path == "models" ->
            {:json, 200, openrouter_models_fixture()}

          request.body["stream"] == true ->
            {:sse, 200,
             chat_completion_stream_events(
               request,
               "## Active Task\nhello from compliance"
             )}

          true ->
            {:json, 200, compact_chat_completion_fixture(request.body)}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-standalone-compact",
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
               provider_id: "openrouter-standalone-compact",
               model: "openai/gpt-5.5",
               context_length: 131_072
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "prompt_cache_key" => "openresponses-compact-test",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "We agreed to launch on Tuesday and notify support first."
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => "Understood. The launch is Tuesday, with support notified beforehand."
          }
        ]
      })

    assert {:ok, body, _events} = conn

    # The trigger's reply carries the compaction item and nothing else: the
    # caller rebuilds its own retained history around it.
    assert %{
             "object" => "response",
             "status" => "completed",
             "output" => [
               %{
                 "id" => "cmp_" <> artifact_id,
                 "type" => "compaction",
                 "encrypted_content" => encrypted_content,
                 "created_by" => "ankole-aigateway"
               }
             ],
             "usage" => %{
               "input_tokens" => 5,
               "output_tokens" => 7,
               "total_tokens" => 12,
               "input_tokens_details" => %{"cached_tokens" => 0},
               "output_tokens_details" => %{"reasoning_tokens" => 0}
             }
           } = body

    assert encrypted_content == "ankole:compact:v1:cmp_#{artifact_id}"

    assert %CompactionArtifact{content: artifact_content} =
             Repo.get!(CompactionArtifact, artifact_id)

    assert artifact_content["summary"] == %{"text" => "## Active Task\nhello from compliance"}

    assert_receive {:gateway_request, metadata_request}
    assert metadata_request.path == "models"

    assert_receive {:gateway_request, upstream_request}
    assert upstream_request.path == "chat/completions"
    assert upstream_request.body["model"] == "openai/gpt-5.5"
    refute Map.has_key?(upstream_request.body, "previous_response_id")
    refute Map.has_key?(upstream_request.body, "conversation")

    assert Repo.all(Message) == []

    continuation_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" =>
          body["output"] ++
            [
              %{
                "type" => "message",
                "role" => "user",
                "content" => "continue from the compacted state"
              }
            ]
      })

    assert json_response(continuation_conn, 200)

    assert_receive {:gateway_request, continuation_request}
    assert continuation_request.path == "chat/completions"
    assert inspect(continuation_request.body) =~ "Context checkpoint:"
    assert inspect(continuation_request.body) =~ "## Active Task\\nhello from compliance"
  end

  test "compact endpoint reports no candidate for history that is only opaque provider state",
       %{
         conn: _conn
       } do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "opaque-compact-fallback",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "opaque-compact-fallback",
               model: "gpt-test"
             })

    assert {:ok, _api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "input" => [
          %{"type" => "compaction", "encrypted_content" => "provider-opaque-state"}
        ]
      })

    assert {:error, 400, "no_compaction_candidate"} = conn
  end

  test "compact endpoint compacts only items after the previous compaction item", %{conn: _conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        cond do
          request.path == "models" ->
            {:json, 200, openrouter_models_fixture()}

          inspect(request.body) =~ "second round follow-up" ->
            {:sse, 200, chat_completion_stream_events(request, "## Active Task\nsecond summary")}

          true ->
            {:sse, 200, chat_completion_stream_events(request, "## Active Task\nfirst summary")}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-compact-boundary",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-compact-boundary",
               model: "openai/gpt-5.5",
               context_length: 131_072
             })

    assert {:ok, _api_key} = Tokens.mint_for_agent(agent.uid)

    first_conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "original kickoff request"},
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => "original assistant answer"
          }
        ]
      })

    assert {:ok, first_body, _first_events} = first_conn
    first_summarizer = receive_summarizer_request()
    assert summarizer_user_prompt(first_summarizer.body) =~ "original kickoff request"

    second_conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "input" =>
          first_body["output"] ++
            [
              %{"type" => "message", "role" => "user", "content" => "second round follow-up"},
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => "second round assistant answer"
              },
              %{"type" => "message", "role" => "user", "content" => "latest user question"}
            ]
      })

    assert {:ok, second_body, _second_events} = second_conn
    second_summarizer = receive_summarizer_request()
    second_prompt = summarizer_user_prompt(second_summarizer.body)

    assert second_prompt =~ "second round follow-up"
    assert second_prompt =~ "second round assistant answer"
    assert second_prompt =~ "latest user question"
    refute second_prompt =~ "original kickoff request"
    refute second_prompt =~ "ankole:compact:v1:"

    assert second_prompt =~
             "<previous_chat_history>\n## Active Task\nfirst summary\n</previous_chat_history>"

    assert [%{"type" => "compaction", "id" => "cmp_" <> second_artifact_id}] =
             second_body["output"]

    assert Repo.get!(CompactionArtifact, second_artifact_id).content["summary"] ==
             %{"text" => "## Active Task\nsecond summary"}
  end

  test "compact endpoint rejects input with no items after the last compaction item", %{
    conn: _conn
  } do
    %{principal: agent} = agent_fixture()
    assert {:ok, _api_key} = Tokens.mint_for_agent(agent.uid)

    assert {:ok, artifact} =
             CompactionArtifacts.insert_artifact(%{
               subject_uid: agent.uid,
               summary_text: "Prior work is complete.",
               retained_items: [],
               retained_user_originals: [],
               retention: %{},
               usage: %{}
             })

    conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "input" => [CompactionArtifacts.compaction_item(artifact.id)]
      })

    assert {:error, 400, "no_compaction_candidate"} = conn
  end

  test "compact endpoint rejects standalone compact without model", %{conn: _conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, _api_key} = Tokens.mint_for_agent(agent.uid)

    conn =
      compaction_trigger(agent.uid, %{
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "compact this"
          }
        ]
      })

    assert {:error, 400, "missing_model"} = conn
  end

  test "compact endpoint stores artifact and checkpoint when store is true", %{conn: _conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, _api_key} = Tokens.mint_for_agent(agent.uid)

    base_url =
      start_recording_upstream(self(), fn request ->
        if request.path == "models" do
          {:json, 200, openrouter_models_fixture()}
        else
          {:sse, 200,
           chat_completion_stream_events(request, "## Active Task\nhello from compliance")}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-stateful-compact",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-stateful-compact",
               model: "openai/gpt-5.5",
               context_length: 131_072
             })

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "compact-response-controller")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "id" => "msg_compact_input",
            "type" => "message",
            "status" => "completed",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "long prior context"}]
          }
        ],
        metadata: %{"model" => "gpt-test"}
      })

    assert {:ok, anchor} =
             StatefulResponses.commit_complete(
               anchor,
               [
                 %{
                   "id" => "msg_compact_output",
                   "type" => "message",
                   "status" => "completed",
                   "role" => "assistant",
                   "content" => [
                     %{"type" => "output_text", "text" => "prior answer", "annotations" => []}
                   ]
                 }
               ],
               %{"usage" => response_usage_fixture()}
             )

    # Without store=true the anchor names this connection's own history, and
    # this connection never issued that ID.
    unknown_anchor_conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "previous_response_id" => anchor.id,
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "unknown anchor should fail"}
        ]
      })

    assert {:error, 400, "previous_response_not_found"} = unknown_anchor_conn

    conn =
      compaction_trigger(agent.uid, %{
        "model" => "primary",
        "store" => true,
        "previous_response_id" => "resp_#{anchor.id}",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Prior context says the answer was prior answer."
          }
        ],
        "metadata" => %{"visible" => "compact"}
      })

    assert {:ok, body, _events} = conn
    assert body["object"] == "response"
    assert body["status"] == "completed"

    [compaction_item] = body["output"]
    assert compaction_item["type"] == "compaction"
    assert "cmp_" <> artifact_id = compaction_item["id"]
    assert compaction_item["encrypted_content"] == "ankole:compact:v1:cmp_#{artifact_id}"

    # A stored compaction answers with the checkpoint id, so the caller's next
    # turn continues from it without a second lookup.
    assert body["id"] == "resp_#{artifact_id}"

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, artifact_id)
    assert artifact.id == artifact_id
    assert artifact.conversation_id == conversation.id
    assert artifact.content["summary"] == %{"text" => "## Active Task\nhello from compliance"}

    assert %Message{} = row = Repo.get!(Message, artifact_id)
    assert row.type == "checkpoint"
    assert row.status == "complete"
    assert row.previous_message_id == anchor.id
    assert row.content == [%{"id" => "cmp_#{artifact_id}", "type" => "compaction_artifact"}]
    # A checkpoint keeps Provider items verbatim, so it records its issuer like
    # every other stored message. Without it a later Turn on another Provider
    # would replay state that Provider cannot read.
    assert row.metadata == %{
             "request_metadata" => %{"visible" => "compact"},
             "issuer" => "openrouter-stateful-compact"
           }

    assert StatefulResponses.expand_history(conversation.id,
             previous_response_id: body["id"]
           ) ==
             [
               row
             ]
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
  end

  defp output_item_event(type, id, output_index, sequence_number) do
    %{
      "type" => type,
      "sequence_number" => sequence_number,
      "output_index" => output_index,
      "item" => %{
        "id" => id,
        "type" => "web_search_call",
        "status" => if(type == "response.output_item.done", do: "completed", else: "in_progress")
      }
    }
  end

  defp receive_summarizer_request do
    assert_receive {:gateway_request, request}

    if request.path == "models" do
      receive_summarizer_request()
    else
      request
    end
  end

  defp summarizer_user_prompt(body) do
    body
    |> Map.get("messages")
    |> List.wrap()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} when is_binary(content) ->
        content

      %{"role" => "user", "content" => parts} when is_list(parts) ->
        parts
        |> Enum.map(fn
          %{"text" => text} when is_binary(text) -> text
          _part -> ""
        end)
        |> Enum.join("\n")

      _message ->
        nil
    end)
  end

  test "every transport answers the same compaction trigger" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        # The trigger is answered here, so it must never reach a Provider.
        input = request.body["input"]

        if is_list(input) do
          refute Enum.any?(input, &(is_map(&1) and Map.get(&1, "type") == "compaction_trigger"))
        end

        {:sse, 200,
         response_sse_events(
           "resp_transport_summary",
           "gpt-main",
           "## Active Task\nTransport summary"
         )}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-transport-trigger",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-transport-trigger",
               model: "gpt-main"
             })

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)

    trigger_input = [
      %{"type" => "message", "role" => "user", "content" => "first"},
      %{"type" => "message", "role" => "assistant", "content" => "second"},
      %{"type" => "compaction_trigger"}
    ]

    json_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses", %{"model" => "primary", "input" => trigger_input})

    assert %{"object" => "response", "output" => [%{"type" => "compaction"}]} =
             json_response(json_conn, 200)

    sse_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "stream" => true,
        "input" => trigger_input
      })

    assert get_resp_header(sse_conn, "content-type") == ["text/event-stream"]
    body = response(sse_conn, 200)

    assert body =~ "event: response.created"
    assert body =~ "event: response.output_item.done"
    assert body =~ "event: response.completed"
    assert body =~ "\"type\":\"compaction\""
    assert body =~ "data: [DONE]"

    # The socket renders the same reply as frames; this is the third transport.
    assert {:ok, socket_body, _events} =
             compaction_trigger(agent.uid, %{
               "model" => "primary",
               "input" => Enum.drop(trigger_input, -1)
             })

    assert [%{"type" => "compaction"}] = socket_body["output"]
  end

  # These cases drive the Responses socket, because that is what the Main Agent
  # and Codex use. One case above proves every transport answers the same way.
  defp compaction_trigger(agent_uid, body) do
    input =
      case Map.get(body, "input", []) do
        input when is_list(input) ->
          input

        input when is_binary(input) ->
          [%{"type" => "message", "role" => "user", "content" => input}]
      end

    request =
      body
      |> Map.merge(%{
        "type" => "response.create",
        "input" => input ++ [%{"type" => "compaction_trigger"}]
      })
      |> Ankole.JSON.encode!()

    result =
      AnkoleWeb.AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
        subject_uid: agent_uid,
        subject_type: "agent"
      })

    case result do
      {:push, {:text, chunk}, _state} ->
        compaction_trigger_result([Ankole.JSON.decode!(chunk)])

      {:push, chunks, _state} ->
        compaction_trigger_result(
          Enum.map(chunks, fn {:text, chunk} -> Ankole.JSON.decode!(chunk) end)
        )
    end
  end

  defp compaction_trigger_result(events) do
    case Enum.find(events, &(&1["type"] == "error")) do
      nil -> {:ok, Enum.find(events, &(&1["type"] == "response.completed"))["response"], events}
      error -> {:error, error["status"], error["error"]["code"]}
    end
  end
end
