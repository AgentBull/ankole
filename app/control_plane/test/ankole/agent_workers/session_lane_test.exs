defmodule Ankole.AgentWorkers.SessionLaneTest do
  use Ankole.SessionsCase
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.SessionLane

  test "Job acceptance still checks the persisted running attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _} = admit_worker(route)

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => "actor-lane-owner",
               "source_tool_call_id" => "actor-lane-job",
               "title" => "Job",
               "task" => "Run once",
               "reply_route" => %{"binding_name" => "bot"}
             })

    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, %{event: event}} = Run.rebuild(key, DateTime.add(job.queued_at, 1, :second))
    assert {:ok, run} = CodexJob.admit(key, event, [])

    envelope = %FabricProto.Envelope{
      body:
        {:turn_accepted,
         %FabricProto.TurnAccepted{turn: Ankole.Sessions.JobTurnRef.to_proto(run.job_ref)}}
    }

    assert :ok = SessionLane.handle(envelope, %{worker_id: agent.uid})

    assert {:ok, %{job: %{status: "stopped"}}} =
             BackgroundAgentJobs.request_stop(job.id, %{"agent_uid" => agent.uid})

    assert {:error, :background_agent_job_attempt_changed} =
             SessionLane.handle(envelope, %{worker_id: agent.uid})
  end
end
