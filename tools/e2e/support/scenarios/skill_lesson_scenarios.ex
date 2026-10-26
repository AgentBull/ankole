# FUTURE AGENT GUARDRAIL: this module drives the real skill-lesson loop against
# a real provider. Weakening its assertions to make a run pass is reward
# hacking; fix the business code, or the reflection template through its
# documented no-context probe process, instead.
defmodule Ankole.E2E.Scenarios.SkillLesson do
  @moduledoc """
  Real-LLM scenarios for the skill-lesson loop.

  Native Pod requests produce real execution evidence and a reflection on a
  Docker Worker without external Bindings. A separate scenario uses seeded
  evidence to check the completion gates, Skill rendering, and lease review.
  Another checks instance memory through the Brain tool's `recall` operation.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness, only: [ensure_input_driver!: 2]
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.Brain.SkillLessons
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Message, as: PublicMessage
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.PodContentBrowser
  alias Ankole.Repo
  alias Ankole.Signals.Signal

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
  Runs native Human requests, their Codex evidence Jobs, and a reflection on
  the real Worker. Every evidence item and lesson comes from executed work.
  """
  def run_real_pod_skill_lesson_reflection_loop(%{agent: agent} = ctx) do
    bindings_before = assert_no_external_bindings!(agent.uid)
    put_coding_profile!(agent.uid, ctx.provider_id)
    put_brain_maintainer_profile!(agent.uid, ctx.provider_id)

    assert {:ok, _value} =
             AppConfigure.put_global_by_key("brain.skill_learning_reflection_threshold", 2)

    assert {:ok, _sync} = Library.sync_agent_skills(agent.uid)
    assert {:ok, xlsx} = Library.skill_view(agent.uid, "xlsx")
    assert xlsx["skill_name"] == "xlsx"
    assert is_binary(xlsx["content"]) and xlsx["content"] != ""
    assert agent_lessons(agent.uid) == []

    started_at = DateTime.utc_now(:microsecond)
    evidence_jobs = Enum.map(["A", "B"], &run_pod_lesson_evidence_job!(ctx, &1))
    evidence_ids = MapSet.new(evidence_jobs, & &1.id)

    signals = BackgroundAgentJobs.evidence_signals(agent.uid, 0, started_at)
    assert MapSet.new(signals, & &1.job_id) == evidence_ids
    assert Enum.all?(signals, &(&1.failed_call_count > 0))
    assert_no_external_bindings!(agent.uid)

    public_message_ids = public_message_ids(agent.uid)
    refute Repo.exists?(from(intent in Intent, where: intent.agent_uid == ^agent.uid))

    assert %{status: :ok, agents: agents} = SkillLessons.run_phase()

    assert %{trigger: %{status: :reflection_created, job_id: reflection_id}} =
             Map.fetch!(agents, agent.uid)

    queued = Repo.get!(Job, reflection_id)
    assert queued.reply_route == %{}
    assert queued.authorization_kind == "service"
    assert queued.human_uid == nil
    assert queued.source_signal_id == nil
    assert MapSet.new(queued.metadata["evidence_job_ids"]) == evidence_ids

    dispatch_job!(agent.uid, reflection_id)
    reflection = wait_for_terminal_job!(reflection_id)
    assert_completed_worker_job!(reflection)

    dispatch =
      Repo.get_by!(Signal,
        source_event_id: "background_agent_job:#{reflection.id}:dispatch"
      )

    assert dispatch.reply_binding_name == nil
    assert dispatch.conversation_id == nil

    assert {:ok, _completed} =
             Ankole.E2E.WaitHelpers.wait_for_signal_completed(
               ctx.container,
               dispatch.id,
               deadline(60_000)
             )

    Oban.drain_queue(queue: :default)
    stamped = Repo.get!(Job, reflection.id)
    output_text = stamped.result["output_text"]
    reflection_messages = reflection_messages(stamped)

    IO.puts(
      "Pod Skill Lessons reflection trace: " <>
        Ankole.JSON.encode!(%{
          job_id: stamped.id,
          runtime_thread_id: stamped.runtime_thread_id,
          output_text: output_text,
          messages: reflection_messages
        })
    )

    assert is_binary(stamped.metadata["lessons_applied_at"]),
           "reflection output was not applied: #{inspect(output_text)}"

    lessons = agent_lessons(agent.uid)

    assert lessons != [],
           "real Worker evidence produced no accepted lesson: #{inspect(output_text)}"

    assert Enum.any?(lessons, &(&1.skill_name == "xlsx")),
           "the reflection did not retain a lesson for the exercised xlsx Skill"

    delivery_checks =
      for lesson <- lessons do
        assert lesson.author_kind == :dreaming
        assert MapSet.new(lesson.evidence_job_ids) == evidence_ids
        assert is_binary(lesson.checked_release)
        assert is_binary(lesson.checked_skill_hash)
        assert %DateTime{} = lesson.review_after
        assert lesson.retired_at == nil
        assert lesson.content != ""

        assert {:ok, rendered} = Library.skill_view(agent.uid, lesson.skill_name)
        assert rendered["has_agent_overlay"]

        assert rendered["content"] =~
                 "Field notes (dated; verify against the current environment):"

        assert rendered["content"] =~ lesson.content

        %{
          lesson_id: lesson.id,
          skill_name: lesson.skill_name,
          exact_content_present: String.contains?(rendered["content"], lesson.content)
        }
      end

    assert public_message_ids(agent.uid) == public_message_ids
    refute Repo.exists?(from(intent in Intent, where: intent.agent_uid == ^agent.uid))

    refute Repo.exists?(
             from(event in Signal,
               where:
                 event.agent_uid == ^agent.uid and
                   event.session_id == ^stamped.owner_session_id
             )
           )

    bindings_after = assert_no_external_bindings!(agent.uid)

    emit_pod_lesson_evidence!(ctx, %{
      evidence_jobs:
        Enum.map(evidence_jobs, &Map.take(&1, [:id, :status, :runtime_thread_id, :attempts])),
      evidence_signals: signals,
      reflection:
        Map.take(stamped, [
          :id,
          :status,
          :reply_route,
          :authorization_kind,
          :human_uid,
          :runtime_thread_id,
          :attempts
        ])
        |> Map.put(:turns, completed_job_turns(stamped))
        |> Map.put(:output_text, output_text)
        |> Map.put(:messages, reflection_messages),
      lessons:
        Enum.map(
          lessons,
          &Map.take(&1, [:id, :skill_name, :content, :evidence_job_ids, :author_kind])
        ),
      skill_view_delivery: delivery_checks,
      bindings_before: bindings_before,
      bindings_after: bindings_after,
      public_message_ids_before: public_message_ids,
      public_message_ids_after: public_message_ids(agent.uid),
      external_delivery_count:
        Repo.aggregate(from(intent in Intent, where: intent.agent_uid == ^agent.uid), :count)
    })

    %{evidence_jobs: evidence_jobs, reflection: stamped, lessons: lessons}
  end

  defp run_pod_lesson_evidence_job!(ctx, label) do
    request =
      PodContentBrowser.send_message!(ctx, ctx.owner_uid,
        text: """
        Run this spreadsheet compatibility reproduction as exactly one background
        Agent Job titled "Named-row workbook #{label}". Use the xlsx Skill in that
        Job. Put the full instructions below in its task. Do not run the commands
        in the main conversation, create a Workflow, or split it into more Jobs.

        First load the xlsx Skill. Reproduce this actual openpyxl behavior by
        running the following unmodified Python in a separate shell command:

        from openpyxl import Workbook
        Workbook().active.append({"revenue": 42, "cost": 17})

        Preserve and inspect that command's real nonzero exit status and error.
        Do not catch it, replace its output, or hide its status with a shell suffix.
        The issue is field-name mapping keys; mappings keyed by Excel column
        letters or indexes have different behavior.

        Then repair the input by using explicit header order ["revenue", "cost"]
        and a list of values in that order. Save named-rows-#{label}.xlsx in the
        Job workspace. Read it back with openpyxl and verify the first two rows
        are ["revenue", "cost"] and [42, 17]. This is a small execution task:
        use no web research, no subagents, and no extra background Jobs.

        Wait for this one Job to finish and report its verified result here.
        """
      )

    input = Repo.get_by!(Signal, message_id: request["message_id"])
    assert input.agent_uid == ctx.agent.uid
    assert input.human_uid == ctx.owner_uid
    assert input.authorization_kind == "human"
    assert input.conversation_id == request["conversation_id"]
    assert input.reply_binding_name == nil

    assert {:ok, [job]} =
             wait_until(deadline(180_000), fn ->
               jobs =
                 Repo.all(
                   from(job in Job,
                     where: job.agent_uid == ^ctx.agent.uid and job.source_signal_id == ^input.id,
                     order_by: [asc: job.id]
                   )
                 )

               if jobs != [], do: jobs
             end)

    assert job.human_uid == ctx.owner_uid
    assert job.reply_route["conversation_id"] == input.conversation_id
    assert job.reply_route["binding_name"] == nil
    dispatch_job!(ctx.agent.uid, job.id)
    finished = wait_for_terminal_job!(job.id)
    assert_completed_worker_job!(finished)

    items =
      Repo.all(
        from(item in TurnItem,
          join: turn in Turn,
          on: turn.id == item.turn_id,
          where: turn.job_id == ^job.id,
          select: item.item
        )
      )
      |> Enum.map(&Ankole.AIGateway.OpaqueContent.reveal/1)

    IO.puts(
      "Pod Skill Lessons Job trace: " <>
        Ankole.JSON.encode!(%{
          job_id: finished.id,
          task: finished.task,
          output_text: finished.result["output_text"],
          item_types: Enum.frequencies_by(items, & &1["type"]),
          commands:
            for item <- items, item["type"] == "commandExecution" do
              Map.take(item, ["command", "status", "exitCode", "aggregatedOutput"])
            end
        })
    )

    assert Enum.any?(items, fn item ->
             item["type"] == "commandExecution" and is_integer(item["exitCode"]) and
               item["exitCode"] != 0 and
               String.contains?(item["aggregatedOutput"] || "", "ValueError") and
               String.contains?(item["aggregatedOutput"] || "", "revenue")
           end),
           "Job #{job.id} did not execute the required named-key failure"

    workbook = "/workspace/jobs/#{finished.workspace_owner_job_id}/named-rows-#{label}.xlsx"

    assert DockerWorker.exec!(ctx.container, [
             "python3",
             "-c",
             "import sys; from openpyxl import load_workbook; " <>
               "rows=list(load_workbook(sys.argv[1], data_only=True).active.values); " <>
               "assert rows == [('revenue', 'cost'), (42, 17)], rows; " <>
               "print('NAMED_ROWS_VERIFIED')",
             workbook
           ]) =~ "NAMED_ROWS_VERIFIED"

    assert {:ok, completion} =
             wait_until(deadline(60_000), fn ->
               Repo.get_by(Signal,
                 agent_uid: ctx.agent.uid,
                 source_event_id:
                   "background_agent_job:#{finished.id}:succeeded:#{finished.attempts}"
               )
             end)

    for signal <- [input, completion] do
      assert {:ok, _completed} =
               Ankole.E2E.WaitHelpers.wait_for_signal_completed(
                 ctx.container,
                 signal.id,
                 deadline(180_000)
               )
    end

    assert Repo.exists?(
             from(message in PublicMessage,
               where:
                 message.conversation_id == ^input.conversation_id and
                   message.author_uid == ^ctx.agent.uid and message.author_type == :agent
             )
           )

    assert_no_external_bindings!(ctx.agent.uid)
    finished
  end

  defp assert_completed_worker_job!(job) do
    assert job.status == :succeeded,
           "Worker Job #{job.id} ended #{job.status}: #{inspect(job.error)}"

    assert job.attempts > 0
    assert is_binary(job.runtime_thread_id) and job.runtime_thread_id != ""

    assert Repo.exists?(
             from(turn in Turn,
               where:
                 turn.job_id == ^job.id and turn.runtime_thread_id == ^job.runtime_thread_id and
                   turn.attempt == ^job.attempts and turn.kind == "agent" and
                   turn.status == :completed and not is_nil(turn.completed_at)
             )
           ),
           "Worker Job #{job.id} has no completed root Turn for its actual runtime"
  end

  defp assert_no_external_bindings!(agent_uid) do
    count =
      Repo.aggregate(
        from(binding in Ankole.Signals.Binding, where: binding.agent_uid == ^agent_uid),
        :count
      )

    assert count == 0
    count
  end

  defp public_message_ids(agent_uid) do
    Repo.all(
      from(message in PublicMessage,
        where: message.author_uid == ^agent_uid,
        order_by: [asc: message.id],
        select: message.id
      )
    )
  end

  defp completed_job_turns(job) do
    Repo.all(
      from(turn in Turn,
        where:
          turn.job_id == ^job.id and turn.runtime_thread_id == ^job.runtime_thread_id and
            turn.attempt == ^job.attempts and turn.kind == "agent" and turn.status == :completed,
        select: map(turn, [:id, :runtime_thread_id, :runtime_turn_id, :attempt, :status])
      )
    )
  end

  defp reflection_messages(job) do
    Repo.all(
      from(item in TurnItem,
        join: turn in Turn,
        on: turn.id == item.turn_id,
        where:
          turn.job_id == ^job.id and turn.runtime_thread_id == ^job.runtime_thread_id and
            turn.attempt == ^job.attempts and turn.kind == "agent",
        order_by: [asc: turn.started_at, asc: item.position],
        select: item.item
      )
    )
    |> Enum.map(&Ankole.AIGateway.OpaqueContent.reveal/1)
    |> Enum.filter(&(&1["type"] == "agentMessage"))
    |> Enum.map(&Map.take(&1, ["id", "text", "phase"]))
  end

  defp emit_pod_lesson_evidence!(ctx, evidence) do
    container_name = DockerWorker.container_name(ctx.agent.uid)
    assert %{status: "running"} = info = DockerWorker.container_info(container_name)
    docker = System.find_executable("docker")
    assert is_binary(docker)

    assert {pid, 0} =
             System.cmd(docker, ["inspect", "--format", "{{.State.Pid}}", container_name])

    evidence =
      Map.put(evidence, :worker, %{
        agent_uid: ctx.agent.uid,
        image: info.image,
        container: container_name,
        container_pid: pid |> String.trim() |> String.to_integer()
      })

    IO.puts("Pod Skill Lessons evidence: " <> Ankole.JSON.encode!(Ankole.JSON.plain(evidence)))
  end

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

    assert reflection.status == :succeeded,
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
      assert lesson.author_kind == :dreaming
      assert lesson.evidence_job_ids != []
      assert Enum.all?(lesson.evidence_job_ids, &MapSet.member?(evidence_ids, &1))
      assert is_binary(lesson.checked_release)
      assert is_binary(lesson.checked_skill_hash)
      assert %DateTime{} = lesson.review_after
      refute lesson.content =~ "http"
    end

    [lesson | _rest] = lessons

    assert {:ok, rendered} = Library.skill_view(agent.uid, lesson.skill_name)
    assert rendered["has_agent_overlay"]
    assert rendered["content"] =~ "Field notes"
    assert rendered["content"] =~ String.slice(lesson.content, 0, 24)

    review = run_real_lease_review!(agent.uid, lessons)

    %{reflection: stamped, lessons: lessons, review: review}
  end

  @doc """
  Proves a background job reads instance memory: a real codex job calls the
  read-only `recall` operation, AIGateway executes it inside the job's own
  Response as the hosted Brain tool, and the job reports what it found.
  """
  def run_real_job_brain_recall_turn(%{
        agent: agent,
        provider_id: provider_id,
        primary_binding: primary_binding
      }) do
    put_coding_profile!(agent.uid, provider_id)
    put_brain_model!("brain.embedding_model", provider_id, @real_embedding_model)

    assert {:ok, _claim} =
             Ankole.Brain.write_fact(
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
    started_at = DateTime.utc_now(:microsecond)

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
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

    assert finished.status == :succeeded,
           "recall job ended #{finished.status}: #{inspect(finished.error)}"

    assert finished.result["output_text"] =~ @codename,
           "the job did not report the recalled codename: #{inspect(finished.result["output_text"])}"

    object = Repo.get_by!(Ankole.Brain.Schemas.Object, slug: "agents/" <> agent.uid)
    assert %DateTime{} = object.last_retrieved_at
    assert DateTime.compare(object.last_retrieved_at, started_at) != :lt

    assert Repo.aggregate(
             from(claim in Ankole.Brain.Schemas.Claim, where: claim.created_at >= ^started_at),
             :count
           ) == 0

    %{job: finished}
  end

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
        assert lesson.retire_reason in [:lapsed, :obsolete]
      end
    end

    review
  end

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

  defp insert_evidence_job!(agent, binding_name) do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    source = Ankole.WorkFixtures.service_source(agent.uid)

    {:ok, job} =
      Repo.transact(fn _ ->
        with {:ok, job} <-
               Ankole.Ash.create(Job, :create_job, %{
                 "id" => id,
                 "agent_uid" => agent.uid,
                 "source_signal_id" => source.id,
                 "authorization_kind" => "service",
                 "owner_session_id" => "signal-channel:skill-lesson-evidence",
                 "source_tool_call_id" => "evidence-#{id}",
                 "workspace_owner_job_id" => id,
                 "title" => "evidence job #{id}",
                 "task" => "Build the quarterly research workbook.",
                 "reply_route" => %{"binding_name" => binding_name}
               }) do
          Ankole.Ash.update(job, :external_complete, %{completed_at: DateTime.utc_now()})
        end
      end)

    job
  end

  defp insert_turn!(job, items) do
    turn =
      case Repo.transact(fn _ ->
             Ankole.Ash.create(Turn, :record, %{
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
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end

    items
    |> Enum.with_index()
    |> Enum.each(fn {item, position} ->
      case Repo.transact(fn _ ->
             Ankole.Ash.create(TurnItem, :append, %{
               turn_id: turn.id,
               position: position,
               revision: 1,
               item_key: "item-#{position}",
               item: item
             })
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end
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

  # The scenarios pump the production dispatch Signal explicitly. The Worker
  # can still be admitting itself when the Job arrives, so the pump repeats
  # until the Job leaves the queue.
  defp dispatch_job!(agent_uid, job_id) do
    session_id = BackgroundAgentJobs.job_session_id(job_id)

    event =
      Repo.one!(
        from(event in Signal,
          where: event.agent_uid == ^agent_uid,
          where: event.session_id == ^session_id,
          where: event.type == "background_agent_job.dispatch"
        )
      )

    claimed =
      wait_until(deadline(@dispatch_deadline_ms), fn ->
        case Repo.get!(Job, job_id) do
          %Job{status: :queued} ->
            ensure_input_driver!(event, DateTime.utc_now(:microsecond))
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
          %Job{status: status} = job when status in [:succeeded, :failed, :stopped] -> job
          _job -> false
        end
      end)

    assert {:ok, %Job{} = job} = terminal, "job #{job_id} never reached a terminal status"
    job
  end
end
