defmodule Ankole.AIGateway.ClaudeMessageThreadsTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.ClaudeMessageThreads
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.UpstreamWebSocketPool
  alias Ankole.Observability

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

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok = ClaudeMessageThreads.reset!()
    :ok = UpstreamWebSocketPool.reset!()

    on_exit(fn ->
      :ok = ClaudeMessageThreads.reset!()
      :ok = UpstreamWebSocketPool.reset!()
    end)

    :ok
  end

  test "creates and continues Claude Message Threads across single_request and response_stream" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    call_counter = :atomics.new(1, signed: false)

    base_url =
      start_upstream_server(fn req ->
        n = :atomics.add_get(call_counter, 1, 1)
        send(test_pid, {:claude_req, n, req})

        case n do
          1 ->
            {:json, 200, anthropic_tool_use_body("msg_t1", "call_1", "read_doc", %{"id" => "d1"})}

          2 ->
            {:json, 200, anthropic_text_body("msg_t2", "Document summary.")}

          3 ->
            {:raw, 200, "text/event-stream",
             anthropic_sse(anthropic_text_stream_events("msg_s1", "Streamed turn 1."))}

          4 ->
            {:raw, 200, "text/event-stream",
             anthropic_sse(anthropic_text_stream_events("msg_s2", "Streamed turn 2."))}
        end
      end)

    configure_claude_provider!(agent.uid, base_url, message_threads: "enabled")

    tools = [
      %{
        "type" => "function",
        "name" => "read_doc",
        "description" => "Read document",
        "parameters" => %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
      }
    ]

    # 1. Non-streaming (:single_request) Turn 1 -> Turn 2
    t1_input = [%{"type" => "message", "role" => "user", "content" => "Summarize d1"}]

    assert {:ok, %{body: body1}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "instructions" => "Be concise.",
                 "tools" => tools,
                 "input" => t1_input,
                 "metadata" => %{"session_id" => "claude-nonstream-sess"}
               }
             )

    assert_receive {:claude_req, 1, req1}
    assert req1.headers["anthropic-beta"] =~ "message-threads-2026-08-12"
    assert req1.body["thread"] == %{"type" => "create"}
    assert is_list(req1.body["tools"])
    assert not is_nil(req1.body["system"])

    t2_input =
      t1_input ++
        body1["output"] ++
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_1",
            "output" => "Quarterly revenue grew 40%."
          }
        ]

    assert {:ok, %{body: body2}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "instructions" => "Be concise.",
                 "tools" => tools,
                 "input" => t2_input,
                 "metadata" => %{"session_id" => "claude-nonstream-sess"}
               }
             )

    assert get_in(body2, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "Document summary."

    assert_receive {:claude_req, 2, req2}
    assert req2.headers["anthropic-beta"] =~ "message-threads-2026-08-12"
    assert req2.body["thread"] == %{"type" => "continue", "previous_message_id" => "msg_t1"}
    refute Map.has_key?(req2.body, "system")
    refute Map.has_key?(req2.body, "tools")
    assert length(req2.body["messages"]) == 1
    assert hd(req2.body["messages"])["role"] == "user"

    # 2. Streaming (:response_stream) Turn 1 -> Turn 2
    s1_input = [%{"type" => "message", "role" => "user", "content" => "Hello stream"}]

    s1_events =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "instructions" => "Stream system.",
          "tools" => tools,
          "input" => s1_input,
          "stream" => true
        },
        request_context: %{"socket_session_id" => "claude-stream-sess"}
      )

    s1_completed = List.last(s1_events)["response"]

    s2_input =
      s1_input ++
        s1_completed["output"] ++
        [%{"type" => "message", "role" => "user", "content" => "Follow-up stream"}]

    _s2_events =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "instructions" => "Stream system.",
          "tools" => tools,
          "input" => s2_input,
          "stream" => true
        },
        request_context: %{"socket_session_id" => "claude-stream-sess"}
      )

    assert_receive {:claude_req, 3, req3}
    assert req3.body["thread"] == %{"type" => "create"}

    assert_receive {:claude_req, 4, req4}
    assert req4.body["thread"] == %{"type" => "continue", "previous_message_id" => "msg_s1"}
    refute Map.has_key?(req4.body, "system")
    refute Map.has_key?(req4.body, "tools")
    assert length(req4.body["messages"]) == 1
  end

  test "message_threads auto leaves custom base_url relays unthreaded while structural_fingerprint tracks official fixed fields" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    auto_url =
      start_upstream_server(fn req ->
        send(test_pid, {:auto_relay_req, req})
        {:json, 200, anthropic_text_body("msg_auto_1", "relay ok")}
      end)

    configure_claude_provider!(agent.uid, auto_url, message_threads: "auto")

    assert {:ok, _res} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [%{"type" => "message", "role" => "user", "content" => "hi"}],
               "metadata" => %{"session_id" => "auto-relay-sess"}
             })

    assert_receive {:auto_relay_req, relay_req}
    refute Map.has_key?(relay_req.body, "thread")
    refute (relay_req.headers["anthropic-beta"] || "") =~ "message-threads-2026-08-12"

    # Even with message_threads: "enabled", a bare prompt_cache_key without a conversation/session
    # identity must remain unthreaded so shared cache buckets never cross-link threads.
    configure_claude_provider!(agent.uid, auto_url, message_threads: "enabled")

    assert {:ok, _res} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [%{"type" => "message", "role" => "user", "content" => "shared bucket"}],
               "prompt_cache_key" => "shared-cache-bucket-only"
             })

    assert_receive {:auto_relay_req, cache_only_req}
    refute Map.has_key?(cache_only_req.body, "thread")

    # Verify structural_fingerprint ignores mcp_servers authorization_token rotation
    # while detecting container.skills, context_management, and fallbacks presence changes
    base_spec = %{
      response_context: %{model: "claude-sonnet-4-6", provider_options: %{}},
      upstream: %{headers: [{"anthropic-version", "2023-06-01"}]}
    }

    req_token_a = %{
      "instructions" => "sys",
      "mcp_servers" => [
        %{"name" => "docs", "url" => "https://mcp.test", "authorization_token" => "tok-a"}
      ],
      "container" => %{"skills" => [%{"skill_id" => "pdf"}]}
    }

    req_token_b =
      put_in(req_token_a, ["mcp_servers", Access.at(0), "authorization_token"], "tok-b")

    assert ClaudeMessageThreads.structural_fingerprint(base_spec, req_token_a) ==
             ClaudeMessageThreads.structural_fingerprint(base_spec, req_token_b)

    req_skill_changed =
      put_in(req_token_a, ["container", "skills"], [%{"skill_id" => "xlsx"}])

    refute ClaudeMessageThreads.structural_fingerprint(base_spec, req_token_a) ==
             ClaudeMessageThreads.structural_fingerprint(base_spec, req_skill_changed)

    req_with_fallbacks = Map.put(req_token_a, "fallbacks", ["claude-haiku-4-5"])

    refute ClaudeMessageThreads.structural_fingerprint(base_spec, req_token_a) ==
             ClaudeMessageThreads.structural_fingerprint(base_spec, req_with_fallbacks)

    # Pre-flight bypass on manual block cache_control
    runtime = %{
      "provider_kind" => "claude",
      "subject_uid" => agent.uid,
      "provider_id" => "claude-pf",
      "connection_options" => %{"message_threads" => "enabled"},
      "request_context" => %{"socket_session_id" => "pf-1"}
    }

    manual_cc_req = %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "hi", "cache_control" => %{"type" => "ephemeral"}}
          ]
        }
      ]
    }

    decorated =
      ClaudeMessageThreads.decorate_spec(
        %{api_resolver: :anthropic_messages, response_context: %{request: manual_cc_req}},
        runtime,
        manual_cc_req
      )

    assert is_nil(ClaudeMessageThreads.get_attempt(decorated))
  end

  test "recovers official thread_not_found, continue_unthreaded, thread_unsupported_request, and fallback_message without penalizing credentials" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    step = :atomics.new(1, signed: false)

    base_url =
      start_upstream_server(fn req ->
        n = :atomics.add_get(step, 1, 1)
        send(test_pid, {:recovery_req, n, req})

        case n do
          # Turn 1: create succeeds
          1 ->
            {:json, 200, anthropic_text_body("msg_r1", "turn 1")}

          # Turn 2 attempt 1: continue gets 404 thread_not_found -> replays full create (attempt 2)
          2 ->
            {:json, 404,
             %{
               "type" => "error",
               "error" => %{
                 "type" => "not_found_error",
                 "message" => "Thread not found",
                 "details" => %{"error_code" => "thread_not_found"}
               }
             }}

          3 ->
            {:json, 200, anthropic_text_body("msg_r2_recreated", "turn 2 recreated")}

          # Turn 3 attempt 1: immediate post-replay continue STILL gets 404 thread_not_found -> continue_unthreaded!
          4 ->
            {:json, 404,
             %{
               "type" => "error",
               "error" => %{
                 "type" => "not_found_error",
                 "message" => "Thread not found again",
                 "details" => %{"error_code" => "thread_not_found"}
               }
             }}

          5 ->
            {:json, 200, anthropic_text_body("msg_r3_unthreaded", "turn 3 unthreaded")}

          # Plain model 404 on another session must NOT replay!
          6 ->
            {:json, 404,
             %{
               "type" => "error",
               "error" => %{
                 "type" => "not_found_error",
                 "message" => "model: claude-missing not found"
               }
             }}
        end
      end)

    configure_claude_provider!(agent.uid, base_url, message_threads: "enabled")

    i1 = [%{"type" => "message", "role" => "user", "content" => "q1"}]

    assert {:ok, %{body: b1}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "instructions" => "sys",
               "input" => i1,
               "metadata" => %{"session_id" => "rec-sess"}
             })

    i2 = i1 ++ b1["output"] ++ [%{"type" => "message", "role" => "user", "content" => "q2"}]

    assert {:ok, %{body: b2}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "instructions" => "sys",
               "input" => i2,
               "metadata" => %{"session_id" => "rec-sess"}
             })

    assert_receive {:recovery_req, 2, attempt_continue}
    assert attempt_continue.body["thread"]["type"] == "continue"
    assert_receive {:recovery_req, 3, replayed_create}
    assert replayed_create.body["thread"] == %{"type" => "create"}
    assert length(replayed_create.body["messages"]) == 3

    i3 = i2 ++ b2["output"] ++ [%{"type" => "message", "role" => "user", "content" => "q3"}]

    assert {:ok, %{body: _b3}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "instructions" => "sys",
               "input" => i3,
               "metadata" => %{"session_id" => "rec-sess"}
             })

    assert_receive {:recovery_req, 4, second_404_continue}
    assert second_404_continue.body["thread"]["type"] == "continue"
    assert_receive {:recovery_req, 5, unthreaded_fallback}
    refute Map.has_key?(unthreaded_fallback.body, "thread")
    refute (unthreaded_fallback.headers["anthropic-beta"] || "") =~ "message-threads-2026-08-12"

    # Plain model 404 fails immediately without replaying
    assert {:error, _reason} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [%{"type" => "message", "role" => "user", "content" => "plain-404"}],
               "metadata" => %{"session_id" => "plain-404-sess"}
             })

    assert :atomics.get(step, 1) == 6
  end

  test "recovers thread_unsupported_request on stream with negative cache and skips anchor on fallback_message" do
    previous_provider = Observability.provider()

    on_exit(fn ->
      :ok = Observability.put_provider_for_test(previous_provider)
      :ok = Observability.put_runtime_config_for_test(nil)
      :ok = :otel_batch_processor.set_exporter(:global, DisabledExporter, [])
    end)

    enable_span_export!()
    %{principal: agent} = agent_fixture()
    test_pid = self()
    unsup_counter = :atomics.new(1, signed: false)

    unsup_url =
      start_upstream_server(fn req ->
        n = :atomics.add_get(unsup_counter, 1, 1)
        send(test_pid, {:unsup_req, n, req})

        if n == 1 do
          {:json, 400,
           %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "Message threads are not supported for HIPAA organizations",
               "details" => %{"error_code" => "thread_unsupported_request", "reason" => "hipaa"}
             }
           }}
        else
          {:raw, 200, "text/event-stream",
           anthropic_sse(anthropic_text_stream_events("msg_u#{n}", "ok-#{n}"))}
        end
      end)

    configure_claude_provider!(agent.uid, unsup_url, message_threads: "enabled")

    events1 =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [%{"type" => "message", "role" => "user", "content" => "hipaa turn 1"}],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "hipaa-sock"}
      )

    assert List.last(events1)["type"] == "response.completed"
    assert_receive {:unsup_req, 1, hipaa_first}
    assert hipaa_first.body["thread"] == %{"type" => "create"}
    assert_receive {:unsup_req, 2, hipaa_retry}
    refute Map.has_key?(hipaa_retry.body, "thread")
    refute (hipaa_retry.headers["anthropic-beta"] || "") =~ "message-threads-2026-08-12"

    spans = drain_spans()
    round_span = Enum.find(spans, &String.starts_with?(&1.name, "chat "))
    assert round_span.attributes["ankole.ai_gateway.continuation_mode"] == "stateless_full"

    assert round_span.attributes["ankole.ai_gateway.continuation_fallback_reason"] ==
             "thread_unsupported_request"

    refute "ankole.ai_gateway.credential_retry" in round_span.events

    # Negative cache prevents Turn 2 from even attempting `thread`!
    _events2 =
      collect_sse_turn!(
        agent.uid,
        %{
          "model" => "primary",
          "input" => [%{"type" => "message", "role" => "user", "content" => "hipaa turn 2"}],
          "stream" => true
        },
        request_context: %{"socket_session_id" => "hipaa-sock"}
      )

    assert_receive {:unsup_req, 3, hipaa_second_turn}
    refute Map.has_key?(hipaa_second_turn.body, "thread")

    # Separate provider: usage.iterations with fallback_message skips anchor so Turn 2 sends create
    fb_counter = :atomics.new(1, signed: false)

    fb_url =
      start_upstream_server(fn req ->
        n = :atomics.add_get(fb_counter, 1, 1)
        send(test_pid, {:fb_req, n, req})

        body =
          if n == 1 do
            put_in(
              anthropic_text_body("msg_fb_1", "from fallback model"),
              ["usage", "iterations"],
              [%{"type" => "fallback_message", "input_tokens" => 8, "output_tokens" => 4}]
            )
          else
            anthropic_text_body("msg_fb_2", "turn 2 fresh create")
          end

        {:json, 200, body}
      end)

    configure_claude_provider!(agent.uid, fb_url, message_threads: "enabled")

    fb_i1 = [%{"type" => "message", "role" => "user", "content" => "fb 1"}]

    assert {:ok, %{body: fb_b1}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => fb_i1,
               "metadata" => %{"session_id" => "fb-sess"}
             })

    refute Map.has_key?(fb_b1["usage"] || %{}, "iterations")

    fb_i2 =
      fb_i1 ++ fb_b1["output"] ++ [%{"type" => "message", "role" => "user", "content" => "fb 2"}]

    assert {:ok, _} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => fb_i2,
               "metadata" => %{"session_id" => "fb-sess"}
             })

    assert_receive {:fb_req, 1, fb1}
    assert fb1.body["thread"] == %{"type" => "create"}
    assert_receive {:fb_req, 2, fb2}
    assert fb2.body["thread"] == %{"type" => "create"}
  end

  defp configure_claude_provider!(subject_uid, base_url, opts) do
    provider_id = "claude-threads-#{System.unique_integer([:positive])}"
    message_threads = Keyword.get(opts, :message_threads, "auto")

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "claude",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Primary", "api_key" => "sk-ant-test"}]
               },
               connection_options: %{
                 "message_threads" => message_threads
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(subject_uid, "primary", %{
               provider_id: provider_id,
               model: "claude-sonnet-4-6"
             })

    provider_id
  end

  defp collect_sse_turn!(subject_uid, request, opts) do
    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(
               subject_uid,
               request,
               Keyword.put(opts, :receiver, self())
             )

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
        flunk("timed out waiting for Claude response stream")
    end
  end

  defp anthropic_text_body(id, text) do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-6",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 12, "output_tokens" => 6}
    }
  end

  defp anthropic_tool_use_body(id, call_id, name, input) do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-6",
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "tool_use", "id" => call_id, "name" => name, "input" => input}
      ],
      "usage" => %{"input_tokens" => 15, "output_tokens" => 8}
    }
  end

  defp anthropic_text_stream_events(id, text) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [],
          "stop_reason" => nil,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 5}
      },
      %{"type" => "message_stop"}
    ]
  end

  defp anthropic_sse(events) do
    Enum.map_join(events, "", fn event ->
      "event: #{event["type"]}\ndata: #{Ankole.JSON.encode!(event)}\n\n"
    end)
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
              attributes: decode_otel_attrs(span.attributes),
              events: Enum.map(span.events, &IO.iodata_to_binary(&1.name))
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
