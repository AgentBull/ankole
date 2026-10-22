defmodule Ankole.Signals.StateMachineTest do
  use Ankole.DataCase, async: false

  alias Ankole.Principals.Principal
  alias Ankole.Sessions.Queue

  setup do
    {:ok, agent} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(Principal, :create_in_tx, %{
          uid: "signal-state-#{System.unique_integer([:positive])}",
          type: :agent,
          display_name: "Signal state test"
        })
      end)

    %{agent: agent}
  end

  test "intake owns the initial state and preserves source identity", %{agent: agent} do
    attrs = intake(agent)
    assert {:ok, first} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs))
    assert first.status == :queued
    assert first.attempt_count == 0
    assert first.last_attempt_at == nil
    assert {:ok, duplicate} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs))
    assert duplicate.id == first.id
    assert duplicate.queue_sequence == first.queue_sequence

    assert {:error, :signal_producer_conflict} =
             Repo.transact(&Ankole.Signals.accept_in_tx(&1, %{attrs | producer: :external}))
  end

  test "admission, capacity defer and refund preserve the distinct attempt budgets", %{
    agent: agent
  } do
    signal = signal(agent)
    now = DateTime.utc_now(:microsecond)
    assert {:ok, running} = transition(signal, :admit, %{last_attempt_at: now})
    assert %{status: :running, attempt_count: 1, provider_capacity_attempt_count: 0} = running
    assert {:ok, reclaimed} = transition(running, :admit, %{last_attempt_at: now})
    assert reclaimed.attempt_count == 2

    assert {:ok, deferred} =
             transition(reclaimed, :defer, %{
               available_at: DateTime.add(now, 30),
               provider_capacity?: true
             })

    assert deferred.status == :queued
    assert deferred.last_attempt_at == now

    assert {:ok, retried} =
             transition(deferred, :admit, %{last_attempt_at: DateTime.add(now, 30)})

    assert retried.attempt_count == 3
    assert retried.provider_capacity_attempt_count == 1
    assert {:ok, refunded} = transition(retried, :refund_attempt, %{})
    assert %{status: :running, attempt_count: 2, provider_capacity_attempt_count: 1} = refunded
    assert {:ok, refunded} = transition(refunded, :refund_attempt, %{})
    assert refunded.attempt_count == 1

    assert {:ok, at_floor} = transition(refunded, :refund_attempt, %{})
    assert %{status: :running, attempt_count: 1, provider_capacity_attempt_count: 1} = at_floor
    Ankole.DataCase.assert_persisted_equal(Repo.reload!(at_floor), at_floor)
  end

  test "attempt counters use persisted values and refunds cannot cross either floor", %{
    agent: agent
  } do
    queued = signal(agent)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, zero} = transition(queued, :refund_attempt, %{})
    assert %{status: :queued, attempt_count: 0, provider_capacity_attempt_count: 0} = zero

    for expected <- 1..3 do
      assert {:ok, admitted} = transition(queued, :admit, %{last_attempt_at: now})
      assert admitted.attempt_count == expected
    end

    running = Repo.reload!(queued)

    for expected <- 1..2 do
      assert {:ok, deferred} =
               transition(running, :defer, %{available_at: now, provider_capacity?: true})

      assert deferred.attempt_count == 3
      assert deferred.provider_capacity_attempt_count == expected
    end

    for _ <- 1..3 do
      assert {:ok, refunded} = transition(running, :refund_attempt, %{})
      assert refunded.attempt_count == 2

      assert %{status: :queued, attempt_count: 2, provider_capacity_attempt_count: 2} =
               Repo.reload!(refunded)
    end

    triage = signal(agent)

    for expected <- 1..2 do
      assert {:ok, retried} = transition(triage, :retry_triage, %{available_at: now})
      assert retried.attempt_count == expected
    end
  end

  test "Ambient NOOP can complete queued work and terminal states cannot restart", %{agent: agent} do
    signal = signal(agent)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, completed} =
             Repo.transact(fn repo ->
               Queue.mark_turn_event_completed_in_tx(repo, signal, now, nil, "silent")
             end)

    assert %{status: :completed, last_attempt_at: nil, attempt_count: 0} = completed
    assert {:error, %Ash.Error.Invalid{}} = transition(completed, :admit, %{last_attempt_at: now})

    assert {:ok, dead} =
             transition(signal(agent), :dead_letter, %{
               dead_letter_at: now,
               dead_letter_reason: %{"reason" => "poison"}
             })

    assert {:error, %Ash.Error.Invalid{}} = transition(dead, :defer, %{available_at: now})

    assert {:error, :signal_already_dead_lettered} =
             Repo.transact(fn repo ->
               Queue.mark_turn_event_completed_in_tx(repo, dead, now, nil, "silent")
             end)
  end

  test "PostgreSQL rejects illegal state evidence even when actions are bypassed", %{agent: agent} do
    signal = signal(agent)

    for assignment <- [
          "status = 'running', last_attempt_at = NULL",
          "status = 'completed', completed_at = NULL",
          "status = 'queued', completed_at = now()",
          "status = 'dead_letter', dead_letter_at = NULL, dead_letter_reason = '{}'",
          "status = 'dead_letter', dead_letter_at = now(), dead_letter_reason = NULL",
          "status = 'dead_letter', dead_letter_at = now(), dead_letter_reason = '[]'",
          "status = 'dead_letter', dead_letter_at = now(), dead_letter_reason = '{}', completed_at = now()"
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE signals SET #{assignment} WHERE id = $1",
            [Ecto.UUID.dump!(signal.id)],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == "signals_lifecycle_check"
    end

    assert Repo.reload!(signal).status == :queued
  end

  test "preview creation reports the real tenant and Signal foreign key" do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(Ankole.Conversations.Delivery.PreviewState, :ensure, %{
                 signal_id: Ecto.UUID.generate()
               })
             end)

    assert [%{path: "signal_id", message: "does not exist"}] =
             Ankole.Ash.validation_details(error)
  end

  test "revocation is atomic and leaves admitted work able to finish", %{agent: agent} do
    human_uid = "human-#{System.unique_integer([:positive])}"

    {:ok, _human} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(Principal, :create_in_tx, %{
          uid: human_uid,
          type: :human,
          display_name: "Signal author"
        })
      end)

    auth = %{authorization_kind: "human", human_uid: human_uid, human_access_version: 1}
    {:ok, queued} = transition(signal(agent), :reauthorize, auth)
    {:ok, admitted} = transition(signal(agent), :reauthorize, auth)
    now = DateTime.utc_now(:microsecond)
    {:ok, admitted} = transition(admitted, :admit, %{last_attempt_at: now})

    assert {:ok, {1, nil}} =
             Repo.transact(fn repo ->
               Queue.stop_human_work_in_tx(repo, human_uid, 2, now) |> then(&{:ok, &1})
             end)

    assert Repo.reload!(queued).status == :dead_letter
    assert Repo.reload!(admitted).status == :running
  end

  defp transition(signal, action, attrs),
    do: Repo.transact(fn _ -> Ankole.Ash.update(signal, action, attrs) end)

  defp signal(agent) do
    {:ok, signal} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, intake(agent)))
    signal
  end

  defp intake(agent),
    do: %{
      producer: :kernel,
      source: "state-test",
      id: "signal-#{System.unique_integer([:positive])}",
      type: "test.signal",
      target: %{agent_uid: agent.uid, session_id: "state-test"},
      authorization: %{authorization_kind: "service"},
      data: %{}
    }
end
