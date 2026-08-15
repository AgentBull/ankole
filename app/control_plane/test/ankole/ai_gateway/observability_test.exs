defmodule Ankole.AIGateway.ObservabilityTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.Observability, as: AIGatewayObservability
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Observability
  alias Ankole.SignalsGateway.ActorEvent

  defmodule Exporter do
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

  defmodule OTLPReceiver do
    @moduledoc false

    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)

      send(test_pid, {
        :otlp_request,
        conn.method,
        conn.request_path,
        Map.new(conn.req_headers),
        body
      })

      send_resp(conn, 200, "")
    end
  end

  setup do
    allow_cache_database_access()
    clear_app_configure()
    previous_provider = Observability.provider()
    previous_otlp_environment = otlp_environment()

    on_exit(fn ->
      :ok = Observability.put_provider_for_test(previous_provider)
      :ok = Observability.put_runtime_config_for_test(nil)
      :ok = :otel_batch_processor.set_exporter(:global, DisabledExporter, [])
      restore_environment(previous_otlp_environment)
      clear_app_configure()
    end)

    :ok
  end

  test "one response contains a generation with content, model, usage, and redaction" do
    enable_export(self(), "langfuse")

    observation =
      AIGatewayObservability.start_response(
        "principal-1",
        %{
          "input" => [%{"role" => "user", "content" => "hello"}],
          "metadata" => %{"actor_event_id" => "event-1"}
        },
        stateful: %{conversation_id: "conversation-1"}
      )

    assert %AIGatewayObservability{} = observation

    observation =
      AIGatewayObservability.start_round(
        observation,
        %{runtime: %{"provider_kind" => "openai"}},
        %{
          api_resolver: :openai_responses,
          upstream: %{url: "https://api.openai.com/v1/responses"},
          response_context: %{
            model: "gpt-test",
            stream: false,
            request: %{
              "input" => [%{"role" => "user", "content" => "hello"}],
              "api_key" => "must-not-leave",
              "image_url" => "data:image/png;base64,secret"
            }
          }
        }
      )

    observation =
      AIGatewayObservability.observe_output(observation, %{
        "type" => "response.output_text.delta"
      })

    provider_response = %{
      body: %{
        "id" => "resp-provider",
        "model" => "gpt-test-2026",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "world"}],
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, provider_response)
    _observation = AIGatewayObservability.finish_response(observation, provider_response)

    spans = exported_spans()
    response = span!(spans, "ai_gateway.response")
    generation = span!(spans, "chat gpt-test")

    assert response.trace_id == generation.trace_id
    assert generation.parent_span_id == response.span_id
    assert response.attributes["user.id"] == "principal:principal-1"
    assert response.attributes["ankole.principal.uid"] == "principal-1"
    assert response.attributes["session.id"] == "conversation-1"
    assert response.attributes["langfuse.observation.type"] == "span"
    refute Map.has_key?(response.attributes, "langsmith.trace.name")
    assert generation.attributes["user.id"] == "principal:principal-1"
    assert generation.attributes["ankole.principal.uid"] == "principal-1"
    assert generation.attributes["session.id"] == "conversation-1"
    assert generation.attributes["langfuse.observation.type"] == "generation"
    refute Map.has_key?(generation.attributes, "langsmith.span.kind")
    assert generation.attributes["gen_ai.provider.name"] == "openai"
    assert generation.attributes["gen_ai.request.model"] == "gpt-test"
    assert generation.attributes["gen_ai.response.model"] == "gpt-test-2026"
    assert generation.attributes["gen_ai.usage.input_tokens"] == 3
    assert generation.attributes["gen_ai.usage.output_tokens"] == 2
    assert generation.attributes["gen_ai.usage.total_tokens"] == 5
    assert is_float(generation.attributes["gen_ai.response.time_to_first_chunk"])
    assert generation.status == :ok

    input = generation.attributes["langfuse.observation.input"]
    assert input =~ "hello"
    refute input =~ "must-not-leave"
    refute input =~ "base64,secret"
    assert input =~ "inline_data"
    assert generation.attributes["ankole.ai_gateway.input"] == input
    assert generation.attributes["ankole.ai_gateway.output"] =~ "world"
    refute Map.has_key?(generation.attributes, "gen_ai.prompt")
    refute Map.has_key?(generation.attributes, "gen_ai.completion")
  end

  test "one turn root parents AIGateway responses and carries sanitized trace input and output" do
    enable_export(self(), "langfuse")

    actor_event = %ActorEvent{
      id: "01915f9d-5f00-7000-8000-000000000001",
      agent_uid: "agent-turn",
      session_id: "job:1000",
      type: "background_agent_job.dispatch",
      payload: %{"data" => %{"task" => "investigate", "api_key" => "must-not-leave"}}
    }

    %{traceparent: traceparent, user_id: nil} =
      Observability.start_turn(actor_event, %{
        request_context: %{"job_id" => 1000, "attempts" => 2}
      })

    observation =
      AIGatewayObservability.start_response(
        actor_event.agent_uid,
        %{"input" => "hello"},
        request_context: %{
          "headers" => %{"traceparent" => traceparent},
          "observability_user_id" => nil
        },
        stateful: %{conversation_id: actor_event.session_id},
        subject_type: "agent"
      )

    observation =
      AIGatewayObservability.start_round(
        observation,
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-no-user", request: %{"input" => "hello"}}}
      )

    provider_response = %{
      body: %{
        "model" => "gpt-no-user",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "done"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, provider_response)
    _observation = AIGatewayObservability.finish_response(observation, provider_response)

    assert :ok = Observability.finish_turn(actor_event.id, output: "final reply")

    spans = exported_spans()
    root = span!(spans, "turn background_agent_job.dispatch")
    response = span!(spans, "ai_gateway.response")
    generation = span!(spans, "chat gpt-no-user")

    assert response.trace_id == root.trace_id
    assert generation.trace_id == root.trace_id
    assert response.parent_span_id == root.span_id
    assert generation.parent_span_id == response.span_id
    assert root.attributes["langfuse.observation.type"] == "agent"

    Enum.each([root, response, generation], fn span ->
      refute Map.has_key?(span.attributes, "user.id")
      assert span.attributes["session.id"] == actor_event.session_id
      assert span.attributes["ankole.principal.uid"] == actor_event.agent_uid
      assert span.attributes["ankole.principal.type"] == "agent"
    end)

    assert root.attributes["ankole.background_agent_job.id"] == 1000
    assert root.attributes["ankole.background_agent_job.attempts"] == 2
    assert root.attributes["langfuse.observation.input"] =~ "investigate"
    refute root.attributes["langfuse.observation.input"] =~ "must-not-leave"
    assert root.attributes["langfuse.observation.output"] =~ "final reply"
    assert root.status == :ok
  end

  test "an invalid traceparent keeps the AIGateway response as a root" do
    enable_export(self(), "opentelemetry")

    observation =
      AIGatewayObservability.start_response(
        "agent-invalid-parent",
        %{"input" => "hello"},
        request_context: %{
          "headers" => %{"traceparent" => "invalid"},
          "observability_user_id" => "channel:forged"
        },
        subject_type: "agent"
      )

    _observation =
      AIGatewayObservability.finish_response(observation, %{"status" => "completed"})

    response = exported_spans() |> span!("ai_gateway.response")
    assert response.parent_span_id == <<>>
    assert response.attributes["user.id"] == "principal:agent-invalid-parent"
    assert response.attributes["ankole.principal.uid"] == "agent-invalid-parent"
  end

  test "a malformed carrier with a valid parent uses the authenticated subject fallback" do
    enable_export(self(), "opentelemetry")

    traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

    observation =
      AIGatewayObservability.start_response(
        "agent-malformed-carrier",
        %{"input" => "hello"},
        request_context: %{
          "headers" => %{"traceparent" => traceparent},
          "observability_user_id" => "agent-malformed-carrier"
        },
        subject_type: "agent"
      )

    _observation =
      AIGatewayObservability.finish_response(observation, %{"status" => "completed"})

    response = exported_spans() |> span!("ai_gateway.response")
    refute response.parent_span_id == <<>>
    assert response.attributes["user.id"] == "principal:agent-malformed-carrier"
    assert response.attributes["ankole.principal.uid"] == "agent-malformed-carrier"
  end

  test "a non-Agent subject cannot replace its authenticated user with a carried identity" do
    enable_export(self(), "opentelemetry")

    traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

    observation =
      AIGatewayObservability.start_response(
        "admin-1",
        %{"input" => "hello"},
        request_context: %{
          "headers" => %{"traceparent" => traceparent},
          "observability_user_id" => "channel:forged"
        },
        stateful: %{conversation_id: "conversation-admin"},
        subject_type: "admin_human"
      )
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-admin", request: %{"input" => "hello"}}}
      )

    provider_response = %{
      body: %{
        "model" => "gpt-admin",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "done"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, provider_response)
    _observation = AIGatewayObservability.finish_response(observation, provider_response)

    spans = exported_spans()

    Enum.each([span!(spans, "ai_gateway.response"), span!(spans, "chat gpt-admin")], fn span ->
      assert span.attributes["user.id"] == "principal:admin-1"
      assert span.attributes["ankole.principal.uid"] == "admin-1"
      assert span.attributes["ankole.principal.type"] == "admin_human"
      assert span.attributes["session.id"] == "conversation-admin"
    end)
  end

  test "turn identity maps direct messages to humans and group or event triggers to channels" do
    enable_export(self(), "langfuse")

    cases = [
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000011",
         agent_uid: "agent-dm",
         session_id: "session-dm",
         type: "im.message.addressed",
         source_event_id: "source-dm",
         signal_channel_id: "mock:chat:dm",
         payload: %{"data" => %{"channel" => %{"kind" => "im_dm"}}}
       }, "human-dm", "principal:human-dm"},
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000012",
         agent_uid: "agent-group",
         session_id: "session-group",
         type: "im.message.addressed",
         source_event_id: "source-group",
         signal_channel_id: "mock:chat:group",
         payload: %{"data" => %{"channel" => %{"kind" => "im_group"}}}
       }, "human-group", "channel:mock:chat:group"},
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000013",
         agent_uid: "agent-action",
         session_id: "session-action",
         type: "signal.action.invoked",
         source_event_id: "source-action",
         signal_channel_id: "mock:chat:action",
         payload: %{"data" => %{"channel" => %{"kind" => "im_dm"}}}
       }, "human-action", "channel:mock:chat:action"},
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000014",
         agent_uid: "agent-retry",
         session_id: "session-retry",
         type: "im.message.addressed",
         source_event_id: "retry:source-group",
         signal_channel_id: "mock:chat:retry",
         payload: %{"data" => %{"channel" => %{"kind" => "im_dm"}, "entry" => %{}}}
       }, "human-retry", "channel:mock:chat:retry"},
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000015",
         agent_uid: "agent-no-channel",
         session_id: "session-no-channel",
         type: "command.new",
         source_event_id: "source-no-channel",
         signal_channel_id: nil,
         payload: %{"data" => %{}}
       }, "human-no-channel", "principal:human-no-channel"},
      {%ActorEvent{
         id: "01915f9d-5f00-7000-8000-000000000016",
         agent_uid: "agent-scheduled",
         session_id: "session-scheduled",
         type: "cron.fire",
         source_event_id: "source-scheduled",
         signal_channel_id: "mock:chat:scheduled",
         payload: %{"data" => %{}}
       }, nil, "channel:mock:chat:scheduled"}
    ]

    Enum.each(cases, fn {actor_event, human_uid, expected_user_id} ->
      assert_turn_identity(actor_event, human_uid, expected_user_id)
    end)
  end

  test "LangSmith provider owns its compatibility attributes" do
    enable_export(self(), "langsmith")

    observation =
      AIGatewayObservability.start_response(
        "principal-langsmith",
        %{"input" => "hello"},
        stateful: %{conversation_id: "conversation-langsmith"}
      )
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-test", request: %{"input" => "hello"}}}
      )

    response = %{
      body: %{
        "model" => "gpt-test",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "world"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, response)
    _observation = AIGatewayObservability.finish_response(observation, response)

    spans = exported_spans()
    root = span!(spans, "ai_gateway.response")
    generation = span!(spans, "chat gpt-test")

    assert root.attributes["langsmith.span.kind"] == "chain"
    assert root.attributes["langsmith.metadata.user_id"] == "principal:principal-langsmith"
    assert root.attributes["langsmith.trace.session_id"] == "conversation-langsmith"
    assert generation.attributes["langsmith.span.kind"] == "llm"
    assert generation.attributes["langsmith.trace.session_id"] == "conversation-langsmith"
    assert generation.attributes["gen_ai.system"] == "openai"
    assert generation.attributes["gen_ai.prompt"] =~ "hello"
    assert generation.attributes["gen_ai.completion"] =~ "world"
    refute Enum.any?(Map.keys(generation.attributes), &String.starts_with?(&1, "langfuse."))
  end

  test "OpenTelemetry provider emits no vendor compatibility attributes" do
    enable_export(self(), "opentelemetry")

    observation =
      "principal-otel"
      |> AIGatewayObservability.start_response(%{"input" => "hello"})
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-test", request: %{"input" => "hello"}}}
      )

    response = %{
      body: %{
        "model" => "gpt-test",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "world"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, response)
    _observation = AIGatewayObservability.finish_response(observation, response)

    spans = exported_spans()
    generation = span!(spans, "chat gpt-test")

    assert generation.attributes["gen_ai.provider.name"] == "openai"
    assert generation.attributes["gen_ai.request.model"] == "gpt-test"
    assert generation.attributes["ankole.ai_gateway.input"] =~ "hello"
    assert generation.attributes["ankole.ai_gateway.output"] =~ "world"

    refute Enum.any?(Map.keys(generation.attributes), fn key ->
             String.starts_with?(key, "langfuse.") or String.starts_with?(key, "langsmith.")
           end)
  end

  test "provider failure ends both spans as errors without recording raw error text" do
    enable_export(self(), "langfuse")

    observation =
      "principal-2"
      |> AIGatewayObservability.start_response(%{"input" => "hello"})
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-test", request: %{"input" => "hello"}}}
      )

    assert %AIGatewayObservability{} = observation

    observation =
      AIGatewayObservability.fail_round(
        observation,
        {:universal_ai_request_failed,
         %{"code" => "rate_limit_exceeded", "message" => "secret provider text"}}
      )

    _observation =
      AIGatewayObservability.finish_response(
        observation,
        {:error,
         {:universal_ai_request_failed,
          %{"code" => "rate_limit_exceeded", "message" => "secret provider text"}}}
      )

    spans = exported_spans()
    response = span!(spans, "ai_gateway.response")
    generation = span!(spans, "chat gpt-test")

    assert response.status == :error
    assert generation.status == :error
    assert response.attributes["error.type"] == "rate_limit_exceeded"
    assert generation.attributes["error.type"] == "rate_limit_exceeded"
    refute inspect(spans) =~ "secret provider text"
  end

  test "codex session headers give a trace its session, client, and release facts" do
    enable_export(self(), "langfuse")
    System.put_env("ANKOLE_VERSION", "26.7.99")
    on_exit(fn -> System.delete_env("ANKOLE_VERSION") end)

    request_context = %{
      "downstream_transport" => "http",
      "headers" => %{
        "session_id" => "codex-thread-1",
        "originator" => "codex_cli_rs",
        "user-agent" => "codex_cli_rs/0.55.0",
        "version" => "0.55.0"
      }
    }

    observation =
      AIGatewayObservability.start_response(
        "agent-principal",
        %{"input" => "hello"},
        request_context: request_context,
        subject_type: "agent"
      )

    _observation = AIGatewayObservability.finish_response(observation, %{"status" => "completed"})

    spans = exported_spans()
    response = span!(spans, "ai_gateway.response")

    assert response.attributes["session.id"] == "codex-thread-1"
    assert response.attributes["gen_ai.conversation.id"] == "codex-thread-1"
    assert response.attributes["ankole.principal.type"] == "agent"
    assert response.attributes["ankole.principal.uid"] == "agent-principal"
    assert response.attributes["user.id"] == "principal:agent-principal"
    assert response.attributes["ankole.ai_gateway.originator"] == "codex_cli_rs"
    assert response.attributes["user_agent.original"] == "codex_cli_rs/0.55.0"
    assert response.attributes["ankole.ai_gateway.client_version"] == "0.55.0"
    assert response.attributes["langfuse.trace.metadata.principal_type"] == "agent"
    assert response.attributes["langfuse.trace.metadata.originator"] == "codex_cli_rs"
    assert response.attributes["langfuse.release"] == "26.7.99"
  end

  test "an internal caller labels its trace" do
    enable_export(self(), "langfuse")

    observation =
      AIGatewayObservability.start_response(
        "agent-1",
        %{"input" => "hi"},
        caller: "brain.dreaming.stage_a"
      )

    _observation = AIGatewayObservability.finish_response(observation, %{"status" => "completed"})

    spans = exported_spans()
    response = span!(spans, "ai_gateway.response")

    assert response.attributes["ankole.ai_gateway.caller"] == "brain.dreaming.stage_a"
    assert response.attributes["langfuse.trace.metadata.caller"] == "brain.dreaming.stage_a"
  end

  test "usage attributes keep cache read, cache write, and reasoning buckets" do
    enable_export(self(), "opentelemetry")

    observation =
      "principal-cache"
      |> AIGatewayObservability.start_response(%{"input" => "hello"})
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "claude"}},
        %{response_context: %{model: "claude-test", request: %{"input" => "hello"}}}
      )

    response = %{
      body: %{
        "model" => "claude-test",
        "status" => "completed",
        "output" => [],
        "usage" => %{
          "input_tokens" => 33,
          "output_tokens" => 7,
          "total_tokens" => 40,
          "input_tokens_details" => %{"cached_tokens" => 20, "cache_creation_tokens" => 10},
          "output_tokens_details" => %{"reasoning_tokens" => 2}
        }
      }
    }

    observation = AIGatewayObservability.finish_round(observation, response)
    _observation = AIGatewayObservability.finish_response(observation, response)

    spans = exported_spans()
    generation = span!(spans, "chat claude-test")

    assert generation.attributes["gen_ai.provider.name"] == "anthropic"
    assert generation.attributes["gen_ai.usage.input_tokens"] == 33
    assert generation.attributes["gen_ai.usage.cache_read.input_tokens"] == 20
    assert generation.attributes["gen_ai.usage.cache_creation.input_tokens"] == 10
    assert generation.attributes["gen_ai.usage.reasoning.output_tokens"] == 2
  end

  test "a provider-native compact call records its own generation" do
    enable_export(self(), "langfuse")

    runtime = %{"model" => "gpt-compact", "provider_kind" => "openai"}

    result =
      AIGatewayObservability.record_compact(
        "principal-compact",
        runtime,
        %{"model" => "gpt-compact", "input" => [%{"type" => "message", "content" => "history"}]},
        fn ->
          {:ok,
           %{
             body: %{
               "id" => "resp-compact",
               "model" => "gpt-compact",
               "status" => "completed",
               "output" => [%{"type" => "compaction", "encrypted_content" => "opaque-secret"}],
               "usage" => %{"input_tokens" => 9, "output_tokens" => 4}
             }
           }}
        end
      )

    assert {:ok, %{body: %{"id" => "resp-compact"}}} = result

    spans = exported_spans()
    compact = span!(spans, "compact gpt-compact")

    assert compact.attributes["langfuse.observation.type"] == "generation"
    assert compact.attributes["gen_ai.request.model"] == "gpt-compact"
    assert compact.attributes["user.id"] == "principal:principal-compact"
    assert compact.attributes["ankole.ai_gateway.caller"] == "compaction.upstream"
    assert compact.attributes["gen_ai.usage.input_tokens"] == 9
    assert compact.status == :ok
    refute compact.attributes["ankole.ai_gateway.output"] =~ "opaque-secret"
  end

  test "a credential-pool retry appears as an event on the open round" do
    enable_export(self(), "langfuse")

    observation =
      "principal-retry"
      |> AIGatewayObservability.start_response(%{"input" => "hello"})
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-test", request: %{"input" => "hello"}}}
      )

    assert :ok =
             AIGatewayObservability.record_credential_retry(
               observation,
               {:upstream_response_failed, 429, %{}},
               250
             )

    response = %{
      body: %{
        "model" => "gpt-test",
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, response)
    _observation = AIGatewayObservability.finish_response(observation, response)

    spans = exported_spans()
    generation = span!(spans, "chat gpt-test")

    assert [event] = generation.events
    assert event.name == "ankole.ai_gateway.credential_retry"
    assert event.attributes["error.type"] == "upstream_response_failed"
    assert event.attributes["ankole.ai_gateway.retry_delay_ms"] == 250
  end

  test "the real exporter sends Langfuse OTLP HTTP protobuf to the derived trace path" do
    headers = %{
      "Authorization" => "Basic test-auth",
      "x-langfuse-ingestion-version" => "4"
    }

    configure_real_exporter("langfuse", "/api/public/otel", headers)

    emit_response()

    assert_receive {:otlp_request, "POST", "/api/public/otel/v1/traces", request_headers, body},
                   1_000

    assert request_headers["authorization"] == "Basic test-auth"
    assert request_headers["x-langfuse-ingestion-version"] == "4"
    assert request_headers["content-type"] == "application/x-protobuf"

    decoded =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        body,
        :export_trace_service_request
      )

    assert [resource_span] = decoded.resource_spans
    assert resource_attribute(resource_span, "service.name") == "ankole-control-plane"

    names =
      for scope <- resource_span.scope_spans,
          span <- scope.spans,
          do: span.name

    assert "ai_gateway.response" in names
    assert "chat gpt-http" in names
  end

  test "AppConfigure wins over standard OTLP exporter environment variables" do
    wrong_endpoint = start_otlp_receiver("/wrong")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", wrong_endpoint)
    System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "Authorization=wrong")
    System.put_env("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")
    System.put_env("OTEL_TRACES_EXPORTER", "otlp")

    configure_real_exporter("langfuse", "/api/public/otel", %{
      "Authorization" => "Basic app-configure",
      "x-langfuse-ingestion-version" => "4"
    })

    emit_response()

    assert_receive {:otlp_request, "POST", "/api/public/otel/v1/traces", request_headers, _body},
                   1_000

    assert request_headers["authorization"] == "Basic app-configure"
    refute_receive {:otlp_request, "POST", "/wrong/v1/traces", _headers, _body}, 50

    refute System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    refute System.get_env("OTEL_EXPORTER_OTLP_HEADERS")
    refute System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL")
    refute System.get_env("OTEL_TRACES_EXPORTER")
  end

  test "the real exporter sends LangSmith headers to its derived trace path" do
    headers = %{
      "x-api-key" => "test-langsmith-key",
      "Langsmith-Project" => "ankole-test"
    }

    configure_real_exporter("langsmith", "/otel", headers)
    emit_response()

    assert_receive {:otlp_request, "POST", "/otel/v1/traces", request_headers, body}, 1_000

    assert request_headers["x-api-key"] == "test-langsmith-key"
    assert request_headers["langsmith-project"] == "ankole-test"
    assert request_headers["content-type"] == "application/x-protobuf"

    attributes = decoded_span_attributes(body, "chat gpt-http")

    assert attributes["langsmith.span.kind"] == "llm"
    assert attributes["gen_ai.prompt"] =~ "hello"
    assert attributes["gen_ai.completion"] =~ "world"
    refute Map.has_key?(attributes, "langsmith.trace.session_id")
  end

  test "the real exporter sends a LangSmith conversation as the documented session" do
    configure_real_exporter("langsmith", "/otel", %{"x-api-key" => "test-langsmith-key"})

    observation =
      AIGatewayObservability.start_response(
        "principal-http",
        %{"input" => "hello"},
        stateful: %{conversation_id: "conversation-http"}
      )

    _observation = AIGatewayObservability.finish_response(observation, %{"status" => "completed"})
    assert :ok = :otel_tracer_provider.force_flush()

    assert_receive {:otlp_request, "POST", "/otel/v1/traces", _headers, body}, 1_000

    attributes = decoded_span_attributes(body, "ai_gateway.response")
    assert attributes["langsmith.trace.session_id"] == "conversation-http"
    assert attributes["session.id"] == "conversation-http"
    assert attributes["gen_ai.conversation.id"] == "conversation-http"
  end

  test "a prompt cache key is not exported as a trace session" do
    enable_export(self(), "langsmith")

    observation =
      AIGatewayObservability.start_response(
        "principal-cache-key",
        %{"input" => "hello", "prompt_cache_key" => "shared-prefix"}
      )

    _observation = AIGatewayObservability.finish_response(observation, %{"status" => "completed"})

    response = exported_spans() |> span!("ai_gateway.response")

    refute Map.has_key?(response.attributes, "session.id")
    refute Map.has_key?(response.attributes, "gen_ai.conversation.id")
    refute Map.has_key?(response.attributes, "langsmith.trace.session_id")
  end

  test "the LangSmith provider exports unrelated global spans" do
    headers = %{"x-api-key" => "test-langsmith-key"}
    configure_real_exporter("langsmith", "/otel", headers)

    tracer = :opentelemetry.get_tracer(:unrelated_library, :undefined, :undefined)
    span = :otel_tracer.start_span(OpenTelemetry.Ctx.new(), tracer, "database.query", %{})
    OpenTelemetry.Span.end_span(span)
    assert :ok = :otel_tracer_provider.force_flush()

    assert_receive {:otlp_request, "POST", "/otel/v1/traces", _headers, body}, 1_000
    assert decoded_span_attributes(body, "database.query") == %{}
  end

  test "the real exporter sends generic OTLP spans to VictoriaTraces" do
    configure_real_exporter("opentelemetry", "/insert/opentelemetry", %{})
    emit_response()

    assert_receive {:otlp_request, "POST", "/insert/opentelemetry/v1/traces", headers, body},
                   1_000

    assert headers["content-type"] == "application/x-protobuf"

    attributes = decoded_span_attributes(body, "chat gpt-http")

    assert attributes["gen_ai.provider.name"] == "openai"
    assert attributes["ankole.ai_gateway.input"] =~ "hello"

    refute Enum.any?(Map.keys(attributes), fn key ->
             String.starts_with?(key, "langfuse.") or String.starts_with?(key, "langsmith.")
           end)
  end

  defp assert_turn_identity(actor_event, human_uid, expected_user_id) do
    on_exit(fn ->
      Observability.finish_turn(actor_event.id, error_type: "test_cleanup")
    end)

    runtime_env =
      if is_binary(human_uid) do
        %{"ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => human_uid}
      else
        %{}
      end

    %{traceparent: traceparent, user_id: ^expected_user_id} =
      Observability.start_turn(actor_event, %{
        request_context: %{},
        runtime_env: runtime_env
      })

    observation =
      AIGatewayObservability.start_response(
        actor_event.agent_uid,
        %{"input" => "hello"},
        request_context: %{
          "headers" => %{"traceparent" => traceparent},
          "observability_user_id" => expected_user_id
        },
        stateful: %{conversation_id: actor_event.session_id},
        subject_type: "agent"
      )

    observation =
      AIGatewayObservability.start_round(
        observation,
        %{runtime: %{"provider_kind" => "openai"}},
        %{
          response_context: %{
            model: "gpt-trigger-identity",
            request: %{"input" => "hello"}
          }
        }
      )

    provider_response = %{
      body: %{
        "model" => "gpt-trigger-identity",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "done"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, provider_response)
    _observation = AIGatewayObservability.finish_response(observation, provider_response)
    assert :ok = Observability.finish_turn(actor_event.id)

    spans = exported_spans()
    root = span!(spans, "turn #{actor_event.type}")
    response = span!(spans, "ai_gateway.response")
    generation = span!(spans, "chat gpt-trigger-identity")

    assert response.trace_id == root.trace_id
    assert generation.trace_id == root.trace_id
    assert response.parent_span_id == root.span_id
    assert generation.parent_span_id == response.span_id

    Enum.each([root, response, generation], fn span ->
      assert span.attributes["user.id"] == expected_user_id
      assert span.attributes["session.id"] == actor_event.session_id
      assert span.attributes["ankole.principal.uid"] == actor_event.agent_uid
      assert span.attributes["ankole.principal.type"] == "agent"
    end)
  end

  defp enable_export(test_pid, provider_name) do
    definitions = Map.new(Observability.definitions(), &{&1.key, &1})
    :ok = Observability.ensure_registered()

    assert {:ok, true} =
             AppConfigure.put_global(definitions["observability.traces.enabled"], true)

    assert {:ok, ^provider_name} =
             AppConfigure.put_global(
               definitions["observability.traces.provider"],
               provider_name
             )

    assert {:ok, "https://example.test/otel"} =
             AppConfigure.put_global(
               definitions["observability.traces.otlp_endpoint"],
               "https://example.test/otel"
             )

    assert {:ok, %{enabled?: true}} =
             Observability.init(
               set_exporter: fn _config ->
                 :otel_batch_processor.set_exporter(:global, Exporter, test_pid)
               end
             )

    wait_for_exporter(test_pid)
  end

  defp wait_for_exporter(test_pid, attempts \\ 100)
  defp wait_for_exporter(_test_pid, 0), do: flunk("test exporter did not initialize")

  defp wait_for_exporter(test_pid, attempts) do
    case :sys.get_state(:otel_batch_processor_global) do
      {:idle, state} when elem(state, 2) == {Exporter, test_pid} ->
        :ok

      _state ->
        Process.sleep(1)
        wait_for_exporter(test_pid, attempts - 1)
    end
  end

  defp wait_for_real_exporter(attempts \\ 100)
  defp wait_for_real_exporter(0), do: flunk("OTLP exporter did not initialize")

  defp wait_for_real_exporter(attempts) do
    case :sys.get_state(:otel_batch_processor_global) do
      {:idle, state} ->
        case elem(state, 2) do
          {:opentelemetry_exporter, _exporter_state} ->
            :ok

          _exporter ->
            Process.sleep(1)
            wait_for_real_exporter(attempts - 1)
        end

      _state ->
        Process.sleep(1)
        wait_for_real_exporter(attempts - 1)
    end
  end

  defp configure_real_exporter(provider_name, path, headers) do
    endpoint = start_otlp_receiver(path)
    definitions = Map.new(Observability.definitions(), &{&1.key, &1})
    :ok = Observability.ensure_registered()

    assert {:ok, true} =
             AppConfigure.put_global(definitions["observability.traces.enabled"], true)

    assert {:ok, ^provider_name} =
             AppConfigure.put_global(
               definitions["observability.traces.provider"],
               provider_name
             )

    assert {:ok, ^endpoint} =
             AppConfigure.put_global(
               definitions["observability.traces.otlp_endpoint"],
               endpoint
             )

    assert {:ok, ^headers} =
             AppConfigure.put_global(
               definitions["observability.traces.otlp_headers"],
               headers
             )

    assert {:ok, %{enabled?: true}} = Observability.init([])
    wait_for_real_exporter()
  end

  defp emit_response do
    observation =
      "principal-http"
      |> AIGatewayObservability.start_response(%{"input" => "hello"})
      |> AIGatewayObservability.start_round(
        %{runtime: %{"provider_kind" => "openai"}},
        %{response_context: %{model: "gpt-http", request: %{"input" => "hello"}}}
      )

    response = %{
      body: %{
        "id" => "resp-http",
        "model" => "gpt-http",
        "status" => "completed",
        "output" => [%{"type" => "message", "content" => "world"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }
    }

    observation = AIGatewayObservability.finish_round(observation, response)
    _observation = AIGatewayObservability.finish_response(observation, response)

    assert :ok = :otel_tracer_provider.force_flush()
  end

  defp start_otlp_receiver(path) do
    server =
      start_supervised!(
        {Bandit, plug: {OTLPReceiver, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}#{path}"
  end

  defp decoded_span_attributes(body, name) do
    decoded =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        body,
        :export_trace_service_request
      )

    span =
      for resource <- decoded.resource_spans,
          scope <- resource.scope_spans,
          span <- scope.spans,
          span.name == name,
          do: span

    assert [span] = span
    Map.new(span.attributes, fn item -> {item.key, any_value(item.value)} end)
  end

  defp resource_attribute(resource_span, key) do
    Enum.find_value(resource_span.resource.attributes, fn attribute ->
      if attribute.key == key, do: any_value(attribute.value)
    end)
  end

  defp exported_spans do
    assert :ok = :otel_tracer_provider.force_flush()

    receive do
      {:exported_spans, %{resource_spans: resource_spans}} ->
        for resource <- resource_spans,
            scope <- resource.scope_spans,
            span <- scope.spans,
            do: decode_span(span)
    after
      1_000 -> flunk("OpenTelemetry did not export spans")
    end
  end

  defp decode_span(span) do
    %{
      name: span.name,
      trace_id: span.trace_id,
      span_id: span.span_id,
      parent_span_id: span.parent_span_id,
      attributes: Map.new(span.attributes, fn item -> {item.key, any_value(item.value)} end),
      events:
        Enum.map(span.events, fn event ->
          %{
            name: event.name,
            attributes:
              Map.new(event.attributes, fn item -> {item.key, any_value(item.value)} end)
          }
        end),
      status: status(span.status)
    }
  end

  defp any_value(%{value: {_kind, value}}), do: value

  defp status(%{code: :STATUS_CODE_OK}), do: :ok
  defp status(%{code: :STATUS_CODE_ERROR}), do: :error
  defp status(_status), do: :unset

  defp span!(spans, name), do: Enum.find(spans, &(&1.name == name)) || flunk("missing #{name}")

  defp clear_app_configure do
    Registry.clear_for_test()
    Cache.clear_for_test()
  end

  defp otlp_environment do
    System.get_env()
    |> Map.take([
      "OTEL_EXPORTER_OTLP_COMPRESSION",
      "OTEL_EXPORTER_OTLP_ENDPOINT",
      "OTEL_EXPORTER_OTLP_HEADERS",
      "OTEL_EXPORTER_OTLP_PROTOCOL",
      "OTEL_EXPORTER_OTLP_TRACES_COMPRESSION",
      "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
      "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
      "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
      "OTEL_TRACES_EXPORTER"
    ])
  end

  defp restore_environment(previous_environment) do
    current_environment = otlp_environment()

    current_environment
    |> Map.keys()
    |> Enum.each(&System.delete_env/1)

    System.put_env(previous_environment)
  end
end
