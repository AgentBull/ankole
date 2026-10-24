defmodule Ankole.BackgroundAgentJobs.TurnStateTest do
  use Ankole.AIGatewayCase
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.{Turn, TurnItem}
  alias Ankole.BackgroundAgentJobs.Turns

  @now ~U[2026-10-22 00:00:00.000000Z]

  setup do
    %{principal: agent} = background_agent_fixture()

    {:ok, %{job: job}} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
        "agent_uid" => agent.uid,
        "owner_session_id" => "turn-contract",
        "source_tool_call_id" => "turn-contract",
        "title" => "Check the turn contract",
        "task" => "Record a bounded execution trajectory.",
        "reply_route" => %{"binding_name" => "bot"}
      })

    {:ok, job: job}
  end

  test "a first observed checkpoint retains required state and completion facts", %{job: job} do
    attrs = turn_attrs(job)

    for invalid <- [
          Map.delete(attrs, :status),
          %{attrs | status: :completed},
          Map.put(attrs, :completed_at, @now),
          %{attrs | trajectory: %{"format" => "ankole_chatml", "version" => 1, "pid" => self()}},
          %{attrs | trajectory: %{"format" => "ankole_chatml", "version" => 1, "items" => []}},
          %{attrs | attempt: 0},
          %{attrs | revision: -1},
          Map.put(attrs, :kind, "unrecognized"),
          %{attrs | progress: Map.put(attrs.progress, "tool_calls", 1)},
          %{attrs | progress: Map.put(attrs.progress, "files_changed", ["b", "a"])},
          Map.put(attrs, :usage, %{"thread_total" => %{}})
        ] do
      assert {:error, _} = Repo.transact(fn _ -> Ankole.Ash.create(Turn, :record, invalid) end)
    end

    assert Repo.aggregate(Turn, :count) == 0
    terminal = Map.merge(attrs, %{status: :completed, completed_at: @now})

    assert {:ok, %{status: :completed}} =
             Repo.transact(fn _ -> Ankole.Ash.create(Turn, :record, terminal) end)
  end

  test "a newer checkpoint fences stale snapshots and terminal transitions", %{job: job} do
    assert {:ok, turn} =
             Repo.transact(fn _ -> Ankole.Ash.create(Turn, :record, turn_attrs(job)) end)

    assert {:ok, next} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(turn, :checkpoint, %{revision: 2, next_status: :in_progress})
             end)

    assert {:error, _} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(turn, :checkpoint, %{
                 revision: 3,
                 next_status: :completed,
                 completed_at: @now
               })
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Turn, turn.id), next)

    assert {:ok, completed} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(next, :checkpoint, %{
                 revision: 3,
                 next_status: :completed,
                 completed_at: @now
               })
             end)

    for revision <- [2, 3, 4] do
      assert {:error, _} =
               Repo.transact(fn _ ->
                 Ankole.Ash.update(completed, :checkpoint, %{
                   revision: revision,
                   next_status: :in_progress,
                   completed_at: nil
                 })
               end)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Turn, turn.id), completed)
  end

  test "an identical checkpoint retry preserves optional usage omitted by the Worker", %{job: job} do
    tokens = %{
      "total_tokens" => 1,
      "input_tokens" => 1,
      "cached_input_tokens" => 0,
      "output_tokens" => 0,
      "reasoning_output_tokens" => 0
    }

    usage = %{"thread_total" => tokens, "last_model_call" => tokens}
    attrs = Map.put(turn_attrs(job), :usage, usage)

    assert {:ok, original} =
             Repo.transact(fn _ -> Ankole.Ash.create(Turn, :record, attrs) end)

    assert {:ok, repeated} =
             Repo.transact(fn ->
               Turns.upsert_from_worker_in_tx(
                 %{job | attempts: 1},
                 Map.delete(attrs, :usage)
               )
             end)

    Ankole.DataCase.assert_persisted_equal(repeated, original)
  end

  test "bulk interruption changes each active checkpoint once and rejects late Worker writes", %{
    job: job
  } do
    attrs = turn_attrs(job)
    progress = Map.put(attrs.progress, "active_item", %{"id" => "tool-1", "name" => "shell"})

    assert {:ok, turn} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(Turn, :record, %{attrs | progress: progress})
             end)

    job = %{job | attempts: 1}
    error = %{"code" => "worker_attempt_replaced"}

    for _ <- 1..2 do
      assert {:ok, :ok} =
               Repo.transact(fn ->
                 :ok = Turns.interrupt_active_for_current_attempt_in_tx(job, error, @now)
                 {:ok, :ok}
               end)
    end

    interrupted = Repo.get!(Turn, turn.id)
    assert interrupted.status == :interrupted
    assert interrupted.revision == 2
    assert interrupted.completed_at == @now
    assert interrupted.updated_at == @now
    assert interrupted.error == error
    refute Map.has_key?(interrupted.progress, "active_item")

    assert {:error, _} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(turn, :checkpoint, %{revision: 3, next_status: :in_progress})
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Turn, turn.id), interrupted)
  end

  test "append-only items reject reuse of a position or semantic identity", %{job: job} do
    assert {:ok, turn} =
             Repo.transact(fn _ -> Ankole.Ash.create(Turn, :record, turn_attrs(job)) end)

    attrs = %{
      turn_id: turn.id,
      position: 0,
      revision: 1,
      item_key: "message-1",
      item: %{"type" => "agentMessage", "text" => "Original"}
    }

    assert {:ok, original} =
             Repo.transact(fn _ -> Ankole.Ash.create(TurnItem, :append, attrs) end)

    for conflict <- [%{attrs | position: 1}, %{attrs | item_key: "message-2"}] do
      assert {:error, _} =
               Repo.transact(fn _ -> Ankole.Ash.create(TurnItem, :append, conflict) end)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.all(TurnItem), [original])
  end

  test "a lesson stamp preserves an applied Signal recorded after its Job snapshot", %{job: job} do
    assert {:ok, applied} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(job, :record_applied_signal, %{signal_id: job.source_signal_id})
             end)

    assert {:ok, stamped} = Ankole.Ash.update(job, :record_lessons_applied, %{})
    assert stamped.metadata["applied_source_signal_id"] == job.source_signal_id
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(stamped.metadata["lessons_applied_at"])
    assert Map.delete(stamped.metadata, "lessons_applied_at") == applied.metadata
  end

  defp turn_attrs(job) do
    %{
      job_id: job.id,
      attempt: 1,
      runtime_thread_id: "thread-1",
      runtime_turn_id: "turn-1",
      status: :in_progress,
      revision: 1,
      trajectory: %{"format" => "ankole_chatml", "version" => 1},
      progress: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      },
      started_at: @now
    }
  end
end
