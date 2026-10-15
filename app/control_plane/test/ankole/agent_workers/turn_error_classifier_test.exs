defmodule Ankole.AgentWorkers.TurnErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Ankole.Sessions.TurnErrorClassifier

  @now ~U[2026-09-10 10:00:00.000000Z]

  describe "classify/1" do
    test "reads infrastructure error codes from the top level and from the details" do
      for code <- [
            "background_agent_job_runtime_exception",
            "agent_codex_runtime_busy",
            "background_agent_job_steer_delivery_failed",
            "codex_app_server_request_timeout",
            "socket_closed",
            "runtime_fabric_timeout",
            "runtime_rpc_timeout"
          ] do
        assert TurnErrorClassifier.classify(reason(code)) == :infrastructure

        assert TurnErrorClassifier.classify(reason("worker_turn_failed", %{"error_code" => code})) ==
                 :infrastructure
      end
    end

    test "charges every other failure to the execution account" do
      for details <- [
            %{"error_code" => "credential_pool_exhausted", "retryable" => true},
            %{"error_code" => "server_error"},
            %{"error_code" => "timeout", "retryable" => true},
            %{"retryable" => true},
            %{}
          ] do
        assert TurnErrorClassifier.classify(reason("worker_turn_failed", details)) == :execution
      end

      assert TurnErrorClassifier.classify(%{"code" => "worker_turn_failed"}) == :execution
    end
  end

  describe "retryable?/1" do
    test "reads the Worker conclusion and treats a missing one as permanent" do
      assert TurnErrorClassifier.retryable?(reason("worker_turn_failed", %{"retryable" => true}))
      refute TurnErrorClassifier.retryable?(reason("worker_turn_failed", %{"retryable" => false}))
      refute TurnErrorClassifier.retryable?(reason("worker_turn_failed"))
      refute TurnErrorClassifier.retryable?(%{"code" => "worker_turn_failed"})
    end
  end

  describe "credential_pool_retry_at/2" do
    test "domain pool tuples use the same canonical timestamp as gateway maps" do
      future = DateTime.add(@now, 60, :second)
      tuple = {:credential_pool_exhausted, %{retry_at: DateTime.to_iso8601(future)}}
      assert TurnErrorClassifier.credential_pool_retry_at(tuple, @now) == future
    end

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
