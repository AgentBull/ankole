defmodule Ankole.Sessions.JobDriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ankole.Sessions.JobDriver

  test "failed operations keep their retry and omit private request data from logs" do
    private_request = "private-job-request-#{System.unique_integer([:positive])}"

    for operation <- [:start, :mailbox, :observe] do
      ref = make_ref()
      data = %{tasks: %{ref => {operation, self()}}, mailbox_dirty: false}
      reason = {:task_exit, {:killed, {GenServer, :call, [self(), private_request, 15_000]}}}

      log =
        capture_log([format: "$metadata $message\n", metadata: :all], fn ->
          assert {:keep_state, %{tasks: %{}}, [{:state_timeout, retry_ms, :poll}]} =
                   JobDriver.handle_event(:info, {ref, {:error, reason}}, :running, data)

          assert retry_ms == 60_000
        end)

      assert log =~ "sessions.job_driver.operation_failed"
      assert log =~ "operation=#{operation}"
      refute log =~ private_request
    end
  end
end
