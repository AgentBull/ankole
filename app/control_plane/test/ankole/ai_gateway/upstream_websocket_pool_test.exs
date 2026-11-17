defmodule Ankole.AIGateway.UpstreamWebSocketPoolTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.ClaudeMessageThreads
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.Observability, as: AIGatewayObservability
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.UpstreamWebSocketPool
  alias Ankole.Observability
  alias AnkoleWeb.AIGatewayResponsesSocket

  defmodule SpanExporter do
    @moduledoc false
    @behaviour :otel_exporter_traces

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def export(spans, resource, test_pid) do
      send(test_pid, {:exported_spans, :otel_otlp_traces.to_proto(spans, resource)})
      :ok
    end

    @impl true
    def shutdown(_test_pid), do: :ok
  end

  defmodule DisabledExporter do
    @moduledoc false
    @behaviour :otel_exporter_traces

    @impl true
    def init(_config), do: :ignore

    @impl true
    def export(_spans, _resource, _state), do: :ok

    @impl true
    def shutdown(_state), do: :ok
  end

  defmodule StatefulWSPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: Map.new(opts)

    def call(%Plug.Conn{method: "GET", request_path: "/v1/responses"} = conn, opts) do
      conn_index = :atomics.add_get(opts.connect_counter, 1, 1)

      WebSockAdapter.upgrade(
        conn,
        Ankole.AIGateway.UpstreamWebSocketPoolTest.StatefulWSHandler,
        %{
          conn_index: conn_index,
          turn_in_conn: 0,
          test_pid: opts.test_pid,
          responder: opts.responder,
          headers: Map.new(conn.req_headers)
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

  defmodule StatefulWSHandler do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state) do
      send(state.test_pid, {:ws_connected, state.conn_index, state.headers})
      {:ok, state}
    end

    @impl true
    def handle_in({payload, [opcode: :text]}, state) do
      decoded = Ankole.JSON.decode!(payload)
      turn = state.turn_in_conn + 1
      next_state = %{state | turn_in_conn: turn}

      send(state.test_pid, {:ws_request, state.conn_index, turn, decoded})

      case state.responder.(state.conn_index, turn, decoded) do
        {:events, events} ->
          frames = Enum.map(events, &{:text, Ankole.JSON.encode!(&1)})
          {:push, frames, next_state}

        :close ->
          {:stop, :normal, next_state}

        {:hold, gate_pid} ->
          send(state.test_pid, {:ws_holding, state.conn_index, self()})
          send(gate_pid, {:ws_handler_waiting, self()})
          {:ok, next_state}
      end
    end

    def handle_in(_other, state), do: {:ok, state}

    @impl true
    def handle_info({:push_events, events}, state) do
      frames = Enum.map(events, &{:text, Ankole.JSON.encode!(&1)})
      {:push, frames, state}
    end

    def handle_info(:close_now, state), do: {:stop, :normal, state}
    def handle_info(_other, state), do: {:ok, state}

    @impl true
    def terminate(reason, state) do
      send(state.test_pid, {:ws_closed, state.conn_index, reason})
      :ok
    end
  end

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok = UpstreamWebSocketPool.reset!()
    :ok = ClaudeMessageThreads.reset!()

    on_exit(fn ->
      :ok = UpstreamWebSocketPool.reset!()
      :ok = ClaudeMessageThreads.reset!()
    end)

    :ok
  end

  test "reuses upstream WebSocket across turns and slices delta input with full top-level fields" do
    %{principal: agent} = agent_fixture()

    {base_url, connect_counter} =
      start_ws_upstream(fn _conn_idx, turn, _req ->
        case turn do
          1 ->
            {:events,
             [
               ws_created("resp_up_1"),
               ws_reasoning_done("rs_1"),
               ws_function_call_done(
                 "fc_1",
                 "call_weather",
                 "lookup_weather",
                 ~s({"city":"Tokyo"})
               ),
               ws_completed("resp_up_1")
             ]}

          2 ->
            {:events,
             [
               ws_created("resp_up_2"),
               ws_message_done("msg_2", "Sunny 22C in Tokyo."),
               ws_completed("resp_up_2")
             ]}
        end
      end)

    configure_ws_provider!(agent.uid, base_url,
      provider_kind: "openai_compatible",
      upstream_websocket_continuation: true
    )

    tools = [
      %{
        "type" => "function",
        "name" => "lookup_weather",
        "description" => "Look up weather",
        "parameters" => %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}
      }
    ]

    turn1_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => String.duplicate("Context block. ", 80)}
        ]
      }
    ]

    turn1_events =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "instructions" => "Always answer concisely.",
          "tools" => tools,
          "input" => turn1_input,
          "stream" => true
        },
        request_context: %{
          "socket_session_id" => "downstream-sock-1",
          "ws_request_header_traceparent" =>
            "00-11111111111111111111111111111111-1111111111111111-01",
          "ws_request_header_x_client_request_id" => "req-turn-1"
        }
      )

    assert :atomics.get(connect_counter, 1) == 1
    assert_receive {:ws_request, 1, 1, req1}
    refute Map.has_key?(req1, "previous_response_id")
    assert length(req1["input"]) == 1
    assert req1["instructions"] == "Always answer concisely."
    assert length(req1["tools"]) == 1

    completed1 = List.last(turn1_events)["response"]
    assert completed1["id"] =~ ~r/^tmp_resp_/
    assert is_nil(completed1["previous_response_id"])

    # Simulate normalized replay history (including stripped non-replay IDs on user/function_call)
    turn2_input =
      turn1_input ++
        [
          %{"id" => "rs_1", "type" => "reasoning", "summary" => []},
          %{
            "type" => "function_call",
            "call_id" => "call_weather",
            "name" => "lookup_weather",
            "arguments" => ~s({"city":"Tokyo"})
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_weather",
            "output" => "22C, clear sky"
          }
        ]

    turn2_events =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "instructions" => "Always answer concisely.",
          "tools" => tools,
          "input" => turn2_input,
          "stream" => true
        },
        request_context: %{
          "socket_session_id" => "downstream-sock-1",
          "ws_request_header_traceparent" =>
            "00-22222222222222222222222222222222-2222222222222222-01",
          "ws_request_header_x_client_request_id" => "req-turn-2"
        }
      )

    # Same physical WebSocket reused despite per-turn traceparent/request-id header rotation!
    assert :atomics.get(connect_counter, 1) == 1
    assert_receive {:ws_request, 1, 2, req2}
    assert req2["previous_response_id"] == "resp_up_1"
    assert req2["instructions"] == "Always answer concisely."
    assert length(req2["tools"]) == 1
    assert req2["store"] == false

    assert [
             %{
               "type" => "function_call_output",
               "call_id" => "call_weather",
               "output" => "22C, clear sky"
             }
           ] = req2["input"]

    completed2 = List.last(turn2_events)["response"]
    assert is_nil(completed2["previous_response_id"])
  end

  test "openai_compatible defaults upstream_websocket_continuation to false while still reusing the socket" do
    %{principal: agent} = agent_fixture()

    {base_url, connect_counter} =
      start_ws_upstream(fn _conn_idx, turn, _req ->
        id = "resp_compat_#{turn}"

        {:events,
         [ws_created(id), ws_message_done("msg_#{turn}", "ok-#{turn}"), ws_completed(id)]}
      end)

    configure_ws_provider!(agent.uid, base_url, provider_kind: "openai_compatible")

    turn1_input = [%{"type" => "message", "role" => "user", "content" => "turn 1"}]

    _events1 =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => turn1_input, "stream" => true},
        request_context: %{"socket_session_id" => "compat-default-sock"}
      )

    turn2_input =
      turn1_input ++
        [
          %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "ok-1"}]
          },
          %{"type" => "message", "role" => "user", "content" => "turn 2"}
        ]

    _events2 =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => turn2_input, "stream" => true},
        request_context: %{"socket_session_id" => "compat-default-sock"}
      )

    assert :atomics.get(connect_counter, 1) == 1
    assert_receive {:ws_request, 1, 1, _req1}
    assert_receive {:ws_request, 1, 2, req2}
    refute Map.has_key?(req2, "previous_response_id")
    assert length(req2["input"]) == 3
  end

  test "stateful store: true websocket streams slice delta input across durable turns" do
    %{principal: agent} = agent_fixture()

    {base_url, connect_counter} =
      start_ws_upstream(fn _conn_idx, turn, _req ->
        id = "resp_stateful_up_#{turn}"

        {:events,
         [ws_created(id), ws_message_done("msg_st_#{turn}", "reply-#{turn}"), ws_completed(id)]}
      end)

    configure_ws_provider!(agent.uid, base_url,
      provider_kind: "openai",
      upstream_websocket_continuation: true
    )

    events1 =
      collect_stateful_ws_turn!(agent.uid, %{
        "model" => "primary",
        "store" => true,
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "first stateful question"}
        ]
      })

    resp1_id = List.last(events1)["response"]["id"]
    assert resp1_id =~ ~r/^resp_/

    _events2 =
      collect_stateful_ws_turn!(agent.uid, %{
        "model" => "primary",
        "store" => true,
        "previous_response_id" => resp1_id,
        "input" => [%{"type" => "message", "role" => "user", "content" => "follow-up question"}]
      })

    assert :atomics.get(connect_counter, 1) == 1
    assert_receive {:ws_request, 1, 1, _req1}
    assert_receive {:ws_request, 1, 2, req2}
    assert req2["previous_response_id"] == "resp_stateful_up_1"
    assert length(req2["input"]) == 1
  end

  test "silently retries on a fresh socket with full input on pre-first-event previous_response_not_found or closed idle socket" do
    %{principal: agent} = agent_fixture()

    {base_url, connect_counter} =
      start_ws_upstream(fn conn_idx, turn, _req ->
        cond do
          conn_idx == 1 and turn == 1 ->
            {:events,
             [
               ws_created("resp_ok_1"),
               ws_message_done("msg_1", "hello"),
               ws_completed("resp_ok_1")
             ]}

          conn_idx == 1 and turn == 2 ->
            {:events,
             [
               %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => "previous_response_not_found",
                   "message" => "Previous response with id 'resp_ok_1' not found."
                 }
               }
             ]}

          conn_idx == 2 and turn == 1 ->
            {:events,
             [
               ws_created("resp_ok_2"),
               ws_message_done("msg_2", "recovered"),
               ws_completed("resp_ok_2")
             ]}

          conn_idx == 2 and turn == 2 ->
            :close

          conn_idx == 3 and turn == 1 ->
            {:events,
             [
               ws_created("resp_ok_3"),
               ws_message_done("msg_3", "reconnected"),
               ws_completed("resp_ok_3")
             ]}
        end
      end)

    configure_ws_provider!(agent.uid, base_url,
      provider_kind: "openai_compatible",
      upstream_websocket_continuation: true
    )

    t1_input = [%{"type" => "message", "role" => "user", "content" => "step 1"}]

    _ =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => t1_input, "stream" => true},
        request_context: %{"socket_session_id" => "fallback-sock"}
      )

    t2_input =
      t1_input ++
        [
          %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "hello"}]
          },
          %{"type" => "message", "role" => "user", "content" => "step 2"}
        ]

    events2 =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => t2_input, "stream" => true},
        request_context: %{"socket_session_id" => "fallback-sock"}
      )

    assert List.last(events2)["type"] == "response.completed"
    assert :atomics.get(connect_counter, 1) == 2
    assert_receive {:ws_request, 1, 2, delta_attempt}
    assert delta_attempt["previous_response_id"] == "resp_ok_1"
    assert length(delta_attempt["input"]) == 1

    assert_receive {:ws_request, 2, 1, full_retry}
    refute Map.has_key?(full_retry, "previous_response_id")
    assert length(full_retry["input"]) == 3

    # Turn 3 hits immediate server close on reused socket #2 and silently recovers on socket #3
    t3_input =
      t2_input ++
        [
          %{
            "id" => "msg_2",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "recovered"}]
          },
          %{"type" => "message", "role" => "user", "content" => "step 3"}
        ]

    events3 =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => t3_input, "stream" => true},
        request_context: %{"socket_session_id" => "fallback-sock"}
      )

    assert List.last(events3)["type"] == "response.completed"
    assert :atomics.get(connect_counter, 1) == 3
    assert_receive {:ws_request, 3, 1, full_retry_3}
    refute Map.has_key?(full_retry_3, "previous_response_id")
    assert length(full_retry_3["input"]) == 5
  end

  test "incomplete responses omit continuation anchors, cancelled streams destroy dirty sockets, and busy leases bypass without blocking" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    {base_url, connect_counter} =
      start_ws_upstream(fn conn_idx, turn, req ->
        mode = List.last(req["input"])["content"]

        cond do
          mode == "incomplete-turn" ->
            {:events, [ws_created("resp_inc"), ws_incomplete("resp_inc")]}

          mode == "hold-turn" ->
            {:hold, test_pid}

          true ->
            id = "resp_#{conn_idx}_#{turn}"

            {:events,
             [ws_created(id), ws_message_done("m_#{conn_idx}_#{turn}", "done"), ws_completed(id)]}
        end
      end)

    configure_ws_provider!(agent.uid, base_url,
      provider_kind: "openai_compatible",
      upstream_websocket_continuation: true
    )

    # 1. Incomplete response reuses clean socket but does NOT build a previous_response_id anchor
    inc_events =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [%{"type" => "message", "role" => "user", "content" => "incomplete-turn"}],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "edge-sock"}
      )

    assert List.last(inc_events)["type"] == "response.incomplete"

    _after_inc =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [
            %{"type" => "message", "role" => "user", "content" => "incomplete-turn"},
            %{"type" => "message", "role" => "user", "content" => "after-incomplete"}
          ],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "edge-sock"}
      )

    assert :atomics.get(connect_counter, 1) == 1
    assert_receive {:ws_request, 1, 2, after_inc_req}
    refute Map.has_key?(after_inc_req, "previous_response_id")

    # 2. Hold socket #1 leased; a concurrent stream on the same scope immediately bypasses onto socket #2
    assert {:ok, held_stream, _meta} =
             AIGateway.open_sse_stream(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hold-turn"}],
                 "stream" => true
               },
               receiver: self(),
               request_context: %{"socket_session_id" => "edge-sock"}
             )

    assert :ok = ResponseStream.read(held_stream, 1)
    assert_receive {:ws_handler_waiting, _handler_pid}, 1_000

    _concurrent =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [%{"type" => "message", "role" => "user", "content" => "concurrent-turn"}],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "edge-sock"}
      )

    assert :atomics.get(connect_counter, 1) == 2

    # 3. Cancel the held stream: Destroy-on-Dirty evicts socket #1 so the next turn connects socket #3
    assert :ok = ResponseStream.cancel(held_stream, "test_cancel")
    assert_receive {:ws_closed, 1, _reason}, 1_000

    _after_cancel =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [%{"type" => "message", "role" => "user", "content" => "post-cancel"}],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "edge-sock"}
      )

    assert :atomics.get(connect_counter, 1) == 3

    # 4. Downstream AIGatewayResponsesSocket.terminate/2 evicts the idle socket
    assert :ok =
             AIGatewayResponsesSocket.terminate(:normal, %{
               tenant_id: Ankole.Repo.tenant_id(),
               subject_uid: agent.uid,
               socket_session_id: "edge-sock",
               active_stream: nil
             })

    assert_receive {:ws_closed, 3, _reason}, 1_000
  end

  test "records continuation_mode, wire request_bytes, and logical_request_bytes on round spans" do
    previous_provider = Observability.provider()

    on_exit(fn ->
      :ok = Observability.put_provider_for_test(previous_provider)
      :ok = Observability.put_runtime_config_for_test(nil)
      :ok = :otel_batch_processor.set_exporter(:global, DisabledExporter, [])
    end)

    enable_span_export!()
    %{principal: agent} = agent_fixture()

    {base_url, _counter} =
      start_ws_upstream(fn _conn_idx, turn, _req ->
        id = "resp_obs_#{turn}"
        {:events, [ws_created(id), ws_message_done("m_obs_#{turn}", "reply"), ws_completed(id)]}
      end)

    configure_ws_provider!(agent.uid, base_url,
      provider_kind: "openai_compatible",
      upstream_websocket_continuation: true
    )

    long_prompt = String.duplicate("Large historical context payload. ", 120)
    t1_input = [%{"type" => "message", "role" => "user", "content" => long_prompt}]

    _ =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => t1_input, "stream" => true},
        request_context: %{"socket_session_id" => "obs-ws-sock"}
      )

    _ = drain_spans()

    t2_input =
      t1_input ++
        [
          %{
            "id" => "m_obs_1",
            "role" => "assistant",
            "content" => "reply"
          },
          %{"type" => "message", "role" => "user", "content" => "tiny delta"}
        ]

    _ =
      collect_sse_turn!(
        agent.uid,
        %{"model" => "primary", "input" => t2_input, "stream" => true},
        request_context: %{"socket_session_id" => "obs-ws-sock"}
      )

    spans = drain_spans()
    round_span = Enum.find(spans, &String.starts_with?(&1.name, "chat "))
    assert round_span.attributes["ankole.ai_gateway.continuation_mode"] == "ws_reused_delta"
    assert is_integer(round_span.attributes["ankole.ai_gateway.request_bytes"])
    assert is_integer(round_span.attributes["ankole.ai_gateway.logical_request_bytes"])

    assert round_span.attributes["ankole.ai_gateway.request_bytes"] <
             round_span.attributes["ankole.ai_gateway.logical_request_bytes"]
  end

  test "rotates pooled sessions at 15m standard max age, 5m xhigh/max age, and 5m idle TTL" do
    %{principal: agent} = agent_fixture()

    spec = %{
      api_resolver: :openai_responses,
      upstream: %{
        kind: :websocket_text,
        url: "wss://api.openai.com/v1/responses",
        headers: [{"authorization", "Bearer sk-test"}],
        transport: %{}
      },
      response_context: %{
        model: "gpt-5.4",
        request: %{"input" => [%{"type" => "message", "role" => "user", "content" => "hi"}]},
        provider_options: %{}
      }
    }

    runtime = %{
      "provider_kind" => "openai",
      "provider_id" => "openai-age-test",
      "credential_id" => "cred-1",
      "subject_uid" => agent.uid,
      "connection_options" => %{"upstream_transport" => "websocket"},
      "request_context" => %{"socket_session_id" => "age-sock"}
    }

    t0 = System.monotonic_time(:millisecond) - 6 * 60_000
    a1 = UpstreamWebSocketPool.prepare_stream_attempt(spec, runtime, now_ms: t0)
    refute a1.reused?
    :ok = UpstreamWebSocketPool.complete_stream_attempt(a1, "completed", "resp_age_1", [])

    # Standard effort (15m max age) still reuses a 6m-old socket whose idle age is 0ms
    a2 = UpstreamWebSocketPool.prepare_stream_attempt(spec, runtime)
    assert a2.reused?
    :ok = UpstreamWebSocketPool.complete_stream_attempt(a2, "completed", "resp_age_2", [])

    # xhigh reasoningEffort caps max reuse age at 5m, rotating the 6m-old socket
    xhigh_spec =
      put_in(spec, [:response_context, :provider_options, "reasoningEffort"], "xhigh")

    a3 = UpstreamWebSocketPool.prepare_stream_attempt(xhigh_spec, runtime)
    refute a3.reused?
    :ok = UpstreamWebSocketPool.complete_stream_attempt(a3, "completed", "resp_age_3", [])

    # Idle >= 5m rotates to a fresh socket
    fresh_after_idle =
      UpstreamWebSocketPool.prepare_stream_attempt(
        spec,
        runtime,
        now_ms: System.monotonic_time(:millisecond) + 5 * 60_000
      )

    refute fresh_after_idle.reused?
    :ok = UpstreamWebSocketPool.abort_stream_attempt(fresh_after_idle)
  end

  defp start_ws_upstream(responder) do
    connect_counter = :atomics.new(1, signed: false)

    server_spec =
      Supervisor.child_spec(
        {Bandit,
         plug:
           {StatefulWSPlug,
            test_pid: self(), connect_counter: connect_counter, responder: responder},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0},
        id: {:ws_upstream, System.unique_integer([:positive])},
        shutdown: 1_000
      )

    server = start_supervised!(server_spec)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}/v1", connect_counter}
  end

  defp configure_ws_provider!(subject_uid, base_url, opts) do
    provider_kind = Keyword.fetch!(opts, :provider_kind)
    provider_id = "ws-pool-#{System.unique_integer([:positive])}"

    connection_options =
      %{"upstream_transport" => "websocket"}
      |> maybe_put_bool("upstream_websocket_continuation", opts[:upstream_websocket_continuation])
      |> maybe_put_compat_options(provider_kind)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: provider_kind,
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Primary", "api_key" => "sk-ws-test"}]
               },
               connection_options: connection_options
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(subject_uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-5.4"
             })

    provider_id
  end

  defp maybe_put_bool(map, _key, nil), do: map
  defp maybe_put_bool(map, key, val) when is_boolean(val), do: Map.put(map, key, val)

  defp maybe_put_compat_options(map, "openai_compatible"),
    do: Map.put(map, "endpoint_kind", "responses")

  defp maybe_put_compat_options(map, _other), do: map

  defp collect_sse_turn!(subject_uid, request, opts) do
    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(
               subject_uid,
               request,
               Keyword.put(opts, :receiver, self())
             )

    drain_response_stream!(stream)
  end

  defp collect_stateful_ws_turn!(subject_uid, request) do
    assert {:ok, stream, _meta} =
             AIGateway.open_websocket_stream(subject_uid, request, receiver: self())

    drain_response_stream!(stream)
  end

  defp drain_response_stream!(stream, acc \\ []) do
    assert :ok = ResponseStream.read(stream, 1)
    ref = stream.ref

    receive do
      {:ai_gateway_response_stream, ^ref, :events, events, {:terminal, _outcome}} ->
        acc ++ events

      {:ai_gateway_response_stream, ^ref, :events, events, :continue} ->
        drain_response_stream!(stream, acc ++ events)
    after
      5_000 ->
        flunk("timed out waiting for response stream events")
    end
  end

  defp ws_created(id) do
    %{
      "type" => "response.created",
      "sequence_number" => 0,
      "response" => %{
        "id" => id,
        "object" => "response",
        "model" => "gpt-5.4",
        "status" => "in_progress",
        "output" => []
      }
    }
  end

  defp ws_reasoning_done(id) do
    %{
      "type" => "response.output_item.done",
      "sequence_number" => 1,
      "output_index" => 0,
      "item" => %{"id" => id, "type" => "reasoning", "summary" => []}
    }
  end

  defp ws_function_call_done(id, call_id, name, arguments) do
    %{
      "type" => "response.output_item.done",
      "sequence_number" => 2,
      "output_index" => 1,
      "item" => %{
        "id" => id,
        "type" => "function_call",
        "call_id" => call_id,
        "name" => name,
        "arguments" => arguments,
        "status" => "completed"
      }
    }
  end

  defp ws_message_done(id, text) do
    %{
      "type" => "response.output_item.done",
      "sequence_number" => 1,
      "output_index" => 0,
      "item" => %{
        "id" => id,
        "type" => "message",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    }
  end

  defp ws_completed(id) do
    %{
      "type" => "response.completed",
      "sequence_number" => 3,
      "response" => %{
        "id" => id,
        "object" => "response",
        "model" => "gpt-5.4",
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }
    }
  end

  defp ws_incomplete(id) do
    %{
      "type" => "response.incomplete",
      "sequence_number" => 1,
      "response" => %{
        "id" => id,
        "object" => "response",
        "model" => "gpt-5.4",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "output" => [],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }
    }
  end

  defp enable_span_export! do
    :ok = :otel_batch_processor.set_exporter(:global, SpanExporter, self())
    :ok = Observability.put_provider_for_test(Ankole.Observability.Providers.Langfuse)

    :ok =
      Observability.put_runtime_config_for_test(%{
        enabled: true,
        provider: "langfuse",
        endpoint: "http://127.0.0.1:4318/v1/traces",
        headers: []
      })

    _ = AIGatewayObservability
    :ok
  end

  defp drain_spans do
    _ = :otel_batch_processor.force_flush(%{reg_name: :otel_batch_processor_global})
    collect_exported_spans([])
  end

  defp collect_exported_spans(acc) do
    receive do
      {:exported_spans, %{resource_spans: resource_spans}} ->
        decoded =
          for %{scope_spans: scope_spans} <- resource_spans,
              %{spans: spans} <- scope_spans,
              span <- spans do
            %{
              name: IO.iodata_to_binary(span.name),
              attributes: decode_otel_attrs(span.attributes)
            }
          end

        collect_exported_spans(acc ++ decoded)
    after
      50 -> acc
    end
  end

  defp decode_otel_attrs(attrs) do
    Map.new(attrs, fn %{key: key, value: %{value: {_kind, raw}}} ->
      val = if is_list(raw), do: IO.iodata_to_binary(raw), else: raw
      {IO.iodata_to_binary(key), val}
    end)
  end
end
