defmodule Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier

  @now ~U[2026-09-10 10:00:00.000000Z]

  describe "classify/1" do
    test "reads infrastructure error codes from the top level and from the details" do
      for code <- [
            "background_agent_job_runtime_exception",
            "agent_codex_runtime_busy",
            "background_agent_job_steer_delivery_failed",
            "codex_app_server_request_timeout"
          ] do
        assert TurnErrorClassifier.classify(reason(code)) == :infrastructure

        assert TurnErrorClassifier.classify(reason("worker_turn_failed", %{"error_code" => code})) ==
                 :infrastructure
      end
    end

    test "marks a retryable provider or credential pool shortage as provider capacity" do
      for kind <- ["server", "rate_limit"] do
        assert TurnErrorClassifier.classify(
                 reason("worker_turn_failed", %{"llm_error_kind" => kind, "retryable" => true})
               ) == :provider_capacity
      end

      assert TurnErrorClassifier.classify(
               reason("worker_turn_failed", %{
                 "error_code" => "credential_pool_exhausted",
                 "retryable" => true
               })
             ) == :provider_capacity

      assert TurnErrorClassifier.classify(
               reason("worker_turn_failed", %{
                 "retryable" => true,
                 "aigateway" => %{"code" => "credential_pool_exhausted"}
               })
             ) == :provider_capacity
    end

    test "keeps a permanent failure and every other failure on the execution account" do
      permanent = %{"llm_error_kind" => "server", "retryable" => false}
      assert TurnErrorClassifier.classify(reason("worker_turn_failed", permanent)) == :execution

      # A capacity kind without the Worker's retryable conclusion is not enough:
      # the control plane must not schedule what the Worker called permanent.
      assert TurnErrorClassifier.classify(
               reason("worker_turn_failed", %{"llm_error_kind" => "server"})
             ) == :execution

      for details <- [
            %{"llm_error_kind" => "overflow"},
            %{"llm_error_kind" => "auth"},
            %{"error_code" => "server_error"},
            %{}
          ] do
        assert TurnErrorClassifier.classify(reason("worker_turn_failed", details)) == :execution
      end

      assert TurnErrorClassifier.classify(%{"code" => "worker_turn_failed"}) == :execution
    end

    test "puts an infrastructure interruption ahead of a provider capacity signal" do
      assert TurnErrorClassifier.classify(
               reason("worker_turn_failed", %{
                 "error_code" => "codex_app_server_request_timeout",
                 "llm_error_kind" => "server",
                 "retryable" => true
               })
             ) == :infrastructure
    end
  end

  describe "retryable?/1" do
    test "treats the top-level Worker conclusion as authoritative" do
      assert TurnErrorClassifier.retryable?(
               reason("worker_turn_failed", %{
                 "retryable" => true,
                 "aigateway" => %{"details_json" => %{"retryable" => false}}
               })
             )

      refute TurnErrorClassifier.retryable?(
               reason("worker_turn_failed", %{
                 "retryable" => false,
                 "aigateway" => %{"details_json" => %{"retryable" => true}}
               })
             )
    end

    test "reads the nested AIGateway conclusion only when the top level is missing" do
      assert TurnErrorClassifier.retryable?(
               reason("worker_turn_failed", %{
                 "aigateway" => %{"details_json" => %{"retryable" => true}}
               })
             )

      refute TurnErrorClassifier.retryable?(
               reason("worker_turn_failed", %{"aigateway" => %{"code" => "server_error"}})
             )

      refute TurnErrorClassifier.retryable?(reason("worker_turn_failed"))
      refute TurnErrorClassifier.retryable?(%{"code" => "worker_turn_failed"})
    end
  end

  describe "credential_pool_retry_at/2" do
    test "returns only a parseable pool recovery time in the future" do
      future = DateTime.add(@now, 60, :second)

      assert TurnErrorClassifier.credential_pool_retry_at(pool_reason(future), @now) == future

      assert TurnErrorClassifier.credential_pool_retry_at(
               pool_reason(DateTime.add(@now, -1, :second)),
               @now
             ) == nil

      assert TurnErrorClassifier.credential_pool_retry_at(pool_reason(nil), @now) == nil
      assert TurnErrorClassifier.credential_pool_retry_at(pool_reason("not-a-time"), @now) == nil
    end

    test "ignores a recovery time that no pool exhaustion declared" do
      future = DateTime.add(@now, 60, :second)

      assert TurnErrorClassifier.credential_pool_retry_at(
               reason("worker_turn_failed", %{
                 "retryable" => true,
                 "retry_at" => DateTime.to_iso8601(future)
               }),
               @now
             ) == nil
    end
  end

  defp pool_reason(retry_at) do
    details = %{"error_code" => "credential_pool_exhausted", "retryable" => true}

    details =
      case retry_at do
        nil -> details
        %DateTime{} = value -> Map.put(details, "retry_at", DateTime.to_iso8601(value))
        value -> Map.put(details, "retry_at", value)
      end

    reason("worker_turn_failed", details)
  end

  defp reason(code, details \\ %{}) do
    %{"code" => code, "message" => "worker turn failed", "details_json" => details}
  end
end
