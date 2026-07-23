defmodule Ankole.AIGateway.ResponseStreamTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ResponseStream.Supervisor

  test "a provider waiting for ready does not block other stream starts" do
    test_pid = self()

    slow_open = fn ->
      send(test_pid, {:slow_open_started, self()})

      receive do
        :release_slow_open -> {:error, :released}
      end
    end

    slow_starter = Task.async(fn -> Supervisor.start_stream(stream_opts(slow_open)) end)
    assert {:ok, slow_pid} = Task.await(slow_starter, 1_000)
    assert_receive {:slow_open_started, ^slow_pid}

    fast_open = fn ->
      send(test_pid, {:fast_open_started, self()})
      {:error, :fast_failed}
    end

    fast_starter = Task.async(fn -> Supervisor.start_stream(stream_opts(fast_open)) end)
    assert {:ok, fast_pid} = Task.await(fast_starter, 1_000)
    assert_receive {:fast_open_started, ^fast_pid}

    slow_monitor = Process.monitor(slow_pid)
    fast_monitor = Process.monitor(fast_pid)

    assert {:error, :fast_failed} = GenServer.call(fast_pid, :describe)
    assert_receive {:DOWN, ^fast_monitor, :process, ^fast_pid, :normal}

    send(slow_pid, :release_slow_open)
    assert {:error, :released} = GenServer.call(slow_pid, :describe)

    assert_receive {:DOWN, ^slow_monitor, :process, ^slow_pid, :normal}, 2_000
  end

  test "provider terminal retry classification uses stable fields instead of messages" do
    retryable_event =
      failed_event(%{
        "code" => "rate_limit_exceeded",
        "message" => "opaque provider text"
      })

    assert {:ok, _state, [public_event],
            {:terminal,
             %{
               terminal_error: %{
                 "message" => "The upstream provider request failed.",
                 "retryable" => true
               }
             }, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), retryable_event, 0)

    assert get_in(public_event, ["response", "error"]) == %{
             "code" => "rate_limit_exceeded",
             "failure_kind" => "provider_response",
             "message" => "The upstream provider request failed.",
             "provider_error_code" => "rate_limit_exceeded",
             "retryable" => true
           }

    refute Ankole.JSON.encode!(public_event) =~ "opaque provider text"

    non_retryable_event =
      failed_event(%{
        "code" => "invalid_request",
        "message" => "rate limit 429 too many requests"
      })

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_error: terminal_error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), non_retryable_event, 0)

    assert terminal_error["retryable"] == false
    assert terminal_error["code"] == "invalid_request"
    assert terminal_error["message"] == "The upstream provider request failed."
    refute Ankole.JSON.encode!(terminal_error) =~ "rate limit 429 too many requests"
    refute Ankole.JSON.encode!(public_event) =~ "rate limit 429 too many requests"
  end

  defp stream_opts(open_fun) do
    [
      subject_uid: "agent_test",
      request: %{},
      stateful: nil,
      receiver: self(),
      telemetry_spec: %{},
      open_fun: open_fun
    ]
  end

  defp failed_event(error) do
    %{
      "type" => "response.failed",
      "sequence_number" => 0,
      "response" => %{
        "id" => "provider-response",
        "object" => "response",
        "status" => "failed",
        "error" => error,
        "output" => []
      }
    }
  end
end
