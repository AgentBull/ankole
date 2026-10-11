defmodule Ankole.AIGateway.ImageFailureLoggingTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.OpenAIError

  test "failure fields retain routing facts and exclude provider content" do
    spec = %{
      hosted_tools: %{
        image_generation: %{
          "actor_event_id" => "event-1",
          "selected_model" => "selected-model",
          "provider_tags" => ["tag-a", "", nil],
          "provider_slugs" => ["slug-a"],
          "prompt" => "private prompt",
          "api_key" => "private credential"
        }
      }
    }

    reason = %{
      "code" => "internal_transport_code",
      "message" => "private provider message",
      "provider_body_excerpt" => "private provider body",
      "hosted_tool_metadata" => %{
        "failure_reason" => "upstream_error",
        "model" => "actual-model",
        "provider_tag" => "actual-tag",
        "provider_slug" => "actual-slug",
        "image_latency_ms" => 42,
        "result_base64" => "private pixels"
      }
    }

    assert ImageGeneration.failure_log_fields(spec, reason) == %{
             actor_event_id: "event-1",
             image_model: "actual-model",
             image_provider_tag: "actual-tag",
             image_provider_slug: "actual-slug",
             image_provider_tags: ["tag-a"],
             image_provider_slugs: ["slug-a"],
             image_latency_ms: 42,
             image_failure_reason: "upstream_error"
           }
  end

  test "an internal image error and an aborted native stream keep their safe labels" do
    error = OpenAIError.server(502, "upstream_error", "A safe image error.")

    assert ImageGeneration.failure_log_fields(nil, error) == %{
             image_failure_reason: "upstream_error"
           }

    assert ImageGeneration.failure_log_fields(nil, :stream_aborted) == %{
             image_failure_reason: "stream_aborted"
           }
  end
end
