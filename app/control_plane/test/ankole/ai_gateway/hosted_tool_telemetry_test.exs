defmodule Ankole.AIGateway.HostedToolTelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.AIGateway.HostedToolTelemetry

  test "emits only bounded measurements and routing metadata" do
    handler_id = "hosted-image-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ankole, :ai_gateway, :hosted_image_generation],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             HostedToolTelemetry.emit(%{
               "result" => "success",
               "hosted_tool_calls" => 2,
               "successful_image_calls" => 2,
               "main_model_rounds" => 3,
               "image_latency_ms" => 42,
               "input_bytes" => 128,
               "output_bytes" => 256,
               "partial_images" => 1,
               "provider_cost" => 0.01,
               "model" => "openai/gpt-image-2",
               "provider_tag" => "openai/gpt-image-2:openai",
               "provider_slug" => "openai",
               "prompt" => "must not escape",
               "result_base64" => "must not escape"
             })

    assert_receive {:telemetry, [:ankole, :ai_gateway, :hosted_image_generation], measurements,
                    metadata}

    assert measurements == %{
             count: 1,
             hosted_tool_calls: 2,
             successful_image_calls: 2,
             main_model_rounds: 3,
             image_latency_ms: 42,
             input_bytes: 128,
             output_bytes: 256,
             partial_images: 1,
             provider_cost: 0.01
           }

    assert metadata == %{
             result: "success",
             failure_reason: nil,
             model: "openai/gpt-image-2",
             provider_tag: "openai/gpt-image-2:openai",
             provider_slug: "openai"
           }

    failure_log =
      capture_log(
        [
          level: :error,
          metadata: [
            :event,
            :actor_event_id,
            :failure_reason,
            :error_code,
            :provider_status,
            :error_stage,
            :retryable,
            :model,
            :provider_tag,
            :provider_slug
          ]
        ],
        fn ->
          assert :ok =
                   HostedToolTelemetry.emit_failure(
                     %{
                       hosted_tools: %{
                         image_generation: %{
                           "actor_event_id" => "actor-event-test",
                           "selected_model" => "openai/gpt-image-2",
                           "provider_tags" => [
                             "openai/gpt-image-2:openai",
                             "openai/gpt-image-2:azure"
                           ],
                           "provider_slugs" => ["openai", "azure"]
                         }
                       }
                     },
                     %{
                       "code" => "internal_transport_code",
                       "status" => 503,
                       "details_json" => %{"provider_status" => 503},
                       "stage" => "hosted_responses",
                       "message" => "private provider message",
                       "provider_body_excerpt" => "private provider body",
                       "hosted_tool_metadata" => %{
                         "result" => "failure",
                         "failure_reason" => "upstream_error",
                         "hosted_tool_calls" => 1,
                         "main_model_rounds" => 1,
                         "model" => "openai/gpt-image-2",
                         "provider_tag" => "openai/gpt-image-2:openai",
                         "provider_slug" => "openai"
                       }
                     }
                   )
        end
      )

    assert_receive {:telemetry, [:ankole, :ai_gateway, :hosted_image_generation], measurements,
                    metadata}

    assert measurements.hosted_tool_calls == 1
    assert measurements.main_model_rounds == 1
    assert metadata.result == "failure"
    assert metadata.failure_reason == "upstream_error"
    assert metadata.model == "openai/gpt-image-2"

    assert failure_log =~ "event=ai_gateway.hosted_image_generation_failed"
    assert failure_log =~ "actor_event_id=actor-event-test"
    assert failure_log =~ "failure_reason=upstream_error"
    assert failure_log =~ "error_code=internal_transport_code"
    assert failure_log =~ "provider_status=503"
    assert failure_log =~ "error_stage=hosted_responses"
    assert failure_log =~ "retryable=true"
    assert failure_log =~ "model=openai/gpt-image-2"
    assert failure_log =~ "provider_tag=openai/gpt-image-2:openai"
    assert failure_log =~ "provider_slug=openai"
    refute failure_log =~ "private provider message"
    refute failure_log =~ "private provider body"
  end

  test "emits one bounded event per hosted Brain operation" do
    handler_id = "hosted-brain-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ankole, :ai_gateway, :hosted_brain],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             HostedToolTelemetry.emit_brain(%{
               "operation" => "recall",
               "result" => "failure",
               "failure_reason" => "brain_operation_timeout",
               "subject_uid" => "agent-1",
               "latency_ms" => 60_000,
               "arguments" => %{"query" => "must not escape"},
               "output" => %{"claims" => ["must not escape"]}
             })

    assert_receive {:telemetry, [:ankole, :ai_gateway, :hosted_brain], measurements, metadata}
    assert measurements == %{count: 1, latency_ms: 60_000}

    assert metadata == %{
             operation: "recall",
             result: "failure",
             failure_reason: "brain_operation_timeout",
             subject_uid: "agent-1"
           }
  end
end
