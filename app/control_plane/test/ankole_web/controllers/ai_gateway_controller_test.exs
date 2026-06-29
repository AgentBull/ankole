defmodule AnkoleWeb.AIGatewayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import AnkoleWeb.AIGatewayControllerTestHelpers

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias AnkoleWeb.AIGatewayTokens

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
               provider_id: "openrouter-models",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-models",
               model: "openai/gpt-5.5"
             })

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key.api_key}")
      |> get(~p"/api/v1/ai-gateway/models", %{"supported_parameters" => "tools"})

    assert %{"data" => models} = json_response(conn, 200)
    assert primary = Enum.find(models, &(&1["id"] == "primary"))
    assert explicit = Enum.find(models, &(&1["id"] == "openrouter-models/openai/gpt-5.5"))

    assert primary["canonical_slug"] == explicit["id"]
    assert get_in(primary, ["architecture", "output_modalities"]) == ["text"]
    assert "tools" in primary["supported_parameters"]
    assert Map.has_key?(primary, "pricing")
    assert Map.has_key?(primary, "top_provider")
  end

  test "models endpoint includes non-LLM selectors by default", %{conn: conn} do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-models-all-capabilities",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-models-all-capabilities",
               model: "openai/gpt-5.4-nano"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "openrouter-models-all-capabilities",
               model: "perplexity/pplx-embed-v1-0.6b"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "rerank", %{
               provider_id: "openrouter-models-all-capabilities",
               model: "cohere/rerank-4-fast"
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

  test "admin console JWT can access AIGateway with explicit provider model selectors", %{
    conn: conn
  } do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-admin-access",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    Application.put_env(:ankole, Ankole.AIGateway,
      http_client: fn request ->
        assert request.url == "https://openrouter.ai/api/v1/chat/completions"
        assert request.body["model"] == "openai/gpt-5.5"
        {:ok, %{status: 200, body: chat_completion_fixture(request.body)}}
      end
    )

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
  end

  test "responses endpoint supports v1 SSE with an agent AIGateway token", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-sse-main",
               provider_kind: "openai",
               credential: "sk-openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-sse-main",
               model: "gpt-5.5"
             })

    Application.put_env(:ankole, Ankole.AIGateway,
      http_stream_client: fn request, state, handler ->
        assert request.url == "https://api.openai.test/v1/responses"
        assert request.body["stream"] == true
        refute Map.has_key?(request.body, "previous_response_id")

        response_sse_events("resp_sse", "gpt-5.5", "hello from sse")
        |> Enum.reduce_while({:ok, state}, fn event, {:ok, state} ->
          case handler.(sse_data(event), state) do
            {:cont, state} -> {:cont, {:ok, state}}
            {:halt, {:error, reason}} -> {:halt, {:error, reason}}
          end
        end)
      end
    )

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

    assert %{"type" => "response.completed", "response" => body} = List.last(events)
    assert_openresponses_response_resource(body)
    assert body["previous_response_id"] == nil
  end

  test "streaming responses errors stay parseable by the Responses client", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-sse-error",
               provider_kind: "openai",
               credential: "sk-openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-sse-error",
               model: "gpt-5.5"
             })

    Application.put_env(:ankole, Ankole.AIGateway,
      http_stream_client: fn request, _state, _handler ->
        assert request.url == "https://api.openai.test/v1/responses"
        assert request.body["stream"] == true

        {:error,
         {:upstream_response_failed, 429,
          %{"error" => %{"message" => "chaos transient upstream 429"}}}}
      end
    )

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

    assert [
             %{
               "type" => "error",
               "status" => 429,
               "sequence_number" => 0,
               "error" => %{
                 "code" => "upstream_response_failed",
                 "type" => "rate_limit_error",
                 "message" => "chaos transient upstream 429"
               }
             }
           ] = decode_sse_events(response)

    assert response =~ "event: error"
    assert response =~ "data: [DONE]"
  end

  test "responses endpoint returns JSON when stream is absent or false", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-json-main",
               provider_kind: "openai",
               credential: "sk-openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-json-main",
               model: "gpt-5.5"
             })

    Application.put_env(:ankole, Ankole.AIGateway,
      http_client: fn request ->
        assert request.body["stream"] == false

        {:ok,
         %{
           status: 200,
           body: %{
             "id" => "resp_json",
             "object" => "response",
             "status" => "completed",
             "output" => [],
             "usage" => %{}
           }
         }}
      end
    )

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
  end

  test "responses endpoint covers upstream OpenResponses stateless HTTP templates" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-openresponses-compliance",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-openresponses-compliance",
               model: "openai/gpt-5.5"
             })

    test_pid = self()

    Application.put_env(:ankole, Ankole.AIGateway,
      http_client: fn request ->
        send(test_pid, {:gateway_request, request})
        {:ok, %{status: 200, body: chat_completion_fixture(request.body)}}
      end
    )

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
      assert upstream_request.url == "https://openrouter.ai/api/v1/chat/completions"
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
end
