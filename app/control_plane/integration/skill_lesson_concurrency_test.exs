defmodule Ankole.SkillLessonConcurrencyTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ecto.Adapters.SQL.Sandbox

  setup %{tenant: tenant} do
    provider = worker_provider_fixture()
    %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})

    assert {:ok, %{accepted: [lesson], rejected: []}} =
             Library.apply_skill_lesson_adds(
               agent.uid,
               [
                 %{
                   "skill_name" => "pdf",
                   "content" => "Render a page before retrying extraction.",
                   "evidence_job_ids" => [1001, 1002]
                 }
               ],
               %{
                 evidence_job_ids: MapSet.new([1001, 1002]),
                 human_input_job_ids: MapSet.new(),
                 checked_release: "first"
               }
             )

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(agent.uid, provider.provider_id)
        cleanup_tenant!(tenant)
      end)
    end)

    %{agent: agent, lesson: lesson}
  end

  test "a review waits for Human retirement and preserves permanent immunity", %{
    agent: agent,
    lesson: lesson
  } do
    human =
      start(fn -> hold_write(fn -> Library.retire_skill_lesson(agent.uid, lesson.id) end) end)

    assert_receive {:write_held, pid}, 5_000
    assert pid == human.task.pid
    review = start(fn -> renew(agent.uid, lesson.id) end)
    assert_blocked_by(review, human)
    send(human.task.pid, :commit)
    assert {:ok, %AgentSkillLesson{retire_reason: :human_revoked}} = Task.await(human.task, 5_000)

    assert {:ok, %{renewed: 0, rejected: [%{reason: :not_reviewable}]}} =
             Task.await(review.task, 5_000)

    assert %AgentSkillLesson{retire_reason: :human_revoked, checked_release: "first"} =
             Repo.get!(AgentSkillLesson, lesson.id)
  end

  test "Human retirement waits for a review and remains terminal", %{agent: agent, lesson: lesson} do
    review = start(fn -> hold_write(fn -> renew(agent.uid, lesson.id) end) end)
    assert_receive {:write_held, pid}, 5_000
    assert pid == review.task.pid
    human = start(fn -> Library.retire_skill_lesson(agent.uid, lesson.id) end)
    assert_blocked_by(human, review)
    send(review.task.pid, :commit)
    assert {:ok, %{renewed: 1, rejected: []}} = Task.await(review.task, 5_000)
    assert {:ok, %AgentSkillLesson{retire_reason: :human_revoked}} = Task.await(human.task, 5_000)

    assert %AgentSkillLesson{retire_reason: :human_revoked, checked_release: "reviewed"} =
             Repo.get!(AgentSkillLesson, lesson.id)
  end

  defp renew(agent_uid, lesson_id) do
    Library.apply_skill_lesson_reviews(
      agent_uid,
      [%{"lesson_id" => lesson_id, "verdict" => "renew", "evidence_job_ids" => [1001]}],
      MapSet.new([lesson_id]),
      %{index_job_ids: MapSet.new([1001]), checked_release: "reviewed"}
    )
  end

  defp start(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)
        Process.put({__MODULE__, :parent}, parent)

        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.()
        end)
      end)

    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp hold_write(fun) do
    handler = {__MODULE__, self()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and String.starts_with?(metadata.query, "UPDATE") and
               String.contains?(metadata.query, "agent_skill_lessons") do
            send(Process.get({__MODULE__, :parent}), {:write_held, self()})

            receive do
              :commit -> :ok
            after
              10_000 -> raise "test did not release its lesson write"
            end
          end
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end
  end

  defp assert_blocked_by(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)
  end
end
