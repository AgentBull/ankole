# FUTURE AGENT GUARDRAIL: this module drives the real skill-lesson loop against
# a real provider. Weakening its assertions to make a run pass is reward
# hacking; fix the business code, or the reflection template through its
# documented no-context probe process, instead.
defmodule Ankole.E2E.Scenarios.SkillLesson do
  @moduledoc """
  Real-LLM scenarios for the skill-lesson loop.

  One scenario runs the whole production path: seeded evidence jobs, the
  Dreaming trigger, a real reflection BackgroundAgentJob on the Docker worker,
  the completion hook and its mechanical gates, rendered delivery, and then a
  real lease review. The other proves a background job reaches instance memory
  through the read-only Brain `recall` tool over the live RPC boundary.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness, only: [process_ready_event_for_actor!: 2]
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.Brain.Claims
  alias Ankole.Brain.SkillLessons
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent

  # Models are deliberately hardcoded, like the rest of the real-LLM suite:
  # the run gates a known-good provider/model matrix, not local configuration.
  @real_coding_model "z-ai/glm-5.3-flash"
  @real_dreaming_model "z-ai/glm-5.3-flash"
  @real_embedding_model "qwen/qwen3-embedding-4b"
  # Qwen3-Embedding-4B's native width. Embeddings.collect_vectors/2 rejects any
  # response whose vector length differs, so a wrong value fails loudly.
  @real_embedding_dimensions 2560

  @job_deadline_ms 900_000
  @dispatch_deadline_ms 120_000
  @codename "ZUOYUN-7"

  @doc """
  Runs the whole production path and then one real lease review.
  """
  def run_real_skill_lesson_reflection_loop(%{
        agent: agent,
        provider_id: provider_id,
        primary_binding: primary_binding
      }) do
    put_coding_profile!(agent.uid, provider_id)
    put_brain_maintainer_profile!(agent.uid, provider_id)

    assert {:ok, _value} =
             AppConfigure.put_global_by_key("brain.skill_learning_reflection_threshold", 2)

    steering_job = insert_evidence_job!(agent, primary_binding.name)

    insert_turn!(steering_job, [
      task_message(steering_job.task),
      task_message("不要再扩大研究范围，基于已收集证据尽快收敛，完成交付。")
    ])

    failure_job = insert_evidence_job!(agent, primary_binding.name)

    insert_turn!(failure_job, [
      task_message(failure_job.task),
      failed_command(
        "python3 build_sheet.py --rows-from dict",
        "openpyxl 3.1.2 ... TypeError: ws.append() accepts list/tuple, got dict"
      ),
      %{
        "type" => "commandExecution",
        "command" => "python3 build_sheet.py --rows-from list",
        "exitCode" => 0,
        "status" => "completed"
      }
    ])

    assert %{status: :ok, agents: agents} = SkillLessons.run_phase()

    assert %{trigger: %{status: :reflection_created, job_id: reflection_id}} =
             Map.fetch!(agents, agent.uid)

    dispatch_job!(agent.uid, reflection_id)
    reflection = wait_for_terminal_job!(reflection_id)

    assert reflection.status == "succeeded",
           "reflection job ended #{reflection.status}: #{inspect(reflection.error)}"

    # The apply worker was enqueued inside the terminal commit. Oban runs in
    # manual mode here, so the scenario drains it.
    Oban.drain_queue(queue: :default)

    stamped = Repo.get!(Job, reflection_id)
    output_text = stamped.result["output_text"]

    assert is_binary(stamped.metadata["lessons_applied_at"]),
           "reflection output did not parse as {\"adds\": [...]}: #{inspect(output_text)}"

    lessons = agent_lessons(agent.uid)

    assert lessons != [],
           "a real model produced no accepted lesson from unambiguous recurring evidence; " <>
             "model output was: #{inspect(output_text)}"

    evidence_ids = MapSet.new([steering_job.id, failure_job.id])

    for lesson <- lessons do
      assert lesson.author_kind == "dreaming"
      assert lesson.evidence_job_ids != []
      assert Enum.all?(lesson.evidence_job_ids, &MapSet.member?(evidence_ids, &1))
      assert is_binary(lesson.checked_release)
      assert is_binary(lesson.checked_skill_hash)
      assert %DateTime{} = lesson.review_after
      refute lesson.content =~ "http"
    end

    [lesson | _rest] = lessons

    assert {:ok, rendered} = Library.rendered_skill_lessons(agent.uid, [lesson.skill_name])
    assert rendered[lesson.skill_name]["has_lessons"]
    assert rendered[lesson.skill_name]["text"] =~ "Field notes"
    assert rendered[lesson.skill_name]["text"] =~ String.slice(lesson.content, 0, 24)

    review = run_real_lease_review!(agent.uid, lessons)

    %{reflection: stamped, lessons: lessons, review: review}
  end

  @doc """
  Proves a background job reads instance memory: a real codex job calls the
  read-only `recall` tool over the live RPC boundary and reports what it found.
  """
  def run_real_job_brain_recall_turn(%{
        agent: agent,
        provider_id: provider_id,
        primary_binding: primary_binding
      }) do
    put_coding_profile!(agent.uid, provider_id)
    put_brain_model!("brain.embedding_model", provider_id, @real_embedding_model)

    assert {:ok, _claim} =
             Claims.write_fact(
               %{
                 claim: "The internal launch codename is #{@codename}.",
                 kind: "fact",
                 holder: "agents/" <> agent.uid,
                 audience_scope: "world",
                 object_slug: "agents/" <> agent.uid,
                 provenance: "skill lesson e2e seed",
                 notability: "high",
                 confidence: 0.95,
                 valid_from: DateTime.utc_now(:microsecond)
               },
               agent.uid
             )

    recall_session_id = "signal-channel:skill-lesson-recall-e2e"

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => recall_session_id,
               "source_tool_call_id" => "recall-e2e-1",
               "title" => "Recall the launch codename",
               "task" => """
               Call the recall tool exactly once with the query "internal launch codename".
               Then, without calling any other tool, reply with exactly one line:
               RECALL_OK <the codename from the recall result>
               Do not guess the codename; take it from the recall result.
               """,
               "reply_route" => %{"binding_name" => primary_binding.name}
             })

    dispatch_job!(agent.uid, job.id)
    finished = wait_for_terminal_job!(job.id)

    assert finished.status == "succeeded",
           "recall job ended #{finished.status}: #{inspect(finished.error)}"

    assert finished.result["output_text"] =~ @codename,
           "the job did not report the recalled codename: #{inspect(finished.result["output_text"])}"

    recall_calls = job_tool_calls(finished.id, "recall")

    assert recall_calls != [], "the job never called the recall tool"
    assert Enum.any?(recall_calls, &(&1["success"] == true))

    # Write tools stay out of the Job runtime.
    assert job_tool_calls(finished.id, "remember") == []

    %{job: finished, recall_calls: recall_calls}
  end

  # -- lease review -----------------------------------------------------------

  # Ages every lesson past its lease, then runs the phase again so the real
  # dreaming model has to judge whether each condition is still alive.
  defp run_real_lease_review!(agent_uid, lessons) do
    ids = Enum.map(lessons, & &1.id)
    past = DateTime.add(DateTime.utc_now(:microsecond), -1, :hour)

    {_count, _rows} =
      Repo.update_all(
        from(lesson in AgentSkillLesson, where: lesson.id in ^ids),
        set: [review_after: past]
      )

    assert %{status: :ok, agents: agents} = SkillLessons.run_phase()
    assert %{review: review} = Map.fetch!(agents, agent_uid)

    assert review.status == :ok, "lease review failed: #{inspect(review)}"
    assert review.docket == length(ids)

    assert review.renewed + review.obsoleted + review.lapsed > 0,
           "the review model returned no usable verdict: #{inspect(review)}"

    # Every verdict lands: a lesson is renewed with a fresh lease, or retired.
    for id <- ids do
      lesson = Repo.get!(AgentSkillLesson, id)

      if is_nil(lesson.retired_at) do
        assert DateTime.compare(lesson.review_after, past) == :gt,
               "a renewed lesson kept its expired lease"
      else
        assert lesson.retire_reason in ~w(lapsed obsolete)
      end
    end

    review
  end

  # -- fixtures ---------------------------------------------------------------

  defp put_coding_profile!(agent_uid, provider_id) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "coding", %{
               provider_id: provider_id,
               model: @real_coding_model,
               provider_options: %{}
             })
  end

  defp put_brain_model!("brain.embedding_model" = key, provider_id, model) do
    assert {:ok, _value} =
             AppConfigure.put_global_by_key(key, %{
               "provider_id" => provider_id,
               "model" => model,
               "dimensions" => @real_embedding_dimensions
             })
  end

  defp put_brain_maintainer_profile!(agent_uid, provider_id) do
    assert {:ok, ^agent_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", agent_uid)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "heavy", %{
               provider_id: provider_id,
               model: @real_dreaming_model,
               provider_options: %{}
             })
  end

  defp agent_lessons(agent_uid) do
    AgentSkillLesson
    |> where([lesson], lesson.agent_uid == ^agent_uid)
    |> order_by([lesson], asc: lesson.inserted_at)
    |> Repo.all()
  end

  defp job_tool_calls(job_id, tool) do
    TurnItem
    |> join(:inner, [item], turn in Turn, on: item.turn_id == turn.id)
    |> where([_item, turn], turn.job_id == ^job_id)
    |> where([item, _turn], fragment("? ->> 'type'", item.item) == "dynamicToolCall")
    |> where([item, _turn], fragment("? ->> 'tool'", item.item) == ^tool)
    |> select([item, _turn], item.item)
    |> Repo.all()
  end

  defp insert_evidence_job!(agent, binding_name) do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    %Job{id: id}
    |> Job.creation_changeset(%{
      "agent_uid" => agent.uid,
      "owner_session_id" => "signal-channel:skill-lesson-evidence",
      "source_tool_call_id" => "evidence-#{id}",
      "workspace_owner_job_id" => id,
      "status" => "succeeded",
      "title" => "evidence job #{id}",
      "task" => "Build the quarterly research workbook.",
      "reply_route" => %{"binding_name" => binding_name},
      "metadata" => %{},
      "completed_at" => DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_turn!(job, items) do
    turn =
      %Turn{}
      |> Turn.changeset(%{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-evidence-#{job.id}",
        runtime_turn_id: "turn-evidence-#{job.id}",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: %{"format" => "ankole_chatml", "version" => 1},
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    items
    |> Enum.with_index()
    |> Enum.each(fn {item, position} ->
      %TurnItem{}
      |> TurnItem.changeset(%{
        turn_id: turn.id,
        position: position,
        revision: 1,
        item_key: "item-#{position}",
        item: item
      })
      |> Repo.insert!()
    end)

    turn
  end

  defp task_message(text), do: %{"type" => "userMessage", "content" => [%{"text" => text}]}

  defp failed_command(command, error) do
    %{
      "type" => "commandExecution",
      "command" => command,
      "exitCode" => 1,
      "aggregatedOutput" => error,
      "status" => "failed"
    }
  end

  # The e2e stack has no LISTEN/NOTIFY delivery (the sandbox never commits), so
  # a Job's dispatch event is pumped by hand, exactly as the deep-research
  # scenarios do. The Worker may still be admitting itself when the Job lands,
  # so the pump repeats until the Job leaves the queue.
  defp dispatch_job!(agent_uid, job_id) do
    session_id = BackgroundAgentJobs.job_session_id(job_id)

    event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent_uid,
          where: event.session_id == ^session_id,
          where: event.type == "background_agent_job.dispatch"
        )
      )

    claimed =
      wait_until(deadline(@dispatch_deadline_ms), fn ->
        case Repo.get!(Job, job_id) do
          %Job{status: "queued"} ->
            process_ready_event_for_actor!(event, DateTime.utc_now(:microsecond))
            Process.sleep(500)
            false

          %Job{} = job ->
            job
        end
      end)

    assert {:ok, %Job{}} = claimed, "job #{job_id} was never claimed by the Worker"
    :ok
  end

  defp wait_for_terminal_job!(job_id) do
    terminal =
      wait_until(deadline(@job_deadline_ms), fn ->
        case Repo.get(Job, job_id) do
          %Job{status: status} = job when status in ~w(succeeded failed stopped) -> job
          _job -> false
        end
      end)

    assert {:ok, %Job{} = job} = terminal, "job #{job_id} never reached a terminal status"
    job
  end
end
