defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobTurnStallTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.TurnWatchdog
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @grace_seconds TurnWatchdog.stall_grace_seconds()

  test "a Turn that keeps recording progress is never treated as stalled" do
    %{job: job, agent: agent, checkpoint_at: checkpoint_at} = start_job_turn("live")

    assert {:ok, :live} =
             BackgroundAgentJobs.reconcile_stuck_job(job.id,
               now: DateTime.add(checkpoint_at, @grace_seconds - 1, :second)
             )

    assert Repo.one!(from(turn in Turn, where: turn.job_id == ^job.id)).status == "in_progress"
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == "running"
  end

  test "a silent Turn is interrupted and its actor event stays open for retry" do
    %{job: job, agent: agent, event: event, checkpoint_at: checkpoint_at} =
      start_job_turn("stalled")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} = BackgroundAgentJobs.reconcile_stuck_job(job.id, now: stalled_at)

    turn = Repo.one!(from(turn in Turn, where: turn.job_id == ^job.id))
    assert turn.status == "interrupted"
    assert turn.error["code"] == TurnWatchdog.stall_code()
    assert %DateTime{} = turn.completed_at

    # The runtime fence is gone, so nothing the zombie Worker sends can land.
    assert Repo.get_by!(ActorSessionActivation, session_id: job_session_id(job)).status ==
             "failed"

    # The Job keeps its retry budget: the event is still open and rescheduled.
    reloaded_event = Repo.get!(ActorEvent, event.id)
    assert reloaded_event.input_state == "open"
    assert DateTime.compare(reloaded_event.available_at, stalled_at) == :gt
    # R1: the stalled attempt returns the Job to `queued` and the stall charges
    # one execution failure. See internals/docs/BackgroundAgentJobReliability.zh.md.
    assert %{status: "queued", execution_failures: 1} =
             BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)

    # The Worker is told to stop spending tokens on the abandoned Turn.
    assert_receive {:actor_lane, control_envelope}, 200
    control = envelope_body!(control_envelope, :turn_control)
    assert control.command == "retry"
    assert control.turn.actor_event_id == event.id
  end

  test "a stall that marked lead and child Turns counts once toward the retry budget" do
    %{job: job, agent: agent, event: event, checkpoint_at: checkpoint_at} =
      start_job_turn("delegated")

    insert_stalled_turn!(job, 1, "turn-stalled-lead")
    insert_stalled_turn!(job, 1, "turn-stalled-child")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} = BackgroundAgentJobs.reconcile_stuck_job(job.id, now: stalled_at)

    # One earlier stall left two rows, so this is the second stall, not the third.
    assert Repo.get!(ActorEvent, event.id).input_state == "open"
    # R1: the stalled attempt returns the Job to `queued` and the stall charges
    # one execution failure. See internals/docs/BackgroundAgentJobReliability.zh.md.
    assert %{status: "queued", execution_failures: 1} =
             BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
  end

  test "the third stall fails the Job instead of retrying it forever" do
    %{job: job, agent: agent, event: event, checkpoint_at: checkpoint_at} =
      start_job_turn("exhausted")

    insert_stalled_turn!(job, 1, "turn-stalled-1")
    insert_stalled_turn!(job, 2, "turn-stalled-2-lead")
    insert_stalled_turn!(job, 2, "turn-stalled-2-child")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} = BackgroundAgentJobs.reconcile_stuck_job(job.id, now: stalled_at)

    failed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert failed.status == "failed"
    assert failed.error["code"] == TurnWatchdog.stall_code()
    assert Repo.get!(ActorEvent, event.id).input_state == "dead_letter"
  end

  test "a Job with no in-progress Turn is left to the activation and Worker deadlines" do
    %{job: job} = start_job_turn("terminal-turn")

    Repo.update_all(from(turn in Turn, where: turn.job_id == ^job.id),
      set: [status: "completed", completed_at: DateTime.utc_now(:microsecond)]
    )

    assert {:ok, :no_active_turn} =
             BackgroundAgentJobs.reconcile_stuck_job(job.id,
               now: DateTime.add(@base_time, 10 * @grace_seconds, :second)
             )
  end

  test "the boot snapshot re-arms one deadline per Job with an in-progress Turn" do
    %{job: job, checkpoint_at: checkpoint_at} = start_job_turn("snapshot")
    channel = RuntimeEvents.job_turn_deadline_channel()
    stuck_at = RuntimeEvents.encode_datetime(DateTime.add(checkpoint_at, @grace_seconds, :second))

    assert [{^channel, %{"job_id" => job_id, "stuck_at" => ^stuck_at}}] =
             BackgroundAgentJobs.runtime_event_snapshot()

    assert job_id == job.id

    assert [%Ankole.RuntimeEvents.Event{kind: :job_turn_deadline, timer_key: {^channel, ^job_id}}] =
             RuntimeEvents.expand(channel, %{"job_id" => job_id, "stuck_at" => stuck_at})
  end

  defp start_job_turn(suffix) do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{job: job, dispatch_event: event}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "owner-session-stall-#{suffix}",
               "source_tool_call_id" => "tool-stall-#{suffix}",
               "title" => "Stall #{suffix}",
               "task" => "Keep working on #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "chat-#{suffix}"
               }
             })

    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    assert {:ok, turn_ref} = TurnRef.from_proto(turn_start_payload!(envelope).turn)
    checkpoint_at = DateTime.utc_now(:microsecond)

    assert {:ok, turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-stall-#{suffix}",
                 "runtime_turn_id" => "turn-stall-#{suffix}",
                 "kind" => "agent",
                 "status" => "in_progress",
                 "revision" => 0,
                 "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
                 "turn_items" => [
                   %{
                     "position" => 0,
                     "item_key" => "test:0",
                     "item" => %{
                       "type" => "userMessage",
                       "id" => "test:0",
                       "content" => [%{"type" => "text", "text" => "Start #{suffix}"}]
                     }
                   }
                 ],
                 "progress" => %{
                   "completed_items" => 0,
                   "tool_calls" => 0,
                   "tools_used" => [],
                   "files_changed" => []
                 },
                 "usage" => nil,
                 "error" => %{},
                 "started_at" => checkpoint_at
               },
               turn_ref,
               route
             )

    %{
      agent: agent,
      job: BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid),
      event: event,
      turn: turn,
      checkpoint_at: turn.updated_at
    }
  end

  defp insert_stalled_turn!(job, attempt, runtime_turn_id) do
    now = DateTime.utc_now(:microsecond)

    %Turn{}
    |> Turn.changeset(%{
      job_id: job.id,
      attempt: attempt,
      runtime_thread_id: "thread-stalled-history",
      runtime_turn_id: runtime_turn_id,
      kind: "agent",
      status: "interrupted",
      revision: 1,
      trajectory: %{"format" => "ankole_chatml", "version" => 1},
      progress: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      },
      error: %{"code" => TurnWatchdog.stall_code(), "summary" => TurnWatchdog.stall_summary()},
      started_at: now,
      completed_at: now
    })
    |> Repo.insert!()
  end

  defp job_session_id(job), do: BackgroundAgentJobs.job_session_id(job.id)
end
