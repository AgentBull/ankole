defmodule AnkoleWeb.AIGatewayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import AnkoleWeb.AIGatewayControllerTestHelpers

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias AnkoleWeb.AIGatewayTokens

  defmodule NativeResponsesUpstreamPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "POST", request_path: "/v1/responses"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Ankole.JSON.decode!(body)
      send(opts[:test_pid], {:native_controller_upstream_request, request})

      case opts[:mode] do
        :malformed ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, "data: {bad json\n\n")
          conn

        :rate_limit ->
          conn
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

  test "responses retrieve returns an agent-scoped stored response resource", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
      StatefulResponses.ensure_conversation(agent.uid, "retrieve-response-controller")

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [input_item],
        metadata: %{"model" => "gpt-test", "visible" => "yes"}
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
        agent_uid: agent.uid,
        previous_response_id: "resp_#{first.id}",
        request_items: [second_input_item],
        metadata: %{"model" => "gpt-test", "visible" => "yes"}
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
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    input_item = %{"role" => "user", "content" => "Hello"}

    output_item = %{
      "id" => "msg_retrieve_role_only_output",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Hi", "annotations" => []}]
    }

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "retrieve-role-only-input")

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
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
    assert {:ok, intruder_key} = AIGatewayTokens.mint_for_agent(intruder.uid)

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(owner.uid, "retrieve-response-cross-agent")

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        agent_uid: owner.uid,
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
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "retrieve-response-not-terminal")

    {:ok, generating} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
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
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)
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
               connection_options: %{
                 "api_key" => "sk-openai"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

  test "models endpoint includes non-LLM selectors by default", %{conn: conn} do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-models-all-capabilities",
               provider_kind: "openai",
               connection_options: %{
                 "api_key" => "sk-openai"
               }
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-models-all-capabilities",
               provider_kind: "jina",
               connection_options: %{
                 "api_key" => "jina-key"
               }
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models-all-capabilities",
               model: "gpt-4o-mini"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "jina-models-all-capabilities",
               model: "jina-embeddings-v3"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "rerank", %{
               provider_id: "jina-models-all-capabilities",
               model: "jina-reranker-v2-base-multilingual"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models")

    assert %{"data" => models} = json_response(conn, 200)
    selectors = MapSet.new(models, & &1["id"])

    assert MapSet.member?(selectors, "primary")
    assert MapSet.member?(selectors, "embedding.default")
    assert MapSet.member?(selectors, "rerank.default")
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
               connection_options: %{"api_key" => "parallel-key"}
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

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/web_tools")

    assert %{
             "web_search" => %{"available" => true, "model" => "web_search.default"},
             "web_fetch" => %{"available" => true, "model" => "web_fetch.default"}
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle()
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

  test "web_fetch rejects non-public URLs before provider dispatch", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-private-url",
               provider_kind: "parallel",
               connection_options: %{"api_key" => "parallel-key"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "parallel-web-private-url",
               model: "default"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> post(~p"/api/v1/ai-gateway/web_fetch", %{
        "model" => "web_fetch.default",
        "urls" => ["https://127.0.0.1/private"]
      })

    assert %{"error" => %{"code" => "invalid_urls"}} = json_response(conn, 400)
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
               connection_options: %{"api_key" => "jina-key"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "jina-search-web-main",
               model: "default",
               provider_options: %{"gl" => "us", "hl" => "en"}
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

  test "web_search validates query and limit before provider dispatch", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-web-invalid-request",
               provider_kind: "parallel",
               connection_options: %{"api_key" => "parallel-key"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "parallel-web-invalid-request",
               model: "default"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
                 connection_options: %{"api_key" => "sk-openai"}
               })
    end

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-models-duplicate-a",
               model: "gpt-4o-mini"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
               connection_options: %{
                 "api_key" => "sk-openrouter",
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
               provider_id: "openai-sse-main",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "stream" => true,
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
    assert request.body["stream_options"] == %{"include_usage" => true}
    assert request.body["store"] == false
    refute Map.has_key?(request.body, "service_tier")

    assert %{"type" => "response.completed", "response" => body} = List.last(events)
    assert_openresponses_response_resource(body)
    assert body["previous_response_id"] == nil
  end

  test "responses endpoint rejects stateful fields on HTTP and SSE", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
               provider_id: "openai-native-controller-sse",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

    server =
      start_supervised!(
        {Bandit,
         plug: {NativeResponsesUpstreamPlug, test_pid: self(), mode: :rate_limit},
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
               provider_id: "openai-native-controller-pre-ready-error",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

    assert %{"error" => %{"code" => "upstream_response_failed", "message" => message}} =
             json_response(conn, 429)

    assert message == "native upstream rate limit"
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    refute response(conn, 429) =~ "data: [DONE]"
  end

  test "streaming responses errors stay parseable by the Responses client", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    server =
      start_supervised!(
        {Bandit,
         plug: {NativeResponsesUpstreamPlug, test_pid: self(), mode: :malformed},
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
               provider_id: "openai-sse-error",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

    assert Enum.any?(decode_sse_events(response), &(&1["type"] == "error"))
    assert Enum.any?(decode_sse_events(response), &(&1["type"] == "response.failed"))

    assert response =~ "event: error"
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
               provider_id: "openai-json-main",
               model: "gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
               provider_id: "openrouter-openresponses-compliance",
               model: "openai/gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

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

  test "compact endpoint covers OpenResponses standalone compact compliance", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        if request.path == "models" do
          {:json, 200, openrouter_models_fixture()}
        else
          {:json, 200, compact_chat_completion_fixture(request.body)}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-standalone-compact",
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
               provider_id: "openrouter-standalone-compact",
               model: "openai/gpt-5.5",
               context_length: 131_072
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses/compact", %{
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

    body = json_response(conn, 200)

    assert %{
             "id" => "compact_" <> _,
             "object" => "response.compaction",
             "created_at" => created_at,
             "output" => [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => "We agreed to launch on Tuesday and notify support first."
               },
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

    assert is_integer(created_at)
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

  test "compact endpoint rejects standalone compact without model", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses/compact", %{
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "compact this"
          }
        ]
      })

    assert %{"error" => %{"code" => "missing_model"}} = json_response(conn, 400)
  end

  test "compact endpoint stores artifact and checkpoint when store is true", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    base_url =
      start_recording_upstream(self(), fn request ->
        if request.path == "models" do
          {:json, 200, openrouter_models_fixture()}
        else
          {:json, 200, compact_chat_completion_fixture(request.body)}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-stateful-compact",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{"api_key" => "sk-openrouter"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-stateful-compact",
               model: "openai/gpt-5.5",
               context_length: 131_072
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "compact-response-controller")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
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

    raw_anchor_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses/compact", %{
        "model" => "primary",
        "previous_response_id" => anchor.id,
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "raw id should fail"}
        ]
      })

    assert %{"error" => %{"code" => "invalid_previous_response_id"}} =
             json_response(raw_anchor_conn, 400)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses/compact", %{
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

    body = json_response(conn, 200)
    assert body["object"] == "response.compaction"
    assert body["ankole"]["stored"] == true
    assert body["ankole"]["conversation"] == "conv_#{conversation.id}"

    [user_original, compaction_item] = body["output"]
    assert user_original["role"] == "user"
    assert compaction_item["type"] == "compaction"
    assert "cmp_" <> artifact_id = compaction_item["id"]
    assert compaction_item["encrypted_content"] == "ankole:compact:v1:cmp_#{artifact_id}"
    assert body["ankole"]["response_id"] == "resp_#{artifact_id}"

    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, artifact_id)
    assert artifact.id == artifact_id
    assert artifact.conversation_id == conversation.id
    assert artifact.content["summary"] == %{"text" => "## Active Task\nhello from compliance"}

    assert %Message{} = row = Repo.get!(Message, artifact_id)
    assert row.type == "checkpoint"
    assert row.status == "complete"
    assert row.previous_message_id == anchor.id
    assert row.content == [%{"id" => "cmp_#{artifact_id}", "type" => "compaction_artifact"}]
    assert row.metadata == %{"visible" => "compact"}

    assert StatefulResponses.expand_history(conversation.id,
             previous_response_id: body["ankole"]["response_id"]
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
end
