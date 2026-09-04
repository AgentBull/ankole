defmodule Ankole.AIGateway.FailureDiagnosticsTest do
  use ExUnit.Case, async: true

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

  test "classifies a canonical invalid prompt as a terminal provider failure" do
    assert %{
             error_code: "invalid_prompt",
             failure_kind: :provider_response,
             retryable: false
           } =
             FailureDiagnostics.classify(%{
               "code" => "invalid_prompt",
               "retryable" => false
             })
  end

  test "public error code keeps a Responses code and canonicalizes a permanent rejection" do
    assert FailureDiagnostics.public_error_code(
             %{provider_error_code: "context_length_exceeded", provider_status: 400},
             "provider_stream_error"
           ) == "context_length_exceeded"

    assert FailureDiagnostics.public_error_code(
             %{error_code: "upstream_response_failed", provider_status: 400},
             "provider_stream_error"
           ) == "invalid_prompt"

    assert FailureDiagnostics.public_error_code(
             %{error_code: "upstream_response_failed", provider_status: 429, retryable: true},
             "provider_stream_error"
           ) == "upstream_response_failed"

    assert FailureDiagnostics.public_error_code(%{}, "provider_stream_error") ==
             "provider_stream_error"
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

  describe "project/2" do
    test "projects known failures and keeps unknown failures server-side" do
      rows = [
        {:missing_model, 400, "missing_model", "model"},
        {:missing_input, 400, "missing_input", "input"},
        {:invalid_anchor, 400, "invalid_previous_response_id", nil},
        {:invalid_conversation, 400, "invalid_stateful_conversation", nil},
        {:previous_response_not_found, 400, "previous_response_not_found",
         "previous_response_id"},
        {{:stateful_http_field_forbidden, "conversation"}, 400,
         "stateful_responses_require_websocket", nil},
        {:invalid_oidc_access, 401, "invalid_token", nil},
        {{:oidc_access_denied, :model_not_allowed}, 403, "access_denied", "model"},
        {{:oidc_access_denied, :not_found}, 403, "access_denied", nil},
        {:not_found, 404, "not_found", nil},
        {:response_run_in_progress, 409, "response_in_progress", nil},
        {{:tool_results_quarantined, %{"reason" => "orphan"}}, 409, "tool_results_quarantined",
         "input"},
        {:model_profile_not_configured, 422, "model_profile_not_configured", "model"},
        {{:unknown_model_selector, :responses, "nope"}, 422, "unknown_model_selector", "model"},
        {{:model_binding_not_configured, "responses", "main"}, 422,
         "model_binding_not_configured", "model"},
        {{:context_overflow, %{"budget" => 1}}, 422, "context_overflow", nil},
        {:empty_compaction_summary, 502, "empty_compaction_summary", nil},
        {:invalid_summary_shape, 502, "invalid_summary_shape", nil},
        {{:tool_results_record_unavailable, %{"attempts" => 3}}, 503,
         "tool_results_record_unavailable", nil},
        {:response_stream_collect_timeout, 504, "upstream_timeout", nil},
        {:universal_ai_stream_ready_timeout, 504, "upstream_timeout", nil},
        {:response_stream_missing_terminal_response, 502, "invalid_upstream_response", nil},
        {:response_stream_closed, 502, "provider_stream_error", nil},
        {{:response_stream_closed, :killed}, 502, "provider_stream_error", nil},
        {{:exception, RuntimeError, "private crash"}, 502, "ai_gateway_request_failed", nil},
        {{:exit, :shutdown}, 502, "ai_gateway_request_failed", nil},
        {:request_too_large, 422, "request_too_large", nil},
        {{:invalid_provider_options, %{"private" => "detail"}}, 422, "invalid_provider_options",
         nil},
        {:response_stream_start_ignored, 502, "ai_gateway_request_failed", nil},
        {:response_stream_unavailable, 502, "ai_gateway_request_failed", nil},
        {{"unexpected", 1}, 502, "ai_gateway_request_failed", nil}
      ]

      for {reason, status, code, param} <- rows do
        assert %{status: ^status, headers: %{}, error: error} =
                 FailureDiagnostics.project(reason),
               "reason #{inspect(reason)}"

        assert %{"code" => ^code, "param" => ^param, "message" => message, "type" => type} =
                 error

        assert is_binary(message) and message != ""
        assert type == if(status >= 500, do: "server_error", else: "invalid_request_error")
        refute inspect(error) =~ "private"
      end

      assert %{error: %{"details_json" => %{"reason" => "orphan"}}} =
               FailureDiagnostics.project({:tool_results_quarantined, %{"reason" => "orphan"}})
    end

    test "upstream failures follow the HTTP status rule and carry safe details" do
      body = %{"error" => %{"code" => "rate_limited", "message" => "provider rate limit"}}

      assert %{
               status: 429,
               error: %{
                 "code" => "upstream_response_failed",
                 "message" => "provider rate limit",
                 "details_json" => %{
                   "provider_status" => 429,
                   "provider_error_code" => "rate_limited",
                   "retryable" => true,
                   "stage" => "socket_open"
                 }
               }
             } =
               FailureDiagnostics.project({:upstream_response_failed, 429, body},
                 stage: "socket_open"
               )

      assert %{
               status: 502,
               error: %{
                 "code" => "upstream_response_failed",
                 "message" => "The upstream provider request failed.",
                 "details_json" => details
               }
             } =
               FailureDiagnostics.project({:upstream_response_failed, 503, "private body", %{}})

      assert details["provider_status"] == 503
      refute Map.has_key?(details, "stage")

      assert %{
               status: 502,
               error: %{
                 "code" => "invalid_upstream_response",
                 "message" => "The upstream provider returned an invalid response."
               }
             } = FailureDiagnostics.project({:invalid_upstream_response, 200, ["private"]})

      assert %{
               status: 504,
               error: %{
                 "code" => "upstream_timeout",
                 "message" => "The upstream provider timed out."
               }
             } =
               FailureDiagnostics.project(
                 {:universal_ai_request_failed, %{"code" => "total_timeout"}}
               )

      assert %{
               status: 502,
               error: %{
                 "code" => "upstream_transport_failed",
                 "message" => "The upstream provider connection failed.",
                 "details_json" => %{
                   "error_code" => "websocket_connect_failed",
                   "error_stage" => "connect",
                   "retryable" => true
                 }
               }
             } =
               FailureDiagnostics.project(
                 {:universal_ai_request_failed,
                  %{"code" => "websocket_connect_failed", "stage" => "connect"}}
               )

      assert %{status: 400, error: %{"code" => "upstream_response_failed"}} =
               FailureDiagnostics.project(
                 {:universal_ai_request_failed,
                  %{"code" => "upstream_response_failed", "provider_status" => 400}}
               )

      assert %{
               status: 502,
               error: %{
                 "code" => "ai_gateway_request_failed",
                 "message" => "The AIGateway request failed."
               }
             } = FailureDiagnostics.project({:universal_ai_request_failed, %{"code" => "other"}})
    end

    test "an exhausted credential pool keeps one wording, retry headers, and resets_at" do
      retry_at = DateTime.utc_now(:second) |> DateTime.add(600)
      iso = DateTime.to_iso8601(retry_at)

      assert %{
               status: 429,
               headers: %{
                 "retry-after" => retry_after,
                 "x-codex-primary-reset-at" => reset_header
               },
               error: %{
                 "type" => "usage_limit_reached",
                 "code" => "credential_pool_exhausted",
                 "message" => message,
                 "resets_at" => resets_at,
                 "details_json" => %{"retry_at" => ^iso}
               }
             } = FailureDiagnostics.project({:credential_pool_exhausted, %{"retry_at" => iso}})

      assert message == "AIGateway credential pool exhausted. retry_at=#{iso}"
      assert resets_at == DateTime.to_unix(retry_at)
      assert reset_header == Integer.to_string(resets_at)
      assert {seconds, ""} = Integer.parse(retry_after)
      assert seconds in 0..600

      assert %{
               status: 429,
               headers: %{},
               error:
                 %{
                   "message" => "AIGateway credential pool exhausted. Try again later.",
                   "details_json" => %{}
                 } = error
             } = FailureDiagnostics.project({:credential_pool_exhausted, %{"retry_at" => "soon"}})

      refute Map.has_key?(error, "resets_at")

      assert %{retry_at: ^iso} =
               FailureDiagnostics.classify({:credential_pool_exhausted, %{"retry_at" => iso}})

      assert %{"code" => "credential_pool_exhausted", "retry_at" => iso}
             |> FailureDiagnostics.classify_stored()
             |> FailureDiagnostics.public_message() ==
               "AIGateway credential pool exhausted. retry_at=#{iso}"
    end

    test "an OpenAI error projects its own envelope" do
      error = OpenAIError.invalid("input", "invalid_input", "input is invalid")

      assert %{
               status: 400,
               headers: %{},
               error: %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_input",
                 "message" => "input is invalid",
                 "param" => "input"
               }
             } = FailureDiagnostics.project(error)
    end
  end
end
