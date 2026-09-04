defmodule Ankole.BackgroundAgentJobs.TurnEvidenceTest do
  use Ankole.AIGatewayCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.Repo

  test "selects only recent unconsumed Jobs with human input or failed calls" do
    %{principal: agent} = background_agent_fixture()
    old = insert_job!(agent.uid, completed_at: DateTime.add(now(), -40, :day))
    insert_turn!(old, [user_message("old task"), user_message("old correction")])

    clean = insert_job!(agent.uid)
    insert_turn!(clean, [user_message("clean task")])

    human = insert_job!(agent.uid)
    insert_turn!(human, [user_message("human task"), user_message("narrow the scope")])

    failed = insert_job!(agent.uid)

    insert_turn!(failed, [
      user_message("failed task"),
      command("python build.py", 1, "TypeError"),
      command("python build.py --list", 0, "ok"),
      dynamic_call(false),
      %{
        "type" => "collabAgentToolCall",
        "id" => "collab-failed",
        "tool" => "spawnAgent",
        "status" => "failed"
      }
    ])

    reflection =
      insert_job!(agent.uid,
        metadata: %{"skill_lesson_reflection" => true},
        source_tool_call_id: "skill-lessons-reflection"
      )

    insert_turn!(reflection, [user_message("reflection"), dynamic_call(false)])

    assert BackgroundAgentJobs.evidence_signals(
             agent.uid,
             clean.id,
             DateTime.add(now(), -30, :day)
           ) == [
             %{job_id: failed.id, human_input_count: 0, failed_call_count: 2},
             %{job_id: human.id, human_input_count: 1, failed_call_count: 0}
           ]
  end

  test "renders bounded evidence in caller order through TurnItemProjection" do
    %{principal: agent} = background_agent_fixture()
    human = insert_job!(agent.uid, title: "Human correction")

    insert_turn!(human, [user_message("task"), user_message("不要扩大范围")], usage: usage_snapshot())

    failed =
      insert_job!(agent.uid,
        title: "Failed build",
        error: %{"summary" => "Build failed"},
        metadata: %{"stop_reason" => "tool_error"}
      )

    insert_turn!(failed, [
      user_message("task"),
      command("python build.py", 1, "openpyxl TypeError"),
      command("python build.py --list", 0, "ok"),
      %{"type" => "contextCompaction", "id" => "compact-1"}
    ])

    assert [failed_section, human_section] =
             BackgroundAgentJobs.evidence_sections([failed.id, human.id])

    assert failed_section =~ "### Job #{failed.id} — Failed build (succeeded)"
    assert failed_section =~ "ERROR: Build failed"
    assert failed_section =~ "STOP REASON: tool_error"
    assert failed_section =~ "call: python build.py"
    assert failed_section =~ "error tail: \"openpyxl TypeError\""
    assert failed_section =~ "next call in turn: python build.py --list"
    assert failed_section =~ "CONTEXT COMPACTIONS: 1"

    assert human_section =~ "### Job #{human.id} — Human correction (succeeded)"
    assert human_section =~ "HUMAN INPUT DURING RUN:\n- \"不要扩大范围\""
    assert human_section =~ "USAGE: input 12, output 4 tokens"
  end

  defp insert_job!(agent_uid, attrs \\ []) do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    base = %{
      "agent_uid" => agent_uid,
      "owner_session_id" => "turn-evidence-test",
      "source_tool_call_id" => "turn-evidence-#{id}",
      "workspace_owner_job_id" => id,
      "status" => "succeeded",
      "title" => "Evidence Job",
      "task" => "Build the workbook.",
      "reply_route" => %{"binding_name" => "lark"},
      "metadata" => %{},
      "error" => %{},
      "completed_at" => now()
    }

    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    %Job{id: id}
    |> Job.creation_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp insert_turn!(job, items, attrs \\ []) do
    turn =
      %Turn{}
      |> Turn.changeset(%{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-#{job.id}",
        runtime_turn_id: "turn-#{job.id}-#{System.unique_integer([:positive])}",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: %{"format" => "ankole_chatml", "version" => 1},
        usage: Keyword.get(attrs, :usage),
        started_at: now(),
        completed_at: now()
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
        item_key: item["id"] || "item-#{position}",
        item: item
      })
      |> Repo.insert!()
    end)

    turn
  end

  defp user_message(text) do
    %{
      "type" => "userMessage",
      "id" => "user-#{System.unique_integer([:positive])}",
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp command(command, exit_code, output) do
    %{
      "type" => "commandExecution",
      "id" => "command-#{System.unique_integer([:positive])}",
      "command" => command,
      "exitCode" => exit_code,
      "aggregatedOutput" => output,
      "status" => if(exit_code == 0, do: "completed", else: "failed")
    }
  end

  defp dynamic_call(success?) do
    %{
      "type" => "dynamicToolCall",
      "id" => "dynamic-#{System.unique_integer([:positive])}",
      "namespace" => "local",
      "tool" => "worksheet",
      "arguments" => %{"action" => "append"},
      "contentItems" => "worksheet failed",
      "status" => if(success?, do: "completed", else: "failed"),
      "success" => success?
    }
  end

  defp usage_snapshot do
    breakdown = %{
      "total_tokens" => 16,
      "input_tokens" => 12,
      "cached_input_tokens" => 2,
      "output_tokens" => 4,
      "reasoning_output_tokens" => 1
    }

    %{
      "thread_total" => breakdown,
      "last_model_call" => breakdown,
      "model_context_window" => 200_000
    }
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
