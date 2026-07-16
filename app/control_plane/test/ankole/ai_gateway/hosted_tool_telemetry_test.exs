defmodule Ankole.AIGateway.HostedToolTelemetryTest do
  use ExUnit.Case, async: true

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

    assert :ok =
             HostedToolTelemetry.emit_failure(nil, %{
               "code" => "internal_transport_code",
               "hosted_tool_metadata" => %{
                 "result" => "failure",
                 "failure_reason" => "upstream_error",
                 "hosted_tool_calls" => 1,
                 "main_model_rounds" => 1,
                 "model" => "openai/gpt-image-2",
                 "provider_tag" => "openai",
                 "provider_slug" => "openai"
               }
             })

    assert_receive {:telemetry, [:ankole, :ai_gateway, :hosted_image_generation], measurements,
                    metadata}

    assert measurements.hosted_tool_calls == 1
    assert measurements.main_model_rounds == 1
    assert metadata.result == "failure"
    assert metadata.failure_reason == "upstream_error"
    assert metadata.model == "openai/gpt-image-2"
  end
end
