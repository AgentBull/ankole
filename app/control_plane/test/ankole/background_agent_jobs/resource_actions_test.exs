defmodule Ankole.BackgroundAgentJobs.ResourceActionsTest do
  use Ankole.AIGatewayCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  setup do
    %{principal: agent} = background_agent_fixture()

    {:ok, %{job: job}} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
        "agent_uid" => agent.uid,
        "owner_session_id" => "job-actions",
        "source_tool_call_id" => "job-actions",
        "title" => "Check Job state",
        "task" => "Preserve the original wait budget.",
        "reply_route" => %{"binding_name" => "bot"}
      })

    %{job: job}
  end

  test "worker wait keeps its first clock across old snapshots and repeated clearing", %{job: job} do
    first_at = DateTime.utc_now(:microsecond)
    later = DateTime.add(first_at, 30)

    assert {:ok, waiting} =
             Repo.transact(fn _ -> JobState.begin_worker_wait_in_tx(job, first_at) end)

    assert waiting.worker_wait_started_at == first_at
    assert waiting.updated_at == first_at

    assert {:ok, ^waiting} =
             Repo.transact(fn _ -> JobState.begin_worker_wait_in_tx(job, later) end)

    assert {:ok, cleared} =
             Repo.transact(fn _ -> JobState.clear_worker_wait_in_tx(job, later) end)

    assert cleared.worker_wait_started_at == nil
    assert cleared.updated_at == later

    assert {:ok, ^cleared} =
             Repo.transact(fn _ ->
               JobState.clear_worker_wait_in_tx(waiting, DateTime.add(later, 30))
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Job, job.id), cleared)
  end

  test "touch updates only the clock and retains metadata written after its snapshot", %{job: job} do
    assert {:ok, applied} =
             transition_job(job, :record_applied_signal, %{signal_id: job.source_signal_id})

    at = DateTime.add(job.updated_at, 30)
    assert {:ok, touched} = Repo.transact(fn _ -> JobState.touch_in_tx(job, at) end)
    assert touched.updated_at == at
    persisted = Repo.get!(Job, job.id)
    Ankole.DataCase.assert_persisted_equal(%{persisted | updated_at: applied.updated_at}, applied)
    Ankole.DataCase.assert_persisted_equal(touched, persisted)
  end

  test "native fields reject invalid Job values before creation", %{job: job} do
    creation_attrs = %{
      authorization_kind: "service",
      agent_uid: job.agent_uid,
      owner_session_id: job.owner_session_id,
      workspace_owner_job_id: job.workspace_owner_job_id,
      source_tool_call_id: "validated-job",
      title: "Validate Job inputs",
      task: "Preserve the action contract."
    }

    for attrs <- [
          %{agent_uid: nil},
          %{owner_session_id: "  "},
          %{workspace_owner_job_id: nil},
          %{reply_route: %{"callback" => self()}},
          %{attempts: -1},
          %{execution_failures: -1},
          %{task: " \n "},
          %{model_profile: "Invalid profile"},
          %{workspace_template_id: "../escape"},
          %{result: %{"invalid" => self()}},
          %{metadata: nil}
        ] do
      assert {:error, _} =
               Repo.transact(fn _ ->
                 Ankole.Ash.create(Job, :create_job, Map.merge(creation_attrs, attrs))
               end)

      Ankole.DataCase.assert_persisted_equal(Repo.get!(Job, job.id), job)
    end

    assert {:ok, created} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(
                 Job,
                 :create_job,
                 Map.merge(creation_attrs, %{
                   model_profile: " coding ",
                   result: %{"observed_at" => ~U[2026-10-22 00:00:00Z]}
                 })
               )
             end)

    assert created.status == :queued
    assert created.model_profile == "coding"
    assert created.result == %{"observed_at" => "2026-10-22T00:00:00Z"}
  end

  test "lifecycle actions reject ownership changes and unknown fields", %{job: job} do
    for action <- [
          :claim_attempt,
          :claim_continuation,
          :external_complete,
          :fail_admission,
          :stop,
          :stop_human_work
        ],
        attrs <- [
          %{owner_session_id: "another-session"},
          %{authorization_kind: "review_required"},
          %{model_profile: "review"},
          %{reslut: %{}}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = transition_job(job, action, attrs)
      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
      Ankole.DataCase.assert_persisted_equal(Repo.get!(Job, job.id), job)
    end

    assert {:ok, running} = transition_job(job, :claim_attempt, %{attempts: 1})

    for attrs <- [
          %{owner_session_id: "another-session"},
          %{authorization_kind: "review_required"},
          %{attempts: 99},
          %{model_profile: "review"},
          %{reslut: %{}}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               transition_job(running, :worker_report, Map.put(attrs, :next_status, :running))

      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
      Ankole.DataCase.assert_persisted_equal(Repo.get!(Job, job.id), running)
    end

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, job.agent_uid, %{
               "status" => :running,
               "reslut" => %{"summary" => "must not be discarded"}
             })

    assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: "reslut"}, &1))
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Job, job.id), running)
  end

  defp transition_job(job, action, attrs),
    do: Repo.transact(fn _ -> Ankole.Ash.update(job, action, attrs) end)
end
