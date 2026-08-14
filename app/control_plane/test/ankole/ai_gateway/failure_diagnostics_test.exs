defmodule Ankole.AIGateway.FailureDiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.OpenAIError

  test "keeps a public HTTP status separate from provider status" do
    log =
      capture_log(
        [
          level: :error,
          metadata: [:event, :error_code, :http_status, :provider_status, :retryable]
        ],
        fn ->
          assert :ok =
                   FailureDiagnostics.log(
                     "ai_gateway.test_failed",
                     "AIGateway test failed",
                     %{},
                     OpenAIError.server(
                       500,
                       "artifact_persistence_failed",
                       "private public error"
                     )
                   )
        end
      )

    assert log =~ "error_code=artifact_persistence_failed"
    assert log =~ "http_status=500"
    assert log =~ "retryable=true"
    refute log =~ "provider_status="
    refute log =~ "private public error"
  end

  test "keeps an invalid upstream response attributed to the provider boundary" do
    log =
      capture_log(
        [
          level: :error,
          metadata: [
            :event,
            :failure_kind,
            :error_code,
            :provider_status,
            :provider_error_code,
            :retryable
          ]
        ],
        fn ->
          assert :ok =
                   FailureDiagnostics.log(
                     "ai_gateway.test_failed",
                     "AIGateway test failed",
                     %{},
                     {:invalid_upstream_response, 200,
                      %{
                        "error" => %{
                          "code" => "invalid_shape",
                          "message" => "private provider body"
                        }
                      }}
                   )
        end
      )

    assert log =~ "error_code=invalid_upstream_response"
    assert log =~ "failure_kind=invalid_response"
    assert log =~ "provider_status=200"
    assert log =~ "provider_error_code=invalid_shape"
    assert log =~ "retryable=true"
    refute log =~ "private provider body"

    assert %{
             error_code: "invalid_upstream_response",
             failure_kind: :invalid_response,
             provider_status: 200
           } =
             FailureDiagnostics.classify(%{
               "code" => "invalid_upstream_response",
               "status" => 200
             })

    assert %{
             error_code: "upstream_response_failed",
             failure_kind: :provider_response,
             provider_status: 502
           } =
             FailureDiagnostics.classify(%{
               "code" => "upstream_response_failed",
               "status" => 502
             })
  end

  test "restores only an enumerated Ankole failure kind from stored metadata" do
    assert %{
             error_code: "invalid_request",
             failure_kind: :provider_response,
             retryable: false
           } =
             FailureDiagnostics.classify_stored(%{
               "code" => "invalid_request",
               "failure_kind" => "provider_response",
               "retryable" => false
             })

    assert %{failure_kind: :internal} =
             FailureDiagnostics.classify_stored(%{
               "code" => "invalid_request",
               "failure_kind" => "private provider prose"
             })
  end

  test "uses a tuple tag when nested details have no error code" do
    log =
      capture_log(
        [level: :error, metadata: [:event, :error_code, :error_stage]],
        fn ->
          assert :ok =
                   FailureDiagnostics.log(
                     "ai_gateway.test_failed",
                     "AIGateway test failed",
                     %{},
                     {:universal_ai_request_failed, %{"stage" => "connect"}}
                   )
        end
      )

    assert log =~ "error_code=universal_ai_request_failed"
    assert log =~ "error_stage=connect"
  end

  test "classifies stable transport and timeout codes as retryable" do
    assert %{
             failure_kind: :transport,
             error_code: "transport_failed",
             error_stage: "connect",
             retryable: true
           } =
             FailureDiagnostics.classify(
               {:universal_ai_request_failed,
                %{"code" => "transport_failed", "stage" => "connect"}}
             )

    assert %{
             failure_kind: :timeout,
             error_code: "total_timeout",
             retryable: true
           } =
             FailureDiagnostics.classify(
               {:universal_ai_request_failed, %{"code" => "total_timeout"}}
             )

    assert %{
             failure_kind: :timeout,
             error_code: "connect_timeout",
             error_stage: "connect",
             retryable: true
           } =
             FailureDiagnostics.classify(
               {:universal_ai_request_failed,
                %{"code" => "connect_timeout", "stage" => "connect"}}
             )
  end

  test "builds safe public messages from the stable failure kind" do
    assert FailureDiagnostics.public_message(%{failure_kind: :transport}) ==
             "The upstream provider connection failed."

    assert FailureDiagnostics.public_message(%{failure_kind: :invalid_response}) ==
             "The upstream provider returned an invalid response."

    assert FailureDiagnostics.public_message(%{failure_kind: :internal}) ==
             "The AIGateway request failed."

    classification = FailureDiagnostics.classify(%{"code" => "provider_stream_error"})

    assert classification.failure_kind == :transport

    assert FailureDiagnostics.public_message(classification) ==
             "AIGateway provider stream failed before a terminal response."
  end

  test "returns one bounded upstream message without using it for retry classification" do
    upstream_message =
      "This request requires more credits, or fewer max_tokens."

    classification =
      FailureDiagnostics.classify(
        {:upstream_response_failed, 402,
         %{"error" => %{"code" => 402, "message" => upstream_message}}}
      )

    assert classification.failure_kind == :provider_response
    assert classification.provider_status == 402
    assert classification.provider_message == upstream_message
    assert classification.retryable == false
    assert FailureDiagnostics.public_message(classification) == upstream_message

    long_message = String.duplicate("上", 2_001)

    bounded =
      FailureDiagnostics.classify(
        {:upstream_response_failed, 403, %{"error" => %{"message" => long_message}}}
      )

    assert String.length(bounded.provider_message) == 2_000
    assert FailureDiagnostics.public_message(bounded) == String.slice(long_message, 0, 2_000)
  end

  test "restores a bounded provider message from stored provider failures" do
    classification =
      FailureDiagnostics.classify_stored(%{
        "code" => "upstream_response_failed",
        "failure_kind" => "provider_response",
        "message" => "stored upstream message",
        "provider_status" => 403,
        "retryable" => false
      })

    assert classification.provider_message == "stored upstream message"
    assert FailureDiagnostics.public_message(classification) == "stored upstream message"
  end

  test "classifies provider terminal events from stable fields and retains their public message" do
    assert %{
             failure_kind: :provider_response,
             error_code: "rate_limit_exceeded",
             provider_message: "opaque provider text",
             retryable: true
           } =
             FailureDiagnostics.classify(
               {:provider_event_failed,
                %{
                  "status" => "failed",
                  "error" => %{
                    "code" => "rate_limit_exceeded",
                    "message" => "opaque provider text"
                  }
                }}
             )

    assert %{
             failure_kind: :provider_response,
             error_code: "server_error",
             provider_status: 503,
             retryable: true
           } =
             FailureDiagnostics.classify(
               {:provider_event_failed,
                %{"error" => %{"code" => "server_error", "status" => 503}}}
             )

    assert %{error_code: "invalid_request", failure_kind: :provider_response} =
             classification =
             FailureDiagnostics.classify(
               {:provider_event_failed,
                %{
                  "error" => %{
                    "code" => "invalid_request",
                    "message" => "rate limit 429 too many requests"
                  }
                }}
             )

    refute Map.get(classification, :retryable) == true
    refute Map.has_key?(classification, :provider_event?)
  end

  test "keeps a provider error diagnostic subordinate to a transport terminal" do
    terminal_error = %{
      "code" => "upstream_stream_closed_before_terminal_event",
      "failure_kind" => "transport",
      "message" => "provider stream broke",
      "provider_error_code" => "upstream_stream_break",
      "provider_error_type" => "provider_disconnect",
      "retryable" => true,
      "details_json" => %{}
    }

    assert %{
             error_code: "upstream_stream_closed_before_terminal_event",
             failure_kind: :transport,
             provider_error_code: "upstream_stream_break",
             provider_error_type: "provider_disconnect",
             retryable: true
           } = FailureDiagnostics.classify(terminal_error)

    log =
      capture_log(
        [
          level: :error,
          metadata: [
            :event,
            :error_code,
            :failure_kind,
            :provider_error_code,
            :provider_error_type,
            :retryable
          ]
        ],
        fn ->
          assert :ok =
                   FailureDiagnostics.log(
                     "ai_gateway.test_failed",
                     "AIGateway test failed",
                     %{},
                     terminal_error
                   )
        end
      )

    assert log =~ "error_code=upstream_stream_closed_before_terminal_event"
    assert log =~ "failure_kind=transport"
    assert log =~ "provider_error_code=upstream_stream_break"
    assert log =~ "provider_error_type=provider_disconnect"
    assert log =~ "retryable=true"
    refute log =~ "provider stream broke"
  end

  test "bounds provider error identifiers before public or durable projection" do
    code = String.duplicate("c", 300)
    type = String.duplicate("t", 300)

    assert %{
             error_code: bounded_code,
             provider_error_code: provider_error_code,
             provider_error_type: bounded_type
           } =
             FailureDiagnostics.classify(
               {:provider_event_failed,
                %{"error" => %{"code" => code, "type" => type, "message" => "safe"}}}
             )

    assert bounded_code == String.slice(code, 0, 256)
    assert provider_error_code == bounded_code
    assert bounded_type == String.slice(type, 0, 256)
  end

  test "classifies Codex overload aliases as retryable provider failures" do
    for code <- ["server_is_overloaded", "slow_down"] do
      assert %{
               failure_kind: :provider_response,
               error_code: ^code,
               provider_error_code: ^code,
               provider_error_type: "service_unavailable_error",
               retryable: true
             } =
               FailureDiagnostics.classify(
                 {:provider_event_failed,
                  %{
                    "error" => %{
                      "type" => "service_unavailable_error",
                      "code" => code,
                      "message" => "opaque provider text"
                    }
                  }}
               )
    end
  end

  test "logs a provider rate-limit code as warning without logging its message" do
    log =
      capture_log(
        [
          level: :warning,
          metadata: [:event, :failure_kind, :error_code, :provider_message, :retryable]
        ],
        fn ->
          assert :ok =
                   FailureDiagnostics.log(
                     "ai_gateway.test_failed",
                     "AIGateway test failed",
                     %{},
                     {:provider_event_failed,
                      %{
                        "error" => %{
                          "code" => "rate_limit_exceeded",
                          "message" => "untrusted provider prose"
                        }
                      }}
                   )
        end
      )

    assert log =~ "failure_kind=provider_response"
    assert log =~ "error_code=rate_limit_exceeded"
    assert log =~ "retryable=true"
    refute log =~ "untrusted provider prose"
  end
end
