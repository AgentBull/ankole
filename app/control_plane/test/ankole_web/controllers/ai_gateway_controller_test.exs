defmodule AnkoleWeb.AIGatewayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias AnkoleWeb.AIGatewayTokens
  alias AnkoleWeb.ConsoleTokens

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
    assert MapSet.member?(selectors, "embedding")
    assert MapSet.member?(selectors, "rerank")
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

  defp stateless_openresponses_templates do
    noop = fn _id, _body, _request -> :ok end

    [
      {"basic-response",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "user", "content" => "Say hello in exactly 3 words."}
         ]
       }, noop},
      {"assistant-phase",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "assistant",
             "phase" => "commentary",
             "content" => "I should answer with the saved number."
           },
           %{
             "type" => "message",
             "role" => "assistant",
             "phase" => "final_answer",
             "content" => "The number is four."
           },
           %{"type" => "message", "role" => "user", "content" => "Repeat only the number."}
         ]
       }, noop},
      {"system-prompt",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "system", "content" => "You are a pirate."},
           %{"type" => "message", "role" => "user", "content" => "Say hello."}
         ]
       },
       fn _id, _body, request ->
         assert [%{"role" => "system"} | _rest] = request.body["messages"]
       end},
      {"tool-calling",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "user",
             "content" => "What's the weather like in San Francisco?"
           }
         ],
         "tools" => [
           %{
             "type" => "function",
             "name" => "get_weather",
             "description" => "Get the current weather for a location",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"location" => %{"type" => "string"}},
               "required" => ["location"]
             }
           }
         ]
       },
       fn _id, body, request ->
         assert Enum.any?(body["output"], &(&1["type"] == "function_call"))

         assert [%{"strict" => nil, "description" => "Get the current weather for a location"}] =
                  body["tools"]

         assert [%{"type" => "function", "name" => "get_weather"}] = request.body["tools"]
       end},
      {"image-input",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "What do you see in this image?"},
               %{"type" => "input_image", "image_url" => "data:image/png;base64,iVBORw0KGgo="}
             ]
           }
         ]
       }, noop},
      {"multi-turn",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "user", "content" => "My name is Alice."},
           %{"type" => "message", "role" => "assistant", "content" => "Hello Alice!"},
           %{"type" => "message", "role" => "user", "content" => "What is my name?"}
         ]
       }, noop}
    ]
  end

  defp chat_completion_fixture(body) do
    message =
      case Map.get(body, "tools") do
        tools when is_list(tools) and tools != [] ->
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_weather",
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => ~s({"location":"San Francisco, CA"})
                }
              }
            ]
          }

        _tools ->
          %{"role" => "assistant", "content" => "hello from compliance"}
      end

    %{
      "id" => "chatcmpl_#{System.unique_integer([:positive])}",
      "object" => "chat.completion",
      "created" => 1_764_967_971,
      "model" => body["model"],
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
    }
  end

  defp response_sse_events(response_id, model, text) do
    response =
      %{
        "id" => response_id,
        "object" => "response",
        "created_at" => 1_764_967_971,
        "completed_at" => nil,
        "status" => "in_progress",
        "model" => model,
        "previous_response_id" => nil,
        "output" => [],
        "usage" => %{}
      }

    item = %{
      "id" => "msg_sse",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    [
      %{"type" => "response.created", "sequence_number" => 0, "response" => response},
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{item | "status" => "in_progress", "content" => []}
      },
      %{
        "type" => "response.content_part.added",
        "sequence_number" => 2,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
      },
      %{
        "type" => "response.output_text.delta",
        "sequence_number" => 3,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      },
      %{
        "type" => "response.output_text.done",
        "sequence_number" => 4,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "text" => text
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => 5,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "part" => List.first(item["content"])
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 6,
        "output_index" => 0,
        "item" => item
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 7,
        "response" => %{
          response
          | "completed_at" => 1_764_967_972,
            "status" => "completed",
            "output" => [item]
        }
      }
    ]
  end

  defp sse_data(event), do: "data: #{Ankole.JSON.encode!(event)}\n\n"

  defp gateway_conn(api_key) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> put_req_header("content-type", "application/json")
  end

  defp admin_access_token do
    human = human_fixture(%{uid: unique_uid("ai-gateway-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    assert {:ok, token_set} =
             ConsoleTokens.mint_for_session(%{
               "principal_uid" => human.principal.uid,
               "provider_id" => "lark-main",
               "external_id" => "external-1",
               "issued_at" => System.system_time(:second),
               "expires_at" => System.system_time(:second) + 3_600
             })

    token_set.access_token
  end

  defp decode_sse_events(response) do
    response
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn chunk ->
      chunk
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: [DONE]" -> :done
        "data: " <> data -> data
        _line -> nil
      end)
      |> case do
        :done -> []
        data when is_binary(data) -> [Ankole.JSON.decode!(data)]
        _value -> []
      end
    end)
  end

  defp assert_sse_event_names_match_body_types(response) do
    response
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&(&1 == "data: [DONE]"))
    |> Enum.each(fn chunk ->
      lines = String.split(chunk, "\n")
      event_name = sse_field(lines, "event")
      data = sse_field(lines, "data")

      assert is_binary(event_name), "missing SSE event field in #{inspect(chunk)}"
      assert is_binary(data), "missing SSE data field in #{inspect(chunk)}"

      assert %{"type" => ^event_name} = Ankole.JSON.decode!(data)
    end)
  end

  defp sse_field(lines, field) do
    Enum.find_value(lines, fn
      line ->
        case String.split(line, ":", parts: 2) do
          [^field, value] -> String.trim_leading(value)
          _other -> nil
        end
    end)
  end

  defp assert_openresponses_response_resource(body) do
    required_keys = ~w(
      id object created_at completed_at status incomplete_details model previous_response_id
      instructions output error tools tool_choice truncation parallel_tool_calls text top_p
      presence_penalty frequency_penalty top_logprobs temperature reasoning usage
      max_output_tokens max_tool_calls store background service_tier metadata safety_identifier
      prompt_cache_key user
    )

    Enum.each(required_keys, fn key ->
      assert Map.has_key?(body, key), "missing OpenResponses response field #{key}"
    end)

    assert is_binary(body["id"])
    assert body["object"] == "response"
    assert is_integer(body["created_at"])
    assert is_nil(body["completed_at"]) or is_integer(body["completed_at"])
    assert is_binary(body["status"])
    assert is_nil(body["incomplete_details"]) or is_map(body["incomplete_details"])
    assert is_binary(body["model"])
    assert is_nil(body["previous_response_id"])
    assert is_nil(body["instructions"]) or is_binary(body["instructions"])
    assert is_list(body["input"])
    assert is_list(body["output"])
    assert is_nil(body["error"]) or is_map(body["error"])
    assert is_list(body["tools"])
    assert body["tool_choice"] in ["none", "auto", "required"] or is_map(body["tool_choice"])
    assert body["truncation"] in ["auto", "disabled"]
    assert is_boolean(body["parallel_tool_calls"])
    assert get_in(body, ["text", "format", "type"]) == "text"
    assert is_number(body["top_p"])
    assert is_number(body["presence_penalty"])
    assert is_number(body["frequency_penalty"])
    assert is_integer(body["top_logprobs"])
    assert is_number(body["temperature"])
    assert is_map(body["reasoning"])
    assert Map.has_key?(body["reasoning"], "effort")
    assert Map.has_key?(body["reasoning"], "summary")
    assert is_nil(body["user"]) or is_binary(body["user"])
    assert_response_usage(body["usage"])
    assert is_nil(body["max_output_tokens"]) or is_integer(body["max_output_tokens"])
    assert is_nil(body["max_tool_calls"]) or is_integer(body["max_tool_calls"])
    assert is_boolean(body["store"])
    assert is_boolean(body["background"])
    assert is_binary(body["service_tier"])
    assert is_map(body["metadata"])
    assert is_nil(body["safety_identifier"]) or is_binary(body["safety_identifier"])
    assert is_nil(body["prompt_cache_key"]) or is_binary(body["prompt_cache_key"])
    assert is_list(Map.get(body, "next_response_ids", []))
    assert is_list(Map.get(body, "context_edits", []))

    assert is_nil(body["prompt_cache_retention"]) or
             body["prompt_cache_retention"] in ["in_memory", "24h"]

    assert is_nil(body["conversation"]) or is_binary(body["conversation"]["id"])

    Enum.each(body["input"], &assert_openresponses_input_item/1)
    Enum.each(body["output"], &assert_openresponses_output_item/1)
    Enum.each(body["tools"], &assert_openresponses_tool/1)
  end

  defp assert_openresponses_input_item(%{"type" => "message"} = item) do
    assert is_binary(item["id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert item["role"] in ["system", "developer", "user", "assistant", "tool"]
    assert is_list(item["content"])

    Enum.each(item["content"], fn
      %{"type" => "input_text"} = part ->
        assert is_binary(part["text"])

      %{"type" => "output_text"} = part ->
        assert is_binary(part["text"])
        assert is_list(part["annotations"])

      %{"type" => type} ->
        assert type in ["input_image", "input_file", "input_video", "refusal"]
    end)
  end

  defp assert_openresponses_input_item(%{"type" => "function_call"} = item) do
    assert_openresponses_output_item(item)
  end

  defp assert_openresponses_input_item(%{"type" => "function_call_output"} = item) do
    assert is_binary(item["id"])
    assert is_binary(item["call_id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert is_binary(item["output"]) or is_list(item["output"])
  end

  defp assert_openresponses_input_item(item),
    do: flunk("unexpected OpenResponses input item: #{inspect(item)}")

  defp assert_openresponses_output_item(%{"type" => "message"} = item) do
    assert is_binary(item["id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert item["role"] in ["system", "developer", "user", "assistant", "tool"]
    assert is_list(item["content"])
    assert is_nil(item["phase"]) or item["phase"] in ["commentary", "final_answer"]

    Enum.each(item["content"], fn
      %{"type" => "output_text"} = part ->
        assert is_binary(part["text"])
        assert is_list(part["annotations"])

      %{"type" => type} ->
        assert type in [
                 "input_text",
                 "text",
                 "input_image",
                 "input_file",
                 "input_video",
                 "refusal"
               ]
    end)
  end

  defp assert_openresponses_output_item(%{"type" => "function_call"} = item) do
    assert is_binary(item["id"])
    assert is_binary(item["call_id"])
    assert is_binary(item["name"])
    assert is_binary(item["arguments"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
  end

  defp assert_openresponses_output_item(item),
    do: flunk("unexpected OpenResponses output item: #{inspect(item)}")

  defp assert_openresponses_tool(%{"type" => "function"} = tool) do
    assert is_binary(tool["name"])
    assert is_nil(tool["description"]) or is_binary(tool["description"])
    assert is_nil(tool["parameters"]) or is_map(tool["parameters"])
    assert is_nil(tool["strict"]) or is_boolean(tool["strict"])
  end

  defp assert_openresponses_tool(tool),
    do: flunk("unexpected OpenResponses tool: #{inspect(tool)}")

  defp assert_response_usage(usage) do
    assert is_map(usage)
    assert is_integer(usage["input_tokens"])
    assert is_integer(usage["output_tokens"])
    assert is_integer(usage["total_tokens"])
    assert is_integer(get_in(usage, ["input_tokens_details", "cached_tokens"]))
    assert is_integer(get_in(usage, ["output_tokens_details", "reasoning_tokens"]))
  end

  defp response_usage_fixture do
    %{
      "input_tokens" => 1,
      "output_tokens" => 2,
      "total_tokens" => 3,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end
end
