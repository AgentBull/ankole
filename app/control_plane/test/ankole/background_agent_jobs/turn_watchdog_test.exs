defmodule Ankole.BackgroundAgentJobs.TurnWatchdogTest do
  use Ankole.SessionsCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.TurnWatchdog
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.CodexJob
  alias Ankole.AgentWorkers.WorkerRouteAuth

  @grace_seconds 3600

  test "a Turn that keeps recording progress is never treated as stalled" do
    %{job: job, agent: agent, checkpoint_at: checkpoint_at} = start_job_turn("live")

    assert {:ok, :live} =
             Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id,
               now: DateTime.add(checkpoint_at, @grace_seconds - 1, :second)
             )

    assert Repo.one!(from(turn in Turn, where: turn.job_id == ^job.id)).status == :in_progress
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == :running
  end

  test "a silent Turn is interrupted and its actor event stays open for retry" do
    %{job: job, agent: agent, event: event, ref: ref, checkpoint_at: checkpoint_at} =
      start_job_turn("stalled")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} =
             Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id, now: stalled_at)

    turn = Repo.one!(from(turn in Turn, where: turn.job_id == ^job.id))
    assert turn.status == :interrupted
    assert turn.error["code"] == TurnWatchdog.stall_code()
    assert %DateTime{} = turn.completed_at

    assert {:error, :background_agent_job_attempt_changed} =
             Repo.transact(fn repo ->
               WorkerRouteAuth.authorize_turn_in_tx(repo, ref, agent.uid, :write)
             end)

    # The Job keeps its retry budget: the event is still open and rescheduled.
    reloaded_event = Repo.get!(Signal, event.id)
    assert reloaded_event.status == :queued
    assert DateTime.compare(reloaded_event.available_at, stalled_at) == :gt
    # R1: the stalled attempt returns the Job to `queued` and the stall charges
    # one execution failure. See internals/docs/BackgroundAgentJobReliability.zh.md.
    assert %{status: :queued, execution_failures: 1} =
             BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)

    # The Worker is told to stop spending tokens on the abandoned Turn.
    assert_receive {:actor_lane, control_envelope}, 200
    control = envelope_body!(control_envelope, :turn_control)
    assert control.command == "retry"
    assert control.turn.signal_id == event.id
  end

  test "a stall that marked lead and child Turns counts once toward the retry budget" do
    %{job: job, agent: agent, event: event, checkpoint_at: checkpoint_at} =
      start_job_turn("delegated", 2)

    insert_stalled_turn!(job, 1, "turn-stalled-lead")
    insert_stalled_turn!(job, 1, "turn-stalled-child")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} =
             Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id, now: stalled_at)

    # One earlier stall left two rows, so this is the second stall, not the third.
    assert Repo.get!(Signal, event.id).status == :queued
    # R1: the stalled attempt returns the Job to `queued` and the stall charges
    # one execution failure. See internals/docs/BackgroundAgentJobReliability.zh.md.
    assert %{status: :queued, execution_failures: 2} =
             BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
  end

  test "the third stall fails the Job instead of retrying it forever" do
    %{job: job, agent: agent, event: event, checkpoint_at: checkpoint_at} =
      start_job_turn("exhausted", 3)

    insert_stalled_turn!(job, 1, "turn-stalled-1")
    insert_stalled_turn!(job, 2, "turn-stalled-2-lead")
    insert_stalled_turn!(job, 2, "turn-stalled-2-child")

    stalled_at = DateTime.add(checkpoint_at, @grace_seconds + 1, :second)

    assert {:ok, :stalled} =
             Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id, now: stalled_at)

    failed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert failed.status == :failed
    assert failed.error["code"] == TurnWatchdog.stall_code()
    assert Repo.get!(Signal, event.id).status == :dead_letter
  end

  test "an accepted attempt with no trajectory still has a bounded silence" do
    %{job: job} = start_job_turn("terminal-turn")

    Repo.update_all(from(turn in Turn, where: turn.job_id == ^job.id),
      set: [status: :completed, completed_at: DateTime.utc_now(:microsecond)]
    )

    assert {:ok, :live} = Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id)

    Repo.update!(
      Ecto.Changeset.change(job,
        updated_at: DateTime.add(DateTime.utc_now(:microsecond), -@grace_seconds - 2)
      )
    )

    assert {:ok, :stalled} = Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(job.id)
    assert BackgroundAgentJobs.get_job_for_agent(job.id, job.agent_uid).status == :queued
  end

  defp start_job_turn(suffix, attempt \\ 1) do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route, %{worker_id: agent.uid})

    assert {:ok, %{job: job, dispatch_event: event}} =
             Repo.transact(fn repo ->
               BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(repo, %{
                 "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => "owner-session-stall-#{suffix}",
                 "source_tool_call_id" => "tool-stall-#{suffix}",
                 "title" => "Stall #{suffix}",
                 "task" => "Keep working on #{suffix}.",
                 "reply_route" => %{
                   "binding_name" => "bot",
                   "conversation_id" =>
                     Ankole.ExternalConversationsFixtures.external_conversation_id(
                       "chat-#{suffix}"
                     )
                 }
               })
             end)

    # Earlier attempts have committed their failures before this claim.
    Repo.update!(
      Ecto.Changeset.change(job, attempts: attempt - 1, execution_failures: attempt - 1)
    )

    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, run} = Admission.admit(session_key, event)
    assert {:ok, _} = CodexJob.start(run)
    assert_receive {:actor_lane, _envelope}, 200
    turn_ref = run.job_ref
    checkpoint_at = DateTime.add(DateTime.utc_now(:microsecond), -@grace_seconds - 2)

    assert {:ok, turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => attempt,
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
               agent.uid
             )

    turn = Repo.update!(Ecto.Changeset.change(turn, updated_at: checkpoint_at))

    %{
      ref: turn_ref,
      agent: agent,
      job: BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid),
      event: event,
      turn: turn,
      checkpoint_at: turn.updated_at
    }
  end

  defp insert_stalled_turn!(job, attempt, runtime_turn_id) do
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn _ ->
           Ankole.Ash.create(Turn, :record, %{
             job_id: job.id,
             attempt: attempt,
             runtime_thread_id: "thread-stalled-history",
             runtime_turn_id: runtime_turn_id,
             kind: "agent",
             status: :interrupted,
             revision: 1,
             trajectory: %{"format" => "ankole_chatml", "version" => 1},
             progress: %{
               "completed_items" => 0,
               "tool_calls" => 0,
               "tools_used" => [],
               "files_changed" => []
             },
             error: %{
               "code" => TurnWatchdog.stall_code(),
               "summary" => "runtime Turn recorded no durable progress before the stall deadline"
             },
             started_at: now,
             completed_at: now
           })
         end) do
      {:ok, record} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end
end
