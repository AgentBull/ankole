defmodule Ankole.Sessions.EpochTraceTest do
  @moduledoc """
  Model-driven trace conformance for the Session workspace epoch fence.

  `tools/formal/lean/SessionEpoch.lean` proves that a stale run cannot commit,
  that admission advances the epoch and charges one attempt, and that the
  deliberate stale-refund path decrements the live attempt without an attempt
  identity. This test drives the real `Admission.admit/2`, `Fence`, and
  `Run.refund_in_tx/2` against PostgreSQL.
  """

  use Ankole.SessionsCase

  alias Ankole.Sessions.{Admission, Fence, Run, Workspaces}
  alias Ankole.Signals

  @moduletag :trace_conformance

  test "admission advances the epoch, fences the old run, and refunds its attempt" do
    %{principal: agent} = agent_fixture()
    session_id = "epoch-trace-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Repo.transact(fn -> Workspaces.ensure_in_tx(agent.uid, session_id) end)

    assert workspace.epoch == 0
    session_id = workspace.session_id
    key = %{agent_uid: agent.uid, session_id: session_id}
    now = DateTime.utc_now(:microsecond)

    {:ok, signal} =
      Repo.transact(fn ->
        Signals.accept_in_tx(%{
          source: "test://epoch",
          id: Ecto.UUID.generate(),
          type: "test.work",
          time: now,
          target: key,
          sender: agent.uid,
          authorization: Ankole.Principals.WorkAccess.service(),
          data: %{}
        })
      end)

    assert {:ok, %Run{} = run} = Admission.admit(key, signal)
    assert run.epoch == 1
    assert run.event.status == :running
    assert run.event.attempt_count == 1
    assert Repo.reload!(workspace).epoch == 1

    assert {:ok, :ok} = Repo.transact(fn -> {:ok, Fence.check_in_tx(run)} end)

    assert {:ok, %Run{} = replacement} = Admission.admit(key, Repo.reload!(signal))
    assert replacement.epoch == 2
    assert replacement.event.status == :running
    assert replacement.event.attempt_count == 2
    assert Repo.reload!(workspace).epoch == 2

    assert {:error, :stale_driver} = Repo.transact(fn -> Fence.check_in_tx(run) end)
    assert {:ok, :ok} = Repo.transact(fn -> {:ok, Fence.check_in_tx(replacement)} end)

    assert {:ok, _} = Repo.transact(fn -> Run.refund_in_tx(run, :stale_driver) end)
    assert %Signal{status: :running, attempt_count: 1} = Repo.get!(Signal, signal.id)
  end

  test "the fence rejects a closed signal even at the current epoch" do
    %{principal: agent} = agent_fixture()
    session_id = "epoch-closed-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Repo.transact(fn -> Workspaces.ensure_in_tx(agent.uid, session_id) end)

    session_id = workspace.session_id
    now = DateTime.utc_now(:microsecond)

    {:ok, signal} =
      Repo.transact(fn ->
        Signals.accept_in_tx(%{
          source: "test://epoch",
          id: Ecto.UUID.generate(),
          type: "test.work",
          time: now,
          target: %{agent_uid: agent.uid, session_id: session_id},
          sender: agent.uid,
          authorization: Ankole.Principals.WorkAccess.service(),
          data: %{}
        })
      end)

    {:ok, completed} =
      Repo.transact(fn ->
        Signals.transition_in_tx(signal, :complete, %{completed_at: now})
      end)

    run = %Run{
      agent_uid: agent.uid,
      session_id: session_id,
      signal_id: completed.id,
      epoch: workspace.epoch,
      event: completed
    }

    assert {:error, :run_closed} = Repo.transact(fn -> Fence.check_in_tx(run) end)
  end
end
