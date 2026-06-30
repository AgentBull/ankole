defmodule AnkoleWeb.AIGatewayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import AnkoleWeb.AIGatewayControllerTestHelpers

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
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
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "hello",
        "previous_response_id" => "resp_old",
        "stream" => true
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
    refute Map.has_key?(request.body, "previous_response_id")

    assert %{"type" => "response.completed", "response" => body} = List.last(events)
    assert_openresponses_response_resource(body)
    assert body["previous_response_id"] == nil
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
      "max_output_tokens" => nil,
      "max_tool_calls" => nil,
      "store" => true,
      "background" => false,
      "service_tier" => "default",
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

  test "stateful compact endpoint is explicitly outside AIGateway v1", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/ai-gateway/responses/compact", %{
        "model" => "primary",
        "input" => [%{"type" => "message", "role" => "user", "content" => "compact this"}]
      })

    assert response(conn, 404)
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
  end
end
