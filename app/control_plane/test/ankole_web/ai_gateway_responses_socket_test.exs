defmodule AnkoleWeb.AIGatewayResponsesSocketTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.MaxToolCalls
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.ResponseStream.State, as: ResponseStreamState
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias AnkoleWeb.AIGatewayResponsesSocket

  defmodule FakeResponseStream do
    @moduledoc false

    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call({:read, _count}, _from, state), do: {:reply, :ok, state}
    def handle_call({:cancel, _reason}, _from, state), do: {:stop, :normal, :ok, state}
  end

  defmodule NativeResponsesWebSocketUpstreamPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "GET", request_path: "/v1/responses"} = conn, opts) do
      WebSockAdapter.upgrade(
        conn,
        AnkoleWeb.AIGatewayResponsesSocketTest.NativeResponsesWebSocketUpstream,
        %{
          test_pid: opts[:test_pid],
          scenario: opts[:scenario] || :created,
          counter: opts[:counter],
          authorization: conn |> get_req_header("authorization") |> List.first()
        },
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
    def init(%{test_pid: test_pid} = state) when is_pid(test_pid) do
      {:ok, state}
    end

    @impl true
    def handle_in({payload, [opcode: :text]}, state) do
      send(state.test_pid, {:native_socket_upstream_request, Ankole.JSON.decode!(payload)})

      case response_frames(state) do
        [frame] -> {:push, frame, state}
        frames -> {:push, frames, state}
      end
    end

    def handle_in(_message, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp response_frames(%{scenario: :created_then_overload} = state) do
      attempt = :atomics.add_get(state.counter, 1, 1)
      send(state.test_pid, {:native_socket_upstream_attempt, attempt, state.authorization})

      events =
        if attempt == 1,
          do: [response_created(), response_failed(1)],
          else: [response_completed()]

      Enum.map(events, &{:text, Ankole.JSON.encode!(&1)})
    end

    defp response_frames(%{scenario: :output_then_overload} = state) do
      attempt = :atomics.add_get(state.counter, 1, 1)
      send(state.test_pid, {:native_socket_upstream_attempt, attempt, state.authorization})

      [
        {:text, Ankole.JSON.encode!(response_output())},
        {:text, Ankole.JSON.encode!(response_failed(1))}
      ]
    end

    defp response_frames(%{scenario: :created_then_rate_limit} = state) do
      attempt = :atomics.add_get(state.counter, 1, 1)
      send(state.test_pid, {:native_socket_upstream_attempt, attempt, state.authorization})

      [
        {:text, Ankole.JSON.encode!(response_created())},
        {:text, Ankole.JSON.encode!(response_rate_limited())}
      ]
    end

    defp response_frames(_state), do: [{:text, Ankole.JSON.encode!(response_created())}]

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

    defp response_completed do
      %{
        "type" => "response.completed",
        "sequence_number" => 0,
        "response" => %{
          "id" => "resp_native_socket_completed",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{}
        }
      }
    end

    defp response_output do
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 0,
        "item" => %{
          "id" => "msg_native_socket",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => "visible"}]
        }
      }
    end

    defp response_failed(sequence_number) do
      %{
        "type" => "response.failed",
        "sequence_number" => sequence_number,
        "response" => %{
          "id" => "resp_native_socket_failed",
          "object" => "response",
          "status" => "failed",
          "error" => %{
            "type" => "service_unavailable_error",
            "code" => "server_is_overloaded",
            "message" => "opaque provider text",
            "param" => nil
          },
          "output" => []
        }
      }
    end

    defp response_rate_limited do
      reset_at = DateTime.utc_now(:second) |> DateTime.add(600) |> DateTime.to_unix()

      %{
        "type" => "response.failed",
        "sequence_number" => 1,
        "response" => %{
          "id" => "resp_native_socket_rate_limited",
          "object" => "response",
          "status" => "failed",
          "error" => %{
            "type" => "rate_limit_error",
            "code" => "rate_limit_exceeded",
            "message" => "opaque provider text",
            "status" => 429,
            "details_json" => %{
              "provider_status" => 429,
              "provider_headers" => %{
                "x-codex-primary-reset-at" => Integer.to_string(reset_at)
              }
            }
          },
          "output" => []
        }
      }
    end
  end

  test "logs bounded context when a socket closes with an active response stream" do
    ref = make_ref()

    state = %{
      subject_uid: "principal-test",
      active_stream: %{
        ref: ref,
        stream: fake_stream(ref),
        request_input: [%{"content" => "private prompt"}],
        actor_event_id: "actor-event-test",
        model: "google/gemini-3.1-flash-image",
        started_at_ms: System.monotonic_time(:millisecond) - 25
      }
    }

    log =
      capture_log(
        [
          level: :warning,
          metadata: [
            :event,
            :subject_uid,
            :actor_event_id,
            :model,
            :duration_ms,
            :termination_reason
          ]
        ],
        fn ->
          assert :ok =
                   AIGatewayResponsesSocket.terminate(
                     {:remote, "private transport details"},
                     state
                   )
        end
      )

    assert log =~ "event=ai_gateway.responses_socket_interrupted"
    assert log =~ "subject_uid=principal-test"
    assert log =~ "actor_event_id=actor-event-test"
    assert log =~ "model=google/gemini-3.1-flash-image"
    assert log =~ "duration_ms="
    assert log =~ "termination_reason=remote"
    refute log =~ "private prompt"
    refute log =~ "private transport details"
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

    pushed =
      first_pushed_text(handle_test_event(%{active_stream: active}, ref, chunk, 0))

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

    pushed =
      first_pushed_text(handle_test_event(%{active_stream: active}, ref, chunk, 1))

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

  test "implicit continuation rejects an active run opened by another WebSocket" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-implicit-admission-conflict",
               provider_kind: "openai",
               base_url: "https://api.openai.invalid/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-implicit-admission-conflict",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-implicit-admission-conflict")

    {:ok, root} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id
      })

    {:ok, root} = StatefulResponses.commit_complete(root, [text_message("assistant", "done")])

    {:ok, active_run} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        previous_response_id: "resp_#{root.id}"
      })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "continue")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}"
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 409,
             "error" => %{"code" => "response_in_progress"}
           } = Ankole.JSON.decode!(pushed)

    refute Map.has_key?(state, :active_stream)

    assert [persisted_active_run] =
             Message
             |> where([message], message.conversation_id == ^conversation.id)
             |> where([message], message.status == "generating")
             |> Repo.all()

    assert persisted_active_run.id == active_run.id
  end

  test "hosted image request validation uses the official flat Responses error event" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-hosted-validation",
               provider_kind: "openrouter",
               base_url: "https://openrouter.invalid/api/v1",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-hosted-validation",
               model: "test/main-model"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => "draw a lake",
        "tools" => [
          %{"type" => "function", "name" => "lookup", "parameters" => %{}},
          %{"type" => "image_generation", "unknown_option" => true}
        ]
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "sequence_number" => 0,
             "code" => "unknown_parameter",
             "message" => message,
             "param" => "tools[1].unknown_option"
           } = event = Ankole.JSON.decode!(pushed)

    assert message =~ "tools[1].unknown_option"
    refute Map.has_key?(event, "status")
    refute Map.has_key?(event, "error")
  end

  test "response.create maps invalid tool contracts to the official flat error event" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-tool-contract-socket",
               provider_kind: "openrouter",
               base_url: "https://openrouter.invalid/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-invalid-tool-contract-socket",
               model: "test/main-model"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => "Run the tool.",
        "tools" => [
          %{
            "type" => "function",
            "name" => "broken",
            "parameters" => %{"type" => "object", "properties" => %{}},
            "allowed_callers" => ["bogus"]
          },
          %{"type" => "programmatic_tool_calling"}
        ]
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "sequence_number" => 0,
             "code" => "invalid_tool_contract",
             "param" => nil,
             "message" => message
           } = event = Ankole.JSON.decode!(pushed)

    assert message == "The Responses tool declaration or tool-call history is invalid."
    refute pushed =~ "invalid_allowed_callers"
    refute pushed =~ "bogus"
    refute Map.has_key?(event, "status")
    refute Map.has_key?(event, "error")
    refute Map.has_key?(state, :active_stream)
  end

  test "response.create rejects a positive budget with mixed tool effect owners" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-mixed-tool-budget-socket",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.invalid/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               },
               connection_options: %{"endpoint_kind" => "responses"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compatible-mixed-tool-budget-socket",
               model: "gpt-main"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => "Run tools.",
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
        "max_tool_calls" => 1
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "sequence_number" => 0,
             "code" => "unsupported_value",
             "param" => "max_tool_calls"
           } = event = Ankole.JSON.decode!(pushed)

    assert event["message"] =~ "positive max_tool_calls"
    refute Map.has_key?(state, :active_stream)
  end

  test "response.create accepts mixed tool owners when tool_choice is none" do
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
               provider_id: "openai-socket-mixed-tool-budget-none",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"upstream_transport" => "websocket"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-mixed-tool-budget-none",
               model: "gpt-main"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
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

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["tool_choice"] == "none"
    assert upstream_request["max_tool_calls"] == 1

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
    assert active.ref == state.active_stream.ref
  end

  test "response.create forwards normal Codex ResponseCreateWsRequest fields" do
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
               provider_id: "openai-native-socket-codex-response-create",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-native-socket-codex-response-create",
               model: "gpt-main"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "instructions" => "Use the available tools.",
        "previous_response_id" => nil,
        "input" => [text_message("user", "hello")],
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup",
            "parameters" => %{"type" => "object"}
          }
        ],
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "max_tool_calls" => 2,
        "reasoning" => %{"effort" => "low"},
        "store" => false,
        "stream" => true,
        "stream_options" => %{"include_usage" => true},
        "include" => ["reasoning.encrypted_content"],
        "service_tier" => "priority",
        "prompt_cache_key" => "cache-key",
        "text" => %{"verbosity" => "low"},
        "client_metadata" => %{
          "traceparent" => "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        }
      })

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["type"] == "response.create"
    assert upstream_request["model"] == "gpt-main"
    assert upstream_request["instructions"] == "Use the available tools."
    assert upstream_request["input"] == [text_message("user", "hello")]

    assert upstream_request["tools"] == [
             %{
               "type" => "function",
               "name" => "lookup",
               "parameters" => %{"type" => "object"}
             }
           ]

    assert upstream_request["tool_choice"] == "auto"
    assert upstream_request["parallel_tool_calls"] == true
    assert upstream_request["max_tool_calls"] == 2
    assert upstream_request["reasoning"] == %{"effort" => "low"}
    assert upstream_request["store"] == false
    assert upstream_request["stream"] == true
    assert upstream_request["stream_options"] == %{"include_usage" => true}
    assert upstream_request["include"] == ["reasoning.encrypted_content"]
    assert upstream_request["prompt_cache_key"] == "cache-key"
    assert upstream_request["text"] == %{"verbosity" => "low"}

    assert upstream_request["client_metadata"] == %{
             "traceparent" => "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
           }

    refute Map.has_key?(upstream_request, "service_tier")
    refute Map.has_key?(active, :max_tool_calls)

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
    assert active.ref == state.active_stream.ref
  end

  test "response.create completes Codex generate false prewarm without a provider call" do
    %{principal: agent} = agent_fixture()
    prewarm_input = [text_message("developer", "Use the available tools.")]

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "store" => false,
        "input" => prewarm_input,
        "generate" => false
      })

    assert {:push, [{:text, created_json}, {:text, completed_json}], state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert %{
             "type" => "response.created",
             "sequence_number" => 0,
             "response" => %{
               "id" => response_id,
               "status" => "in_progress",
               "output" => []
             }
           } = Ankole.JSON.decode!(created_json)

    assert String.starts_with?(response_id, "tmp_resp_")

    assert %{
             "type" => "response.completed",
             "sequence_number" => 1,
             "response" => %{
               "id" => ^response_id,
               "status" => "completed",
               "output" => [],
               "usage" => %{
                 "input_tokens" => 0,
                 "output_tokens" => 0,
                 "total_tokens" => 0
               }
             }
           } = Ankole.JSON.decode!(completed_json)

    refute Map.has_key?(state, :active_stream)
    assert state.response_history[response_id].items == prewarm_input
    refute_receive {:native_socket_upstream_request, _request}, 50

    counter = :atomics.new(1, [])
    provider_id = "openai-native-socket-codex-prewarm"
    base_url = start_native_socket_upstream(:created, counter)
    :ok = configure_native_socket_provider(agent.uid, provider_id, base_url)

    task_input = text_message("user", "Build the requested artifact.")

    task_request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "store" => false,
        "previous_response_id" => response_id,
        "input" => [task_input]
      })

    assert {:ok, %{active_stream: active} = next_state} =
             AIGatewayResponsesSocket.handle_in(
               {task_request, [opcode: :text]},
               state
             )

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["input"] == prewarm_input ++ [task_input]
    refute Map.has_key?(upstream_request, "previous_response_id")
    assert active.socket_previous_response_id == response_id

    _ = AIGateway.cancel_response_stream(next_state.active_stream.stream)
  end

  test "the first provider event prevents a transparent retry" do
    %{principal: agent} = agent_fixture()
    counter = :atomics.new(1, [])
    provider_id = "openai-native-socket-provider-event-boundary"
    base_url = start_native_socket_upstream(:created_then_overload, counter)

    configure_native_socket_provider(agent.uid, provider_id, base_url)

    request = %{
      "type" => "response.create",
      "model" => "primary",
      "input" => [text_message("user", "hello")],
      "store" => false
    }

    assert {:ok, %ResponseStream{ref: ref} = stream, _meta} =
             AIGateway.open_websocket_stream(agent.uid, request,
               receiver: self(),
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert :ok = AIGateway.read_response_stream(stream, 4)
    assert_receive {:native_socket_upstream_attempt, 1, "Bearer sk-first"}

    assert_receive {:ai_gateway_response_stream, ^ref, :events, [%{"type" => "response.created"}],
                    :continue},
                   5_000

    assert_receive {:ai_gateway_response_stream, ^ref, :events,
                    [
                      %{
                        "type" => "response.failed",
                        "response" => %{
                          "error" => %{
                            "code" => "server_is_overloaded",
                            "failure_kind" => "provider_response",
                            "retryable" => true
                          }
                        }
                      }
                    ],
                    {:terminal,
                     %{
                       terminal_error: %{
                         "code" => "server_is_overloaded",
                         "failure_kind" => "provider_response",
                         "retryable" => true
                       }
                     }}},
                   5_000

    refute_receive {:native_socket_upstream_attempt, 2, _authorization}, 300

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "ok"
    assert by_id["second"]["status"] == "ok"
  end

  test "Codex overload after provider output does not replay the request" do
    %{principal: agent} = agent_fixture()
    counter = :atomics.new(1, [])
    provider_id = "openai-native-socket-overload-after-output"
    base_url = start_native_socket_upstream(:output_then_overload, counter)

    configure_native_socket_provider(agent.uid, provider_id, base_url)

    request = %{
      "type" => "response.create",
      "model" => "primary",
      "input" => [text_message("user", "hello")],
      "store" => false
    }

    assert {:ok, %ResponseStream{ref: ref} = stream, _meta} =
             AIGateway.open_websocket_stream(agent.uid, request,
               receiver: self(),
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert :ok = AIGateway.read_response_stream(stream, 4)
    assert_receive {:native_socket_upstream_attempt, 1, "Bearer sk-first"}

    assert_receive {:ai_gateway_response_stream, ^ref, :events,
                    [%{"type" => "response.output_item.done"}], :continue},
                   5_000

    assert_receive {:ai_gateway_response_stream, ^ref, :events,
                    [
                      %{
                        "type" => "response.failed",
                        "response" => %{
                          "error" => %{
                            "code" => "server_is_overloaded",
                            "failure_kind" => "provider_response",
                            "retryable" => true
                          }
                        }
                      }
                    ],
                    {:terminal,
                     %{
                       terminal_error: %{
                         "code" => "server_is_overloaded",
                         "failure_kind" => "provider_response",
                         "retryable" => true
                       }
                     }}},
                   5_000

    refute_receive {:native_socket_upstream_attempt, 2, _authorization}, 300
  end

  test "a post-output 429 exhausts only its credential without replay" do
    %{principal: agent} = agent_fixture()
    counter = :atomics.new(1, [])
    provider_id = "openai-native-socket-post-output-rate-limit"
    base_url = start_native_socket_upstream(:created_then_rate_limit, counter)

    configure_native_socket_provider(agent.uid, provider_id, base_url)

    request = %{
      "type" => "response.create",
      "model" => "primary",
      "input" => [text_message("user", "hello")],
      "store" => false
    }

    assert {:ok, %ResponseStream{ref: ref} = stream, _meta} =
             AIGateway.open_websocket_stream(agent.uid, request,
               receiver: self(),
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert :ok = AIGateway.read_response_stream(stream, 4)
    assert_receive {:native_socket_upstream_attempt, 1, "Bearer sk-first"}

    assert_receive {:ai_gateway_response_stream, ^ref, :events, [%{"type" => "response.created"}],
                    :continue},
                   5_000

    assert_receive {:ai_gateway_response_stream, ^ref, :events, [%{"type" => "response.failed"}],
                    {:terminal, %{terminal_error: %{"code" => "rate_limit_exceeded"}}}},
                   5_000

    refute_receive {:native_socket_upstream_attempt, 2, _authorization}, 300

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 429
    assert is_binary(by_id["first"]["retry_at"])
    assert by_id["second"]["status"] == "ok"
  end

  test "response.create store true without previous_response_id or conversation creates a managed durable conversation" do
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
               provider_id: "openai-native-socket-codex-store",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-native-socket-codex-store",
               model: "gpt-main"
             })

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true
      })

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["type"] == "response.create"
    assert upstream_request["store"] == false
    refute Map.has_key?(upstream_request, "conversation")
    refute Map.has_key?(upstream_request, "previous_response_id")

    message = Repo.get_by!(Message, subject_uid: agent.uid, status: "generating")
    conversation = Repo.get!(Conversation, message.conversation_id)

    assert conversation.metadata == %{"managed_by_stateful_responses_api" => true}
    refute Map.has_key?(message.metadata, "actor_event_id")
    assert message.content == [text_message("user", "hello")]

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
    assert active.ref == state.active_stream.ref
  end

  test "response.create expands WebSocket previous_response_id from connection history" do
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
               provider_id: "openai-native-socket-history",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-native-socket-history",
               model: "gpt-main"
             })

    function_call = %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_1",
      "name" => "write_file",
      "arguments" => "{\"path\":\"index.html\"}",
      "status" => "completed"
    }

    tool_result = %{
      "type" => "function_call_output",
      "call_id" => "call_1",
      "output" => "ok"
    }

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "previous_response_id" => "resp_socket_1",
        "store" => false,
        "input" => [tool_result]
      })

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in(
               {request, [opcode: :text]},
               %{
                 subject_uid: agent.uid,
                 subject_type: "agent",
                 response_history: %{
                   "resp_socket_1" => %{
                     items: [text_message("user", "write the file"), function_call]
                   }
                 },
                 response_history_order: ["resp_socket_1"]
               }
             )

    assert_receive {:native_socket_upstream_request, upstream_request}

    refute Map.has_key?(upstream_request, "previous_response_id")
    assert upstream_request["store"] == false

    assert [
             %{"role" => "user"},
             %{"type" => "function_call", "call_id" => "call_1"},
             %{"type" => "function_call_output", "call_id" => "call_1"}
           ] = upstream_request["input"]

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
    assert active.ref == state.active_stream.ref
  end

  test "response.create caches completed store false responses for same-socket continuation" do
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
               provider_id: "openai-native-socket-same-connection-history",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-native-socket-same-connection-history",
               model: "gpt-main"
             })

    ref = make_ref()

    first_input = [text_message("user", "remember cobalt")]

    function_call = %{
      "id" => "fc_cached",
      "type" => "function_call",
      "call_id" => "call_cached",
      "name" => "lookup",
      "arguments" => "{}",
      "status" => "completed"
    }

    terminal_chunk = %{
      "type" => "response.completed",
      "sequence_number" => 4,
      "response" => %{
        "id" => "resp_socket_cached",
        "object" => "response",
        "status" => "completed",
        "output" => [function_call]
      }
    }

    assert {:push, {:text, _pushed}, state} =
             handle_test_event(
               %{
                 subject_uid: agent.uid,
                 subject_type: "agent",
                 active_stream: stateless_active_stream(ref, first_input)
               },
               ref,
               terminal_chunk,
               4
             )

    assert Map.has_key?(state.response_history, "resp_socket_cached")

    tool_result = %{
      "type" => "function_call_output",
      "call_id" => "call_cached",
      "output" => "ok"
    }

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "store" => false,
        "previous_response_id" => "resp_socket_cached",
        "input" => [tool_result]
      })

    assert {:ok, %{active_stream: active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, state)

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["store"] == false
    refute Map.has_key?(upstream_request, "previous_response_id")

    assert [
             %{"role" => "user"},
             %{"type" => "function_call", "call_id" => "call_cached"},
             %{"type" => "function_call_output", "call_id" => "call_cached"}
           ] = upstream_request["input"]

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
    assert active.socket_previous_response_id == "resp_socket_cached"
  end

  test "response.create reports previous_response_not_found for uncached store false continuation" do
    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "store" => false,
        "previous_response_id" => "resp_missing",
        "input" => "continue"
      })

    assert {:push, {:text, pushed}, _state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: "agent-test",
               subject_type: "agent"
             })

    assert %{
             "type" => "error",
             "status" => 400,
             "error" => %{
               "code" => "previous_response_not_found",
               "param" => "previous_response_id"
             }
           } = Ankole.JSON.decode!(pushed)
  end

  test "failed store false continuation evicts the referenced connection-local response" do
    ref = make_ref()

    cached_input = [text_message("user", "remember ember")]

    failed_chunk = %{
      "type" => "response.failed",
      "sequence_number" => 6,
      "response" => %{
        "id" => "resp_failed_continuation",
        "object" => "response",
        "status" => "failed",
        "error" => %{"code" => "invalid_tool_output", "message" => "tool output mismatch"},
        "output" => []
      }
    }

    state = %{
      subject_uid: "agent-test",
      subject_type: "agent",
      response_history: %{
        "resp_socket_ember" => %{items: cached_input}
      },
      response_history_order: ["resp_socket_ember"],
      active_stream:
        stateless_active_stream(ref, [
          %{
            "type" => "function_call_output",
            "call_id" => "call_missing",
            "output" => "missing"
          }
        ])
        |> Map.put(:socket_previous_response_id, "resp_socket_ember")
    }

    assert {:push, {:text, pushed}, next_state} =
             handle_test_event(state, ref, failed_chunk, 6)

    assert %{"type" => "response.failed"} = Ankole.JSON.decode!(pushed)
    refute Map.has_key?(next_state.response_history, "resp_socket_ember")
    refute "resp_socket_ember" in next_state.response_history_order
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
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

    assert_receive {:ai_gateway_response_stream, ref, :events, _events, :continue} =
                     stream_message

    assert ref == active.ref

    assert {:push, {:text, pushed}, %{active_stream: next_active} = next_state} =
             AIGatewayResponsesSocket.handle_info(stream_message, state)

    assert next_active.ref == active.ref

    assert %{
             "type" => "response.created",
             "response" => %{"id" => response_id}
           } = Ankole.JSON.decode!(pushed)

    message = Repo.get_by!(Message, conversation_id: conversation.id, status: "generating")
    assert response_id == "resp_#{message.id}"

    _ = AIGateway.cancel_response_stream(next_state.active_stream.stream)
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

    assert {:push, {:text, pushed}, state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 7)

    refute Map.has_key?(state, :active_stream)

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
    assert body["metadata"] == %{"actor_event_id" => actor_event.id}
  end

  test "stateful completed terminal frame preserves non-message response items" do
    {agent, _conversation, actor_event, message} = stateful_message("socket-computer-item")
    ref = make_ref()

    active = active_stream(ref, message, actor_event)

    web_search_item = %{
      "type" => "web_search_call",
      "id" => "search_1",
      "status" => "completed",
      "action" => %{"type" => "search"}
    }

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 10,
      "response" => %{
        "id" => "provider_resp_computer",
        "object" => "response",
        "status" => "completed",
        "output" => [web_search_item]
      }
    }

    assert {:push, {:text, _pushed}, _state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 10)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ [web_search_item]
    refute Map.has_key?(stored.metadata["provider_metadata"], "max_tool_calls")

    assert {:ok, %{body: body}} = AIGateway.retrieve_response(agent.uid, "resp_#{message.id}")
    assert body["status"] == "completed"
    assert body["output"] == [web_search_item]
  end

  test "non-native max_tool_calls waits for the provider terminal after the admitted call" do
    {agent, conversation, actor_event, message} =
      stateful_message("socket-max-tool-calls-late-stop")

    :ok = AIGateway.subscribe(agent.uid, conversation.id)

    ref = make_ref()

    active =
      active_stream(ref, message, actor_event,
        max_tool_calls: MaxToolCalls.new(1, :openai_chat_completions)
      )

    web_search_item = %{
      "type" => "web_search_call",
      "id" => "search_late_stop",
      "status" => "completed",
      "action" => %{"type" => "search"}
    }

    chunk = %{
      "type" => "response.output_item.done",
      "sequence_number" => 10,
      "response_id" => "provider_resp_late_stop",
      "output_index" => 0,
      "item" => web_search_item
    }

    assert {:push, {:text, provider_chunk}, state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 10)

    assert Map.has_key?(state, :active_stream)

    response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.output_item.done",
             "response_id" => ^response_id
           } = Ankole.JSON.decode!(provider_chunk)

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 11,
      "response" => %{
        "id" => "provider_resp_late_stop",
        "object" => "response",
        "status" => "completed",
        "output" => [web_search_item]
      }
    }

    assert {:push, {:text, completed_chunk}, state} =
             handle_test_event(state, ref, terminal, 11)

    refute Map.has_key?(state, :active_stream)

    assert %{
             "type" => "response.completed",
             "response" => %{
               "id" => ^response_id,
               "status" => "completed",
               "output" => [^web_search_item]
             }
           } = Ankole.JSON.decode!(completed_chunk)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ [web_search_item]
    assert stored.metadata["response"]["status"] == "completed"
    assert stored.metadata["stop_reason"] == "stop"
    refute Map.has_key?(stored.metadata["provider_metadata"], "max_tool_calls")

    assert_receive {:ai_gateway_event, :tool_call_started,
                    %{
                      response_id: ^response_id,
                      metadata: %{"actor_event_id" => actor_event_id},
                      payload: %{
                        "id" => "search_late_stop",
                        "status" => "completed",
                        "type" => "web_search_call"
                      }
                    }}

    assert actor_event_id == actor_event.id

    assert {:ok, %{body: body}} = AIGateway.retrieve_response(agent.uid, response_id)
    assert body["status"] == "completed"
    assert body["output"] == [web_search_item]

    assert_receive {:ai_gateway_event, :response_completed,
                    %{response_id: ^response_id, payload: %{content: [^web_search_item]}}}
  end

  test "non-native max_tool_calls ignores a stateless provider call beyond zero" do
    ref = make_ref()
    request_item = text_message("user", "search")

    active =
      ref
      |> stateless_active_stream([request_item])
      |> Map.put(:max_tool_calls, MaxToolCalls.new(0, :anthropic_messages))

    web_search_item = %{
      "type" => "web_search_call",
      "id" => "search_stateless",
      "status" => "completed"
    }

    chunk = %{
      "type" => "response.output_item.done",
      "sequence_number" => 4,
      "response_id" => "provider_resp_stateless_limit",
      "output_index" => 0,
      "item" => web_search_item
    }

    assert {:ok, state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 4)

    assert Map.has_key?(state, :active_stream)

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 5,
      "response" => %{
        "id" => "provider_resp_stateless_limit",
        "object" => "response",
        "status" => "completed",
        "output" => [web_search_item]
      }
    }

    assert {:push, {:text, completed_chunk}, state} =
             handle_test_event(state, ref, terminal, 5)

    refute Map.has_key?(state, :active_stream)

    assert %{
             "type" => "response.completed",
             "response" => %{
               "id" => "provider_resp_stateless_limit",
               "status" => "completed",
               "output" => []
             }
           } = Ankole.JSON.decode!(completed_chunk)

    assert %{items: [^request_item]} =
             state.response_history["provider_resp_stateless_limit"]
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
             handle_test_event(%{active_stream: active}, ref, chunk, 8)

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
             handle_test_event(%{active_stream: active}, ref, chunk, 9)

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

  test "stateful upstream-closed terminal keeps partial calls for audit but commits the run as error" do
    {_agent, conversation, actor_event, message} = stateful_message("socket-upstream-closed")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    partial_call = %{
      "type" => "custom_tool_call",
      "status" => "incomplete",
      "call_id" => "call_partial",
      "name" => "apply_patch",
      "input" => "*** Begin Patch\n*** Add File: repor"
    }

    chunk = %{
      "type" => "response.incomplete",
      "sequence_number" => 10,
      "response" => %{
        "id" => "provider_resp_upstream_closed",
        "object" => "response",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "upstream_stream_closed"},
        "output" => [partial_call]
      }
    }

    assert {:push, {:text, pushed}, _state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 10)

    assert %{
             "type" => "response.incomplete",
             "response" => %{"output" => [^partial_call]}
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_call]
    assert stored.metadata["error"]["code"] == "partial_tool_call_incomplete"
    assert stored.metadata["error"]["reason"] == "upstream_stream_closed"
    assert stored.metadata["error"]["retryable"] == true
    assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
  end

  test "max-output terminal with a partial call commits error instead of an incomplete success" do
    {_agent, conversation, actor_event, message} = stateful_message("socket-max-output-partial")
    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    partial_call = %{
      "type" => "function_call",
      "status" => "incomplete",
      "call_id" => "call_max_output_partial",
      "name" => "patch",
      "arguments" => "{\"path\":\"/tmp/repor"
    }

    chunk = %{
      "type" => "response.incomplete",
      "sequence_number" => 11,
      "response" => %{
        "id" => "provider_resp_max_output_partial",
        "object" => "response",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "output" => [partial_call]
      }
    }

    assert {:push, {:text, _pushed}, _state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 11)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.metadata["error"]["code"] == "partial_tool_call_incomplete"
    assert stored.metadata["error"]["reason"] == "max_output_tokens"
    assert stored.metadata["error"]["retryable"] == false
    assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
  end

  test "provider-completed response with an incomplete call is an error, not executable history" do
    {_agent, conversation, actor_event, message} =
      stateful_message("socket-partial-call-completed")

    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    partial_call = %{
      "type" => "function_call",
      "status" => "in_progress",
      "call_id" => "call_still_streaming",
      "name" => "replace",
      "arguments" => "{\"path\":\"report.md\""
    }

    chunk = %{
      "type" => "response.completed",
      "sequence_number" => 11,
      "response" => %{
        "id" => "provider_resp_false_complete",
        "object" => "response",
        "status" => "completed",
        "output" => [partial_call]
      }
    }

    assert {:push, {:text, _pushed}, _state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 11)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_call]
    assert stored.metadata["error"]["code"] == "partial_tool_call_completed"
    assert stored.metadata["stop_reason"] == "error"
    assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
  end

  test "stateful terminal commit failure sends failed frame instead of completed" do
    message_id = Ecto.UUID.generate()
    ref = make_ref()

    stateful = %{message_id: message_id, message: %Message{id: message_id}}

    active = %{
      ref: ref,
      stream: fake_stream(ref),
      test_semantic: ResponseStreamState.new("agent-test", %{}, %{}, stateful: stateful)
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
               handle_test_event(%{active_stream: active}, ref, chunk, 3)
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

  test "stateful terminal commit does not project Actor state or attachments" do
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
              "file_path" => "/agents/agent-1/user-files/report.pdf",
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
               handle_test_event(%{active_stream: active}, ref, chunk, 11)
             end)

    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.completed",
             "response" => %{
               "id" => ^expected_response_id,
               "status" => "completed"
             }
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "complete"
    assert stored.content == message.content ++ terminal_items
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

    pushed =
      first_pushed_text(
        handle_test_event_then_fail(
          %{active_stream: active},
          ref,
          chunk,
          5,
          "stream_read_failed: test",
          code: "provider_stream_error",
          retryable: true
        )
      )

    assert %{"type" => "response.output_item.done"} = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == [request_item, completed_item]
    assert stored.metadata["error"]["stage"] == "response_stream_cleanup"
    assert stored.metadata["error"]["retryable"] == true
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "function call output item publishes tool activity preview event" do
    {agent, conversation, actor_event, message} =
      stateful_message("socket-tool-activity-start", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "search"}]
        }
      ])

    :ok = Events.subscribe(agent.uid, conversation.id)

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

    pushed =
      first_pushed_text(handle_test_event(%{active_stream: active}, ref, chunk, 7))

    assert %{"type" => "response.output_item.done"} = Ankole.JSON.decode!(pushed)

    assert_receive {:ai_gateway_event, :tool_call_started, event}
    assert event.response_id == "resp_#{message.id}"
    assert event.metadata["actor_event_id"] == actor_event.id

    assert event.payload == %{
             "call_id" => "call_web_fetch",
             "name" => "web_fetch",
             "seq" => 7,
             "type" => "function_call"
           }
  end

  test "provider-visible reasoning is published live without entering durable response items" do
    {agent, conversation, actor_event, message} =
      stateful_message("socket-reasoning-live", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "think"}]
        }
      ])

    :ok = Events.subscribe(agent.uid, conversation.id)

    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    chunk = %{
      "type" => "response.reasoning_summary_text.delta",
      "sequence_number" => 8,
      "delta" => "Checking the evidence."
    }

    pushed =
      first_pushed_text(handle_test_event(%{active_stream: active}, ref, chunk, 8))

    assert ^chunk = Ankole.JSON.decode!(pushed)

    assert_receive {:ai_gateway_event, :reasoning_delta, event}
    assert event.response_id == "resp_#{message.id}"

    assert event.payload == %{
             text: "Checking the evidence.",
             source: "response.reasoning_summary_text.delta",
             seq: 8
           }

    stored = Repo.get!(Message, message.id)
    assert stored.content == message.content
    refute inspect(stored) =~ "Checking the evidence."
  end

  test "provider stream errors preserve accumulated partial response items" do
    {agent, _conversation, actor_event, message} =
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
             handle_test_failure(
               %{active_stream: active},
               ref,
               ~s(provider_stream_error: %{"message" => "upstream closed"}),
               code: "provider_stream_error",
               retryable: true
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
                 "retryable" => true
               }
             }
           } = Ankole.JSON.decode!(pushed)

    refute pushed =~ "upstream closed"

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_item]
    assert stored.metadata["error"]["stage"] == "response_stream_cleanup"
    assert stored.metadata["error"]["retryable"] == true
    refute inspect(stored.metadata["error"]) =~ "upstream closed"

    assert {:ok,
            %{
              body: %{
                "error" => %{
                  "code" => "provider_stream_error",
                  "message" => "AIGateway provider stream failed before a terminal response."
                }
              }
            }} = AIGateway.retrieve_response(agent.uid, expected_response_id)

    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "provider stream done without a terminal frame sends retryable response.failed" do
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

    assert {:push, {:text, pushed}, state} =
             handle_test_failure(
               %{active_stream: active},
               ref,
               "provider_stream_closed_without_terminal",
               code: "provider_stream_closed_without_terminal",
               retryable: true
             )

    refute Map.has_key?(state, :active_stream)
    expected_response_id = "resp_#{message.id}"

    assert %{
             "type" => "response.failed",
             "response" => %{
               "id" => ^expected_response_id,
               "status" => "failed",
               "error" => %{
                 "code" => "provider_stream_closed_without_terminal",
                 "retryable" => true
               }
             }
           } = Ankole.JSON.decode!(pushed)

    stored = Repo.get!(Message, message.id)
    assert stored.status == "error"
    assert stored.content == message.content ++ [partial_item]
    assert stored.metadata["error"]["code"] == "provider_stream_closed_without_terminal"
    assert stored.metadata["error"]["retryable"] == true
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "provider terminal failure keeps safe attribution through persist and retrieve" do
    {agent, _conversation, actor_event, message} =
      stateful_message("socket-provider-failure-round-trip")

    ref = make_ref()
    active = active_stream(ref, message, actor_event)

    chunk = %{
      "type" => "response.failed",
      "sequence_number" => 12,
      "response" => %{
        "id" => "provider_resp_failed",
        "object" => "response",
        "status" => "failed",
        "error" => %{
          "code" => "invalid_request",
          "message" => "private provider message"
        },
        "output" => []
      }
    }

    assert {:push, {:text, pushed}, _state} =
             handle_test_event(%{active_stream: active}, ref, chunk, 12)

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{
                 "code" => "invalid_request",
                 "failure_kind" => "provider_response",
                 "message" => "private provider message",
                 "retryable" => false
               }
             }
           } = Ankole.JSON.decode!(pushed)

    assert pushed =~ "private provider message"

    stored_error = Repo.get!(Message, message.id).metadata["error"]
    assert stored_error["failure_kind"] == "provider_response"
    assert stored_error["message"] == "private provider message"

    assert {:ok, %{body: %{"error" => retrieved_error}}} =
             AIGateway.retrieve_response(agent.uid, "resp_#{message.id}")

    assert retrieved_error == %{
             "code" => "invalid_request",
             "failure_kind" => "provider_response",
             "message" => "private provider message",
             "retryable" => false
           }
  end

  test "stateful overflow sends structured context_overflow error frame" do
    {agent, conversation, _actor_event, message} =
      stateful_message("socket-overflow", [
        media_message_with_memory_nudge(
          "https://files.example.test/#{String.duplicate("large", 40)}.png"
        )
      ])

    with_compaction_config(threshold: 0.50, max_threshold_tokens: 10, tail_rows: 1)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-overflow",
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

  test "stateful response.create accepts an explicit conversation without actor_event_id" do
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
               provider_id: "openai-socket-conversation-without-actor-event",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:#{port}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-conversation-without-actor-event",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-conversation-without-actor-event")

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "hello")],
        "store" => true,
        "conversation" => "conv_#{conversation.id}"
      })

    assert {:ok, %{active_stream: _active} = state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    assert_receive {:native_socket_upstream_request, upstream_request}
    assert upstream_request["store"] == false
    refute Map.has_key?(upstream_request, "conversation")

    message = Repo.get_by!(Message, conversation_id: conversation.id, status: "generating")
    assert message.conversation_id == conversation.id
    refute Map.has_key?(message.metadata, "actor_event_id")

    _ = AIGateway.cancel_response_stream(state.active_stream.stream)
  end

  test "response.tool_results.record writes a completed journal row without opening a provider stream" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-tool-results-record")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-tool-results-record")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}},
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

    :ok = Events.subscribe(agent.uid, conversation.id)

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

    assert_receive {:ai_gateway_event, :tool_call_completed, event}
    assert event.response_id == response_id
    assert event.metadata["actor_event_id"] == actor_event.id

    assert event.payload == %{
             "call_id" => "call_socket_record",
             "output" => "recorded",
             "seq" => nil
           }
  end

  test "response.tool_results.record reports quarantined orphan output without opening a provider stream" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-tool-results-quarantine")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [text_message("user", "stable input")]
      })

    {:ok, anchor} =
      StatefulResponses.commit_complete(anchor, [text_message("assistant", "stable answer")])

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.tool_results.record",
        "model" => "primary",
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_socket_orphan",
            "output" => "raw side effect result"
          }
        ],
        "store" => true,
        "previous_response_id" => "resp_#{anchor.id}"
      })

    assert {:push, {:text, pushed}, state} =
             AIGatewayResponsesSocket.handle_in({request, [opcode: :text]}, %{
               subject_uid: agent.uid,
               subject_type: "agent"
             })

    refute Map.has_key?(state, :active_stream)

    assert %{
             "type" => "error",
             "status" => 409,
             "error" => %{
               "code" => "tool_results_quarantined",
               "param" => "input",
               "details_json" => %{
                 "reason" => "orphan_tool_call_output",
                 "orphan_call_ids" => ["call_socket_orphan"],
                 "quarantine_response_id" => quarantine_response_id,
                 "quarantine_status" => "error"
               }
             }
           } = Ankole.JSON.decode!(pushed)

    "resp_" <> quarantine_id = quarantine_response_id
    assert Repo.get!(Message, quarantine_id).status == "error"
    assert StatefulResponses.latest_visible_leaf(conversation.id) == anchor.id
  end

  test "stateful response.create treats duplicate actor metadata as opaque" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-duplicate-actor-event",
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
               provider_id: "openai-socket-duplicate-actor-event",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-duplicate-actor-event")

    actor_event =
      actor_event_fixture(agent.uid, conversation.conversation_key, "socket-duplicate-event")

    {:ok, first_run} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}},
        request_items: [text_message("user", "first delivery")]
      })

    {:ok, first_run} = StatefulResponses.commit_complete(first_run, [])

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
             "status" => 502,
             "error" => %{
               "code" => "upstream_transport_failed",
               "details_json" => %{
                 "stage" => "socket_open",
                 "error_code" => "websocket_connect_failed",
                 "error_stage" => "connect",
                 "retryable" => true
               }
             }
           } = Ankole.JSON.decode!(pushed)

    runs =
      Message
      |> Repo.all()
      |> Enum.filter(
        &(get_in(&1.metadata, ["request_metadata", "actor_event_id"]) == actor_event.id)
      )

    assert Enum.any?(runs, &(&1.id == first_run.id and &1.status == "complete"))
    assert Enum.any?(runs, &(&1.id != first_run.id and &1.status == "error"))

    failed_run = Enum.find(runs, &(&1.id != first_run.id))

    assert failed_run.metadata["error"] == %{
             "code" => "websocket_connect_failed",
             "error_stage" => "connect",
             "failure_kind" => "transport",
             "message" => "The upstream provider connection failed.",
             "retryable" => true,
             "stage" => "socket_open"
           }
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
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
    test_pid = self()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(900)

    base_url =
      start_upstream_server(fn _request ->
        send(test_pid, :socket_pool_attempt)

        {:json, 429,
         [{"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}],
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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
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

    assert_receive :socket_pool_attempt
    refute_receive :socket_pool_attempt

    assert %{
             "type" => "error",
             "status" => 429,
             "headers" => %{
               "retry-after" => retry_after,
               "x-codex-primary-reset-at" => reset_at_header
             },
             "error" => %{
               "type" => "usage_limit_reached",
               "code" => "credential_pool_exhausted",
               "message" => message,
               "resets_at" => resets_at,
               "details_json" => %{"retry_at" => retry_at}
             }
           } = Ankole.JSON.decode!(pushed)

    assert resets_at == DateTime.to_unix(reset_at)
    assert reset_at_header == Integer.to_string(resets_at)
    assert {retry_after_seconds, ""} = Integer.parse(retry_after)
    assert retry_after_seconds in 0..900
    assert {:ok, parsed_retry_at, _offset} = DateTime.from_iso8601(retry_at)
    assert DateTime.compare(parsed_retry_at, reset_at) == :eq
    assert message =~ "All credentials in this provider pool are unavailable."

    [run] =
      Message
      |> Repo.all()
      |> Enum.filter(
        &(get_in(&1.metadata, ["request_metadata", "actor_event_id"]) == actor_event.id)
      )

    assert run.status == "error"

    assert run.metadata["error"] == %{
             "code" => "credential_pool_exhausted",
             "failure_kind" => "provider_response",
             "message" => "All credentials in this provider pool are temporarily unavailable.",
             "provider_status" => 429,
             "retryable" => true,
             "retry_at" => retry_at,
             "stage" => "socket_open"
           }

    assert run.metadata["instructions"] == "Reply tersely."
    assert run.metadata["service_tier"] == "agent-default"
    assert run.metadata["prompt_cache_key"] == "cache-noop"
    assert run.metadata["request_model"] == "primary"
    refute Map.has_key?(run.metadata, "model")
    assert get_in(run.metadata, ["request_metadata", "request_tag"]) == "kept"
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
  end

  test "stateful upstream socket-open keeps a large non-JSON 503 response out of public and stored errors" do
    %{principal: agent} = agent_fixture()
    private_marker = "provider-private-marker-503"

    base_url =
      start_upstream_server(fn _request ->
        {:raw, 503, "text/plain",
         private_marker <> ":" <> String.duplicate("unavailable;", 32_768)}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-socket-upstream-large-503",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-socket-upstream-large-503",
               model: "gpt-main"
             })

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(agent.uid, "socket-upstream-large-503")

    actor_event =
      actor_event_fixture(
        agent.uid,
        conversation.conversation_key,
        "socket-event-upstream-large-503"
      )

    request =
      Ankole.JSON.encode!(%{
        "type" => "response.create",
        "model" => "primary",
        "input" => [text_message("user", "new request")],
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
             "status" => 503,
             "error" => %{
               "code" => "upstream_response_failed",
               "message" => "The upstream provider request failed.",
               "details_json" => %{
                 "stage" => "socket_open",
                 "provider_status" => 503,
                 "retryable" => true
               }
             }
           } = Ankole.JSON.decode!(pushed)

    refute pushed =~ private_marker
    refute pushed =~ "unavailable;"

    [run] =
      Message
      |> Repo.all()
      |> Enum.filter(
        &(get_in(&1.metadata, ["request_metadata", "actor_event_id"]) == actor_event.id)
      )

    assert run.status == "error"

    assert run.metadata["error"] == %{
             "code" => "upstream_response_failed",
             "failure_kind" => "provider_response",
             "message" => "The upstream provider request failed.",
             "provider_status" => 503,
             "retryable" => true,
             "stage" => "socket_open"
           }

    refute inspect(run.metadata) =~ private_marker
    refute inspect(run.metadata) =~ "unavailable;"
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
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: request_items,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}}
      })

    {agent, conversation, actor_event, message}
  end

  defp start_native_socket_upstream(scenario, counter) do
    server =
      start_supervised!(
        {Bandit,
         plug:
           {NativeResponsesWebSocketUpstreamPlug,
            test_pid: self(), scenario: scenario, counter: counter},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/v1"
  end

  defp configure_native_socket_provider(agent_uid, provider_id, base_url) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               },
               connection_options: %{"upstream_transport" => "websocket"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-main"
             })

    :ok
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

  defp active_stream(ref, message, _actor_event, opts \\ []) do
    stateful = %{message_id: message.id, message: message}
    items = Keyword.get(opts, :accumulated_items, [])

    semantic =
      message.subject_uid
      |> ResponseStreamState.new(%{}, %{}, stateful: stateful)
      |> Map.put(:public_items, items)
      |> Map.put(:durable_items, items)
      |> Map.put(:max_tool_calls, Keyword.get(opts, :max_tool_calls))
      |> Map.put(:provider_response_id, Keyword.get(opts, :provider_response_id))
      |> Map.put(:sequence_number, Keyword.get(opts, :seq))

    %{
      ref: ref,
      stream: fake_stream(ref),
      test_semantic: semantic
    }
  end

  defp fake_stream(ref) do
    child_spec = Supervisor.child_spec({FakeResponseStream, []}, id: make_ref())
    pid = start_supervised!(child_spec)
    %ResponseStream{pid: pid, ref: ref}
  end

  defp stateless_active_stream(ref, request_input) do
    %{
      ref: ref,
      stream: fake_stream(ref),
      request_input: request_input,
      test_semantic: ResponseStreamState.new("agent-test", %{}, %{})
    }
  end

  defp handle_test_event(state, ref, event, sequence_number) do
    active = state.active_stream

    semantic =
      case Map.get(active, :max_tool_calls) do
        %MaxToolCalls{} = policy -> %{active.test_semantic | max_tool_calls: policy}
        _missing -> active.test_semantic
      end

    assert {:ok, semantic, events, status} =
             ResponseStreamState.observe(semantic, event, sequence_number)

    state = put_in(state, [:active_stream, :test_semantic], semantic)

    AIGatewayResponsesSocket.handle_info(
      {:ai_gateway_response_stream, ref, :events, events, public_stream_status(status)},
      state
    )
  end

  defp handle_test_failure(state, ref, reason, opts) do
    active = state.active_stream
    {semantic, events, outcome} = ResponseStreamState.fail(active.test_semantic, reason, opts)
    state = put_in(state, [:active_stream, :test_semantic], semantic)

    AIGatewayResponsesSocket.handle_info(
      {:ai_gateway_response_stream, ref, :events, events, {:terminal, outcome}},
      state
    )
  end

  defp handle_test_event_then_fail(state, ref, event, sequence_number, reason, opts) do
    active = state.active_stream

    assert {:ok, semantic, events, :continue} =
             ResponseStreamState.observe(active.test_semantic, event, sequence_number)

    {semantic, failure_events, outcome} = ResponseStreamState.fail(semantic, reason, opts)
    state = put_in(state, [:active_stream, :test_semantic], semantic)

    AIGatewayResponsesSocket.handle_info(
      {:ai_gateway_response_stream, ref, :events, events ++ failure_events, {:terminal, outcome}},
      state
    )
  end

  defp public_stream_status(:continue), do: :continue

  defp public_stream_status({:terminal, outcome, _upstream_action}),
    do: {:terminal, outcome}

  defp first_pushed_text({:push, {:text, pushed}, _state}), do: pushed
  defp first_pushed_text({:push, [{:text, pushed} | _rest], _state}), do: pushed

  defp text_message(role, text) do
    content_type = if role == "assistant", do: "output_text", else: "input_text"

    %{
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => content_type, "text" => text, "annotations" => []}]
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

  defp with_compaction_config(config) do
    assert {:ok, _config} = Compaction.put_config(Map.new(config))

    on_exit(fn ->
      _result = Compaction.delete_config()
      :ok
    end)
  end
end
