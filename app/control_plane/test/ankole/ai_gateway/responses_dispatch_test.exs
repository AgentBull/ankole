defmodule Ankole.AIGateway.ResponsesDispatchTest do
  use Ankole.AIGatewayCase

  import AnkoleWeb.AIGatewayControllerTestHelpers, only: [decode_sse_events: 1]

  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Kernel.UniversalAIClient
  alias Ankole.Repo

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
    assert request.body["reasoningEffort"] == "minimal"
    refute Map.has_key?(request.body, "service_tier")
    assert request.body["prompt_cache_key"] == "cache-a"

    assert body["id"] == "resp_test"
    assert body["model"] == "gpt-5.5"
    assert model_ref["selector"] == "primary"
    assert model_ref["provider_id"] == "openai-responses-main"
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
               connection_options: %{
                 "api_key" => "sk-openai",
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
               "metadata" => %{"request_tag" => "kept"}
             })

    provider_request = request.response_context.request

    assert provider_request["store"] == false
    assert provider_request["metadata"] == %{"request_tag" => "kept"}
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
          where: conversation.agent_uid == ^agent.uid,
          where:
            fragment("?->>'managed_by_stateful_responses_api'", conversation.metadata) == "true"
        )
      )

    assert String.starts_with?(conversation.conversation_key, "stateful-responses-api:")
    assert conversation.metadata == %{"managed_by_stateful_responses_api" => true}
  end

  test "websocket stateful previous_response_id expands history without provider state fields" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-previous-websocket",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
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
    assert provider_request["metadata"] == %{"kept" => "public"}

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

  test "websocket stateful instructions are request-scoped and are not inherited" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-instructions",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
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
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [text_message("user", "first user")],
        metadata: %{"instructions" => "old instruction"}
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

  test "websocket stateful max_tool_calls is enforced by durable actor-event history" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-max-tool-calls",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-max-tool-calls",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-max-tool-calls")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "max-tool-calls-event")

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [text_message("user", "use the tool once")]
      })

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_lookup",
      "name" => "lookup",
      "arguments" => ~s({"query":"one"})
    }

    {:ok, first} = StatefulResponses.commit_complete(first, [function_call])

    current_input = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_lookup",
        "output" => ~s({"ok":true})
      }
    ]

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    ]

    base_request = %{
      "model" => "primary",
      "input" => current_input,
      "store" => true,
      "previous_response_id" => "resp_#{first.id}",
      "tools" => tools,
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "metadata" => %{"actor_event_id" => actor_event.id}
    }

    assert {:ok, allowed_request} =
             AIGateway.prepare_websocket_request(
               agent.uid,
               Map.put(base_request, "max_tool_calls", 2)
             )

    allowed_provider_request = allowed_request.response_context.request
    assert allowed_provider_request["tools"] == tools
    assert allowed_provider_request["tool_choice"] == "auto"
    assert allowed_provider_request["parallel_tool_calls"] == true
    refute Map.has_key?(allowed_provider_request, "max_tool_calls")

    assert {:ok, capped_request} =
             AIGateway.prepare_websocket_request(
               agent.uid,
               Map.put(base_request, "max_tool_calls", 1)
             )

    capped_provider_request = capped_request.response_context.request
    assert capped_provider_request["input"] == first.content ++ current_input
    refute Map.has_key?(capped_provider_request, "tools")
    refute Map.has_key?(capped_provider_request, "tool_choice")
    refute Map.has_key?(capped_provider_request, "parallel_tool_calls")
    refute Map.has_key?(capped_provider_request, "max_tool_calls")
  end

  test "websocket stateful max_tool_calls zero disables first-turn tools" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-max-tool-calls-zero",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-max-tool-calls-zero",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-max-tool-calls-zero")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "max-tool-calls-zero-event")

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "do not call tools")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "tools" => tools,
               "tool_choice" => "auto",
               "parallel_tool_calls" => true,
               "max_tool_calls" => 0,
               "metadata" => %{"actor_event_id" => actor_event.id}
             })

    provider_request = request.response_context.request
    refute Map.has_key?(provider_request, "tools")
    refute Map.has_key?(provider_request, "tool_choice")
    refute Map.has_key?(provider_request, "parallel_tool_calls")
    refute Map.has_key?(provider_request, "max_tool_calls")
  end

  test "websocket stateful max_tool_calls count is not reset by compaction coverage" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-max-tool-calls-compaction",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-max-tool-calls-compaction",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "dispatch-max-tool-calls-compaction")

    actor_event =
      actor_event_fixture(
        agent.uid,
        conversation.conversation_key,
        "max-tool-calls-compaction-event"
      )

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_lookup_1",
      "name" => "lookup",
      "arguments" => ~s({"query":"one"})
    }

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [text_message("user", "use the tool")]
      })

    {:ok, first} = StatefulResponses.commit_complete(first, [function_call])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        previous_response_id: "resp_#{first.id}",
        actor_event_id: actor_event.id,
        request_items: [
          %{"type" => "function_call_output", "call_id" => "call_lookup_1", "output" => "ok"}
        ]
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [text_message("assistant", "tail")])

    {:ok, compaction} =
      insert_compaction_checkpoint(
        agent.uid,
        conversation,
        second,
        "first tool round summarized",
        [],
        %{"auto" => true}
      )

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_lookup_2",
                   "output" => "ok"
                 }
               ],
               "store" => true,
               "previous_response_id" => "resp_#{compaction.id}",
               "tools" => tools,
               "tool_choice" => "auto",
               "parallel_tool_calls" => true,
               "max_tool_calls" => 1,
               "metadata" => %{"actor_event_id" => actor_event.id}
             })

    provider_request = request.response_context.request
    refute Map.has_key?(provider_request, "tools")
    refute Map.has_key?(provider_request, "tool_choice")
    refute Map.has_key?(provider_request, "parallel_tool_calls")
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
               connection_options: %{
                 "api_key" => "sk-openai",
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
      |> Enum.filter(&(get_in(&1.metadata, ["actor_event_id"]) == actor_event.id))

    assert run.previous_message_id == first.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "websocket stateful conversation run stores checkpoint instead of projected tail as durable anchor" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-compaction-anchor",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
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
      |> Enum.filter(&(get_in(&1.metadata, ["actor_event_id"]) == actor_event.id))

    assert run.previous_message_id == compaction.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "compaction threshold follows model context ratio with a configurable cap" do
    _result = Compaction.delete_config()

    assert %{
             tokens: 120_000,
             context_length: 400_000,
             effective_context_length: 400_000,
             threshold: 0.50,
             max_threshold_tokens: 120_000
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
               connection_options: %{
                 "api_key" => "sk-openai",
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
    refute inspect(provider_input) =~ memory_pre_compaction_nudge_marker()
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
               connection_options: %{
                 "api_key" => "sk-openai",
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

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(4))

    current_input = [text_message("user", "new current request")]

    assert {:ok, request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
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
    assert summarizer_request.body["instructions"] =~ "context summarization assistant"
    assert summarizer_request.body["max_output_tokens"] == 4_096
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
               connection_options: %{
                 "api_key" => "sk-openai",
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

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(4))

    {:ok, m4} =
      start_linked_stateful_message(agent.uid, conversation, m3, "compact-tool-d", [
        text_message("assistant", "final answer after the tool result")
      ])

    {:ok, m4} = StatefulResponses.commit_complete(m4, [], camel_usage(4))

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

  test "websocket stateful auto-compaction strips analysis blocks from summaries" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200, response_summary("<analysis>scratch</analysis>\n## Active Task\nX")}
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-strip-analysis", base_url)
    {conversation, _tail} = compactable_conversation!(agent, "dispatch-strip-analysis")

    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "strip-analysis-event"}
             })

    assert_receive {:gateway_request, _summarizer_request}

    [compaction] = Repo.all(Message) |> Enum.filter(&(&1.type == "checkpoint"))
    artifact = Repo.get!(CompactionArtifact, compaction.id)
    assert get_in(artifact.content, ["summary", "text"]) == "## Active Task\nX"
  end

  test "websocket stateful auto-compaction retries malformed analysis shape on next selector" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    base_url =
      start_recording_upstream(self(), fn request ->
        case request.body["model"] do
          "gpt-compact-light" -> {:json, 200, response_summary("<analysis>truncated...")}
          "gpt-main" -> {:json, 200, response_summary("## Active Task\nPrimary summary")}
        end
      end)

    create_openai_compaction_provider!(agent, "openai-compaction-shape-retry", base_url)
    {conversation, _tail} = compactable_conversation!(agent, "dispatch-shape-retry")

    assert {:ok, _request} =
             AIGateway.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "new current request")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"actor_event_id" => "shape-retry-event"}
             })

    assert_receive {:gateway_request, light_request}
    assert_receive {:gateway_request, primary_request}
    assert light_request.body["model"] == "gpt-compact-light"
    assert primary_request.body["model"] == "gpt-main"

    [compaction] = Repo.all(Message) |> Enum.filter(&(&1.type == "checkpoint"))
    assert get_in(compaction.metadata, ["summarizer", "selector"]) == "primary"
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

    {:ok, _m2} = StatefulResponses.commit_complete(m2, [], camel_usage(4))

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
               connection_options: %{
                 "api_key" => "sk-openai",
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

  test "websocket stateful truncation auto drops older non-compactable history without changing durable anchor" do
    %{principal: agent} = agent_fixture()

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 160, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-truncation-auto",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
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
        text_message("assistant", "tail assistant #{memory_pre_compaction_nudge_marker()}")
      ])

    {:ok, m2} = StatefulResponses.commit_complete(m2, [], usage(20))

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

    run =
      Repo.one!(
        from(message in Message,
          where:
            fragment("?->>'actor_event_id'", message.metadata) ==
              ^actor_event.id
        )
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
               connection_options: %{
                 "api_key" => "sk-openai",
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
        text_message("user", "latest tail #{memory_pre_compaction_nudge_marker()}")
      ])

    {:ok, _m3} = StatefulResponses.commit_complete(m3, [], usage(20))

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
               connection_options: %{
                 "api_key" => "sk-openai",
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
        text_message("user", "latest tail #{memory_pre_compaction_nudge_marker()}")
      ])

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], usage(20))

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

  test "openai_compatible requires base URL and records protocol choices" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-compatible-no-url",
               provider_kind: "openai_compatible",
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
               provider_kind: "openai_compatible",
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
    assert request.body["store"] == false
    assert List.last(events)["type"] == "response.completed"
    assert v1_body["id"] == "resp_azure_v1"
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
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
               connection_options: %{
                 "api_key" => "sk-openai",
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

    {:ok, m3} = StatefulResponses.commit_complete(m3, [], camel_usage(4))

    {conversation, m3}
  end

  defp start_stateful_message(agent_uid, conversation, source_event_id, request_items) do
    actor_event = actor_event_fixture(agent_uid, conversation.conversation_key, source_event_id)

    StatefulResponses.start_response_run(%{
      agent_uid: agent_uid,
      conversation_id: conversation.id,
      actor_event_id: actor_event.id,
      request_items: request_items
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
      agent_uid: agent_uid,
      previous_response_id: "resp_#{previous.id}",
      actor_event_id: actor_event.id,
      request_items: request_items
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
          "text" => "[#{memory_pre_compaction_nudge_marker()}]"
        }
      ]
    }
  end

  defp memory_pre_compaction_nudge_marker, do: "ankole.memory.pre_compaction_nudge.v1"

  defp usage(total_tokens), do: %{"usage" => %{"total_tokens" => total_tokens}}

  defp camel_usage(total_tokens), do: %{"usage" => %{"totalTokens" => total_tokens}}

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
             agent_uid: agent_uid,
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
        agent_uid: agent_uid,
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
