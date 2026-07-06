defmodule AnkoleWeb.AIGatewayResponsesSocketTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.Kernel.UniversalAIClient
  alias Ankole.Repo
  alias AnkoleWeb.AIGatewayResponsesSocket

  defmodule NativeResponsesWebSocketUpstreamPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "GET", request_path: "/v1/responses"} = conn, opts) do
      WebSockAdapter.upgrade(
        conn,
        AnkoleWeb.AIGatewayResponsesSocketTest.NativeResponsesWebSocketUpstream,
        %{test_pid: opts[:test_pid]},
        []
      )
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Ankole.JSON.encode!(%{"error" => %{"message" => "not found"}}))
    end
  end

  defmodule NativeResponsesWebSocketUpstream do
    @moduledoc false

    @behaviour WebSock

    @impl true
    def init(%{test_pid: test_pid}) do
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_in({payload, [opcode: :text]}, state) do
      send(state.test_pid, {:native_socket_upstream_request, Ankole.JSON.decode!(payload)})

      {:push, {:text, Ankole.JSON.encode!(response_created())}, state}
    end

    def handle_in(_message, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp response_created do
      %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{
          "id" => "resp_native_socket",
          "object" => "response",
          "status" => "in_progress",
          "output" => [],
          "usage" => %{}
        }
      }
    end
  end

  test "stateful frames rewrite nested response id before forwarding" do
    {_agent, _conversation, actor_event, message} = stateful_message("socket-rewrite")
    ref = make_ref()

    active =
      active_stream(ref, message, actor_event,
        accumulated_items: [],
        terminal_committed: false
      )

    chunk = %{
      "type" => "response.created",
      "sequence_number" => 0,
      "response" => %{
        "id" => "provider_resp_created",
        "object" => "response",
        "status" => "in_progress",
        "output" => []
      }
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 0, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    expected_response_id = "resp_#{message.id}"

    assert %{"response" => %{"id" => ^expected_response_id}} = Ankole.JSON.decode!(pushed)
  end

  test "stateful frames rewrite top-level response_id before forwarding" do
    {_agent, _conversation, actor_event, message} = stateful_message("socket-rewrite-response-id")
    ref = make_ref()

    active =
      active_stream(ref, message, actor_event,
        accumulated_items: [],
        terminal_committed: false
      )

    chunk = %{
      "type" => "response.output_item.added",
      "sequence_number" => 1,
      "response_id" => "provider_resp_item",
      "output_index" => 0,
      "item" => %{
        "id" => "msg_provider_item",
        "type" => "message",
        "status" => "in_progress",
        "role" => "assistant",
        "content" => []
      }
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 1, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    expected_response_id = "resp_#{message.id}"

    assert %{"response_id" => ^expected_response_id} = Ankole.JSON.decode!(pushed)
  end

  test "response.create rejects a second in-flight response on the same WebSocket" do
    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")]
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: "agent-test",
               subject_type: "agent",
               active_stream: %{ref: make_ref()}
             })

    assert %{
             "type" => "error",
             "status" => 409,
             "error" => %{"code" => "response_in_progress"}
           } = Ankole.JSON.decode!(pushed)

    assert Map.has_key?(state, :active_stream)
  end

  test "stateful non-terminal provider frame grants the next native read and keeps active stream" do
    %{principal: agent} = agent_fixture()

    server =
      start_supervised!(
        {Bandit,
         plug: {NativeResponsesWebSocketUpstreamPlug, test_pid: self()},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-native-socket-read-credit",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-native-socket-read-credit",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-native-read-credit")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-native-read-credit")

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}",
        "metadata" => %{"actor_event_id" => actor_event.id}
      })

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert_receive {:native_socket_upstream_request,
                    %{
                      "type" => "response.create",
                      "model" => "gpt-main",
                      "input" => [%{"role" => "user"}]
                    }}

    assert_receive {:universal_ai_client, ref, :chunk, seq, :websocket_text, chunk}
    assert ref == active.ref

    assert {:push, {:text, pushed}, %{active_stream: next_active} = next_state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, seq, :websocket_text, chunk},
               state
             )

    assert next_active.ref == active.ref

    assert %{
             "type" => "response.created",
             "response" => %{"id" => response_id}
           } = Ankole.JSON.decode!(pushed)

    assert response_id == "resp_#{get_in(active, [:stateful, :message_id])}"

    _ = UniversalAIClient.cancel(next_state.active_stream.stream)
  end

  test "stateful completed terminal frame is committed with provider telemetry before forwarding" do
    {agent, _conversation, actor_event, message} = stateful_message("socket-complete")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    terminal_item = %{
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "done", "annotations" => []}]
    }

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 7,
      "response" => %{
        "id" => "provider_resp_done",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-terminal",
        "service_tier" => "default",
        "system_fingerprint" => "fp_123",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7},
        "output" => [terminal_item]
      }
    }

    pid = self()
    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({UniversalAIClient, :read, 2}, true, [:local])

    pushed =
      try do
        assert {:push, {:text, pushed}, state} =
                 AIGatewayResponsesSocket.handle_info(
                   {:universal_ai_client, ref, :chunk, 7, :websocket_text,
                    Ankole.JSON.encode!(chunk)},
                   %{active_stream: active}
                 )

        refute_receive {:trace, ^pid, :call, {UniversalAIClient, :read, _args}}
        refute Map.has_key?(state, :active_stream)
        pushed
      after
        :erlang.trace_pattern({UniversalAIClient, :read, 2}, false, [:local])
        :erlang.trace(pid, false, [:call])
      end

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => ^expected_response_id}
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ [terminal_item]
    assert stored.metadata["provider_model"] == "gpt-terminal"
    assert stored.metadata["usage"]["total_tokens"] == 7
    assert stored.metadata["stop_reason"] == "stop"

    assert stored.metadata["provider_metadata"] == %{
             "id" => "provider_resp_done",
             "object" => "response",
             "model" => "gpt-terminal",
             "status" => "completed",
             "service_tier" => "default",
             "system_fingerprint" => "fp_123"
           }

    assert stored.metadata["response"] == %{
             "id" => "provider_resp_done",
             "object" => "response",
             "status" => "completed"
           }

    assert {:ok, %{body: body}} = AIGateway.retrieve_response(agent.uid, expected_response_id)
    assert body["usage"]["total_tokens"] == 7
    assert body["provider_metadata"]["system_fingerprint"] == "fp_123"
    assert body["stop_reason"] == "stop"
    assert body["tool_results"] == []
    assert body["metadata"] == %{}
  end

  test "stateful completed terminal frame preserves non-message response items" do
    {agent, _conversation, actor_event, message} = stateful_message("socket-computer-item")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    computer_item = %{
      "type" => "computer_call",
      "id" => "comp_1",
      "status" => "completed",
      "action" => %{"type" => "screenshot"}
    }

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 10,
      "response" => %{
        "id" => "provider_resp_computer",
        "object" => "response",
        "status" => "completed",
        "output" => [computer_item]
      }
    }

    assert {:push, {:text, _pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 10, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ [computer_item]

    assert {:ok, %{body: body}} = AIGateway.retrieve_response(agent.uid, "resp_#{message.id}")
    assert body["output"] == [computer_item]
  end

  test "stateful terminal frame tolerates an already terminal row" do
    {_agent, _conversation, actor_event, message} = stateful_message("socket-already-terminal")
    ref = make_ref()

    terminal_item = %{
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "done", "annotations" => []}]
    }

    assert {:ok, committed} = StatefulResponses.commit_complete(message, [terminal_item], %{})

    active = active_stream(ref, message, actor_event)

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 8,
      "response" => %{
        "id" => "provider_resp_duplicate_done",
        "object" => "response",
        "status" => "completed",
        "output" => [terminal_item]
      }
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 8, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => ^expected_response_id}
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == committed.content
  end

  test "stateful incomplete terminal frame commits durable partial output as incomplete response" do
    {agent, _conversation, actor_event, message} = stateful_message("socket-incomplete")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    terminal_item = %{
      "type" => "message",
      "status" => "incomplete",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "partial", "annotations" => []}]
    }

    incomplete_details = %{"reason" => "max_output_tokens"}

    chunk = %{
      "type" => "response.incomplete",
      "sequence_number" => 9,
      "response" => %{
        "id" => "provider_resp_incomplete",
        "object" => "response",
        "status" => "incomplete",
        "model" => "gpt-terminal",
        "incomplete_details" => incomplete_details,
        "output" => [terminal_item]
      }
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 9, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.incomplete",
             "response" => %{"id" => ^expected_response_id}
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ [terminal_item]
    assert stored.metadata["provider_model"] == "gpt-terminal"
    assert stored.metadata["incomplete_details"] == incomplete_details

    assert {:ok, %{body: body}} = AIGateway.retrieve_response(agent.uid, expected_response_id)
    assert body["status"] == "incomplete"
    assert body["incomplete_details"] == incomplete_details
    assert body["output"] == [terminal_item]
  end

  test "stateful terminal commit failure sends failed frame instead of completed" do
    message_id = Ecto.UUID.generate()
    ref = make_ref()

    active = %{
      ref: ref,
      stream: fake_stream(ref),
      stateful: %{message_id: message_id, actor_event_id: Ecto.UUID.generate()},
      accumulated_items: [],
      text_buffer: "",
      seq: 0,
      terminal_error: nil,
      terminal_committed: false,
      terminal_received: false
    }

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 3,
      "response" => %{
        "id" => "provider_resp_done",
        "object" => "response",
        "status" => "completed",
        "output" => []
      }
    }

    assert {{:push, {:text, pushed}, _state}, _log} =
             with_log(fn ->
               AIGatewayResponsesSocket.handle_info(
                 {:universal_ai_client, ref, :chunk, 3, :websocket_text,
                  Ankole.JSON.encode!(chunk)},
                 %{active_stream: active}
               )
             end)

    expected_response_id = "resp_#{message_id}"

    assert %{
             "type" => "response.failed",
             "sequence_number" => 3,
             "response" => %{
               "id" => ^expected_response_id,
               "status" => "failed",
               "error" => %{"code" => "stateful_commit_failed"}
             }
           } = Ankole.JSON.decode!(pushed)
  end

  test "stateful terminal commit failure keeps actor event open for retry" do
    {_agent, _conversation, actor_event, message} = stateful_message("socket-commit-failure-open")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    terminal_items = [
      %{
        "type" => "message",
        "status" => "completed",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "done", "annotations" => []}]
      },
      %{
        "type" => "function_call",
        "call_id" => "call_reply_attachment",
        "name" => "reply_attachment",
        "arguments" => "{}"
      },
      %{
        "type" => "function_call_output",
        "call_id" => "call_reply_attachment",
        "output" => %{
          "tool" => "reply_attachment",
          "attachments" => [
            %{
              "file_path" => "/workspace/shared/user-files/report.pdf",
              "visible_to" => "agent_computer"
            }
          ]
        }
      }
    ]

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 11,
      "response" => %{
        "id" => "provider_resp_commit_failure_open",
        "object" => "response",
        "status" => "completed",
        "output" => terminal_items
      }
    }

    assert {{:push, {:text, pushed}, _state}, _log} =
             with_log(fn ->
               AIGatewayResponsesSocket.handle_info(
                 {:universal_ai_client, ref, :chunk, 11, :websocket_text,
                  Ankole.JSON.encode!(chunk)},
                 %{active_stream: active}
               )
             end)

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.failed",
             "response" => %{
               "id" => ^expected_response_id,
               "status" => "failed",
               "error" => %{"code" => "stateful_commit_failed"}
             }
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ terminal_items
    assert stored.metadata["error"]["stage"] == "terminal_commit"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "output item done keeps completed item in memory for cleanup commit" do
    request_item = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "start"}]
    }

    {_agent, _conversation, actor_event, message} =
      stateful_message("socket-completed-item", [request_item])

    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    completed_item = %{
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "completed", "annotations" => []}]
    }

    chunk = %{
      "type" => "response.output_item.done",
      "sequence_number" => 5,
      "item" => completed_item
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 5, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    assert %{"type" => "response.output_item.done"} = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == [request_item, completed_item]
    assert stored.metadata["error"]["stage"] == "socket_cleanup"
    assert stored.metadata["error"]["retryable"] == true
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "function call output item publishes tool activity preview event" do
    {_agent, _conversation, actor_event, message} =
      stateful_message("socket-tool-activity-start", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "search"}]
        }
      ])

    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "ai_gateway:actor_event:#{actor_event.id}")

    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_web_fetch",
      "name" => "web_fetch",
      "arguments" => ~s({"url":"https://example.test"})
    }

    chunk = %{
      "type" => "response.output_item.done",
      "sequence_number" => 7,
      "item" => function_call
    }

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :chunk, 7, :websocket_text,
                Ankole.JSON.encode!(chunk)},
               %{active_stream: active}
             )

    assert %{"type" => "response.output_item.done"} = Ankole.JSON.decode!(pushed)

    assert_receive {:ai_gateway_live, :tool_call_started,
                    %{
                      "call_id" => "call_web_fetch",
                      "name" => "web_fetch",
                      "seq" => 7
                    }}
  end

  test "provider stream errors preserve accumulated partial response items" do
    {_agent, _conversation, actor_event, message} =
      stateful_message("socket-error-partial", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "start"}]
        }
      ])

    ref = make_ref()

    partial_item = %{
      "type" => "message",
      "status" => "incomplete",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "partial", "annotations" => []}]
    }

    active = active_stream(ref, message, actor_event, accumulated_items: [partial_item])

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :error, %{"message" => "upstream closed"}},
               %{active_stream: active}
             )

    refute Map.has_key?(state, :active_stream)

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.failed",
             "response" => %{
               "id" => ^expected_response_id,
               "status" => "failed",
               "error" => %{
                 "code" => "provider_stream_error",
                 "retryable" => true,
                 "details" => details
               }
             }
           } = Ankole.JSON.decode!(pushed)

    assert details =~ "upstream closed"

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_item]
    assert stored.metadata["error"]["stage"] == "socket_cleanup"
    assert stored.metadata["error"]["retryable"] == true
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "provider stream done without a terminal frame commits retryable error" do
    {_agent, _conversation, actor_event, message} =
      stateful_message("socket-done-without-terminal", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "start"}]
        }
      ])

    ref = make_ref()

    partial_item = %{
      "type" => "message",
      "status" => "incomplete",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "partial", "annotations" => []}]
    }

    active = active_stream(ref, message, actor_event, accumulated_items: [partial_item])

    assert {:ok, state} =
             AIGatewayResponsesSocket.handle_info(
               {:universal_ai_client, ref, :done, %{"reason" => "provider_closed"}},
               %{active_stream: active}
             )

    refute Map.has_key?(state, :active_stream)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_item]
    assert stored.metadata["error"]["code"] == "provider_stream_closed_without_terminal"
    assert stored.metadata["error"]["retryable"] == true
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "stateful overflow sends structured context_overflow error frame" do
    {agent, conversation, _actor_event, message} =
      stateful_message("socket-overflow", [
        media_message("https://files.example.test/#{String.duplicate("large", 40)}.png")
      ])

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-overflow",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-overflow",
               model: "gpt-main"
             })

    assert {:ok, _message} =
             StatefulResponses.commit_complete(message, [], %{
               "usage" => %{"total_tokens" => 24}
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "new request")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}",
        "metadata" => %{"actor_event_id" => Ecto.UUID.generate()}
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 422,
             "error" => %{
               "code" => "context_overflow",
               "details_json" => %{
                 "reason" => "no_compaction_candidate",
                 "truncation" => "disabled"
               }
             }
           } = Ankole.JSON.decode!(pushed)
  end

  test "stateful response.create requires metadata actor_event_id" do
    %{principal: agent} = agent_fixture()

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true,
        "conversation" => "conv_#{Ecto.UUID.generate()}"
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 400,
             "error" => %{
               "code" => "missing_actor_event_id",
               "param" => "metadata.actor_event_id"
             }
           } = Ankole.JSON.decode!(pushed)
  end

  test "response.tool_results.record writes a completed journal row without opening a provider stream" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-tool-results-record")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-tool-results-record")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [text_message("user", "use a tool")]
      })

    {:ok, anchor} =
      StatefulResponses.commit_complete(anchor, [
        %{
          "type" => "function_call",
          "call_id" => "call_socket_record",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ])

    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "ai_gateway:actor_event:#{actor_event.id}")

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.tool_results.record",
        "model" => "primary",
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_socket_record",
            "output" => "recorded"
          }
        ],
        "store" => true,
        "previous_response_id" => "resp_#{anchor.id}",
        "metadata" => %{"actor_event_id" => actor_event.id}
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    refute Map.has_key?(state, :active_stream)
    anchor_response_id = "resp_#{anchor.id}"

    assert %{
             "type" => "response.tool_results.recorded",
             "response_id" => response_id,
             "response" => %{
               "id" => response_id,
               "status" => "completed",
               "previous_response_id" => ^anchor_response_id,
               "input" => [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_socket_record",
                   "output" => "recorded"
                 }
               ],
               "output" => []
             }
           } = Ankole.JSON.decode!(pushed)

    "resp_" <> message_id = response_id

    assert %Message{status: "complete", previous_message_id: anchor_id} =
             Repo.get!(Message, message_id)

    assert anchor_id == anchor.id

    assert_receive {:ai_gateway_live, :tool_call_completed,
                    %{"call_id" => "call_socket_record", "output" => "recorded"}}
  end

  test "stateful response.create rejects duplicate actor event runs before provider open" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-duplicate-actor-event",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-duplicate-actor-event",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-duplicate-actor-event")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-duplicate-event")

    {:ok, first_run} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [text_message("user", "first delivery")]
      })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "redelivered delivery")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}",
        "metadata" => %{"actor_event_id" => actor_event.id}
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 409,
             "error" => %{"code" => "response_in_progress"}
           } = Ankole.JSON.decode!(pushed)

    runs =
      Message
      |> Repo.all()
      |> Enum.filter(&(get_in(&1.metadata, ["actor_event_id"]) == actor_event.id))

    assert Enum.map(runs, & &1.id) == [first_run.id]
  end

  test "stateful response.create rejects raw conversation ids" do
    %{principal: agent} = agent_fixture()

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true,
        "conversation" => Ecto.UUID.generate(),
        "metadata" => %{"actor_event_id" => Ecto.UUID.generate()}
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 400,
             "error" => %{"code" => "invalid_stateful_conversation"}
           } = Ankole.JSON.decode!(pushed)
  end

  test "stateful response.create reports unknown conversation as a request error" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-invalid-conversation",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-invalid-conversation",
               model: "gpt-main"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true,
        "conversation" => "conv_#{Ecto.UUID.generate()}",
        "metadata" => %{"actor_event_id" => Ecto.UUID.generate()}
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 400,
             "error" => %{"code" => "invalid_stateful_conversation"}
           } = Ankole.JSON.decode!(pushed)
  end

  test "stateful upstream socket-open 429 sends retryable error frame without completing actor event" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_upstream_server(fn _request ->
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
               provider_id: "openai-socket-upstream-429",
               provider_kind: "openai",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openai",
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-upstream-429",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-upstream-429")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-event-upstream-429")

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "instructions" => "Reply tersely.",
        "service_tier" => "agent-default",
        "prompt_cache_key" => "cache-noop",
        "input" => [text_message("user", "new request")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}",
        "metadata" => %{"actor_event_id" => actor_event.id, "request_tag" => "kept"}
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 429,
             "error" => %{
               "code" => "upstream_response_failed",
               "message" => message,
               "details_json" => %{
                 "stage" => "socket_open",
                 "upstream_status" => 429,
                 "retryable" => true
               }
             }
           } = Ankole.JSON.decode!(pushed)

    assert message =~ "429"

    [run] =
      Message
      |> Repo.all()
      |> Enum.filter(&(get_in(&1.metadata, ["actor_event_id"]) == actor_event.id))

    assert run.status == "error"
    assert run.metadata["error"]["stage"] == "socket_open"
    assert run.metadata["instructions"] == "Reply tersely."
    assert run.metadata["service_tier"] == "agent-default"
    assert run.metadata["prompt_cache_key"] == "cache-noop"
    assert run.metadata["request_model"] == "primary"
    refute Map.has_key?(run.metadata, "model")
    assert run.metadata["request_tag"] == "kept"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  defp stateful_message(session_suffix, request_items \\ []) do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-test-#{session_suffix}")

    actor_event =
      actor_event_fixture(
        agent.uid,
        conversation.conversation_key,
        "socket-event-#{session_suffix}"
      )

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: request_items
      })

    {agent, conversation, actor_event, message}
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

  defp active_stream(ref, message, actor_event, opts \\ []) do
    defaults = %{
      ref: ref,
      stream: fake_stream(ref),
      stateful: %{message_id: message.id, actor_event_id: actor_event.id},
      accumulated_items: [],
      text_buffer: "",
      seq: 0,
      terminal_error: nil,
      terminal_committed: false,
      terminal_received: false
    }

    Map.merge(defaults, Map.new(opts))
  end

  defp fake_stream(ref) do
    %UniversalAIClient.Stream{resource: make_ref(), ref: ref, owner: self()}
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

  defp with_compaction_config(config) do
    assert {:ok, _config} = Compaction.put_config(Map.new(config))

    on_exit(fn ->
      _result = Compaction.delete_config()
      :ok
    end)
  end
end
