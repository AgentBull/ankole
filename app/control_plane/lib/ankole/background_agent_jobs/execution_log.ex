defmodule Ankole.BackgroundAgentJobs.ExecutionLog do
  @moduledoc """
  Builds bounded, chronological execution-log pages and task lineage snapshots
  for Worker thread recreation.

  When a BackgroundAgentJob cannot resume its local Codex thread (after cold
  idle recycling, a missing rollout file, or a runtime-binding change across
  `respawn_background_job`), the Worker pages stored `TurnItem` records across
  the Job's workspace continuation lineage and materializes them under the Job
  workspace's `.ankole/` directory.

  `TrajectoryReader` walks items newest-first across pages while returning each
  individual page in chronological order, keeping `AIGateway.OpaqueContent` in
  its wire-encoded form (`reveal: false`) and preserving the Worker's sanitized
  capture resolution.
  """

  require Ash.Expr
  require Ash.Query

  alias Ankole.Attrs
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.TrajectoryReader
  alias Ankole.Text

  @max_lineage_jobs 64
  @page_budget %{groups: 64, bytes: 65_536}
  @lineage_text_bytes 16_384
  @max_user_messages 256
  @truncation_suffix "...[truncated]"

  @type page_result :: %{
          jsonl: binary(),
          next_cursor: String.t() | nil,
          task_lineage_json: binary()
        }

  @spec page(Job.t(), String.t()) :: {:ok, page_result()} | {:error, atom()}
  def page(%Job{} = job, cursor) when is_binary(cursor) and cursor != "" do
    {reader_cursor, include_lineage?} =
      case cursor do
        "head" -> {nil, true}
        other -> {other, false}
      end

    lineage_jobs = lineage_jobs(job)
    turns = lineage_lead_turns(lineage_jobs)
    turn_meta = Map.new(turns, &{&1.id, turn_flags(&1)})
    projector = fn row, turn -> project_item(row, turn, Map.fetch!(turn_meta, turn.id)) end

    with {:ok, page} <-
           TrajectoryReader.page(
             job,
             {:execution_log, turns, projector},
             reader_cursor,
             @page_budget
           ) do
      jsonl =
        case page.units do
          [] -> ""
          units -> Enum.map_join(units, "\n", &Ankole.JSON.encode!(&1.item)) <> "\n"
        end

      lineage_bytes =
        if include_lineage? do
          lineage_jobs
          |> build_task_lineage(job, turns)
          |> Ankole.JSON.encode!()
        else
          ""
        end

      {:ok,
       %{
         jsonl: jsonl,
         next_cursor: page.next_cursor,
         task_lineage_json: lineage_bytes
       }}
    end
  end

  def page(%Job{}, _cursor), do: {:error, :invalid_background_agent_job_trajectory_cursor}

  defp lineage_jobs(%Job{} = job) do
    collect_lineage(job, job.workspace_owner_job_id, MapSet.new(), [], @max_lineage_jobs)
  end

  defp collect_lineage(nil, _owner_id, _seen, acc, _remaining), do: acc
  defp collect_lineage(_job, _owner_id, _seen, acc, 0), do: acc

  defp collect_lineage(%Job{} = current, owner_id, seen, acc, remaining) do
    cond do
      MapSet.member?(seen, current.id) ->
        acc

      current.workspace_owner_job_id != owner_id ->
        acc

      true ->
        next_acc = [current | acc]
        next_seen = MapSet.put(seen, current.id)

        parent =
          case current.continued_from_job_id do
            parent_id when is_integer(parent_id) ->
              Queries.get_for_agent(parent_id, current.agent_uid)

            _none ->
              nil
          end

        collect_lineage(parent, owner_id, next_seen, next_acc, remaining - 1)
    end
  end

  defp lineage_lead_turns([]), do: []

  defp lineage_lead_turns(jobs) do
    job_ids = Enum.map(jobs, & &1.id)

    Turn
    |> Ash.Query.filter(job_id in ^job_ids)
    |> Ash.Query.sort(started_at: :asc, id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.group_by(&{&1.job_id, &1.attempt})
    |> Enum.flat_map(fn {_key, attempt_turns} ->
      ordered = Enum.sort_by(attempt_turns, &Turn.start_key/1)
      lead_thread_id = Turn.attempt_lead_thread_id(ordered)

      case Enum.filter(ordered, &Turn.lead?(&1, lead_thread_id)) do
        [] -> ordered
        lead -> lead
      end
    end)
    |> Enum.sort_by(&Turn.start_key/1)
  end

  defp build_task_lineage(jobs, %Job{} = target_job, turns) do
    %{
      "format" => "ankole_job_task_lineage",
      "version" => 1,
      "workspace_owner_job_id" => target_job.workspace_owner_job_id,
      "current_job_id" => target_job.id,
      "jobs" => Enum.map(jobs, &job_lineage_entry/1),
      "user_messages" => lineage_user_messages(jobs, turns)
    }
  end

  defp job_lineage_entry(%Job{} = job) do
    %{
      "job_id" => job.id,
      "title" => job.title,
      "status" => Atom.to_string(job.status),
      "attempts" => job.attempts,
      "task" => truncate_text(job.task)
    }
    |> Attrs.maybe_put("continued_from_job_id", job.continued_from_job_id)
    |> Attrs.maybe_put("final_report", extract_final_report(job.result))
    |> Attrs.maybe_put("error", extract_job_error(job.error))
  end

  defp extract_final_report(%{"output_text" => text}) when is_binary(text) and text != "",
    do: truncate_text(text)

  defp extract_final_report(_result), do: nil

  defp extract_job_error(%{} = error) when map_size(error) > 0 do
    %{}
    |> Attrs.maybe_put("code", text_or_nil(error["code"]))
    |> Attrs.maybe_put("summary", truncate_optional(error["summary"]))
    |> case do
      empty when map_size(empty) == 0 -> nil
      present -> present
    end
  end

  defp extract_job_error(_error), do: nil

  defp lineage_user_messages(_jobs, []), do: []

  defp lineage_user_messages(jobs, turns) do
    turn_ids = Enum.map(turns, & &1.id)
    turns_by_id = Map.new(turns, &{&1.id, &1})
    tasks_by_job_id = Map.new(jobs, &{&1.id, String.trim(&1.task || "")})

    entries =
      TurnItem
      |> Ash.Query.filter(
        turn_id in ^turn_ids and fragment("? ->> 'type'", item) == "userMessage"
      )
      |> Ash.Query.sort([
        {Ash.Expr.calc(turn.started_at, type: :utc_datetime_usec), :asc},
        turn_id: :asc,
        position: :asc
      ])
      |> Ankole.Ash.read!()
      |> Enum.flat_map(&project_lineage_user_message(&1, turns_by_id, tasks_by_job_id))

    bound_user_messages(entries)
  end

  defp project_lineage_user_message(%TurnItem{} = row, turns_by_id, tasks_by_job_id) do
    turn = Map.fetch!(turns_by_id, row.turn_id)
    text = user_content_text(row.item["content"])
    steer? = String.starts_with?(row.item_key || "", "client:")
    job_task = Map.get(tasks_by_job_id, turn.job_id, "")

    cond do
      text == "" ->
        []

      not steer? and String.trim(text) == job_task ->
        []

      true ->
        [
          %{
            "job_id" => turn.job_id,
            "attempt" => turn.attempt,
            "turn_id" => turn.id,
            "position" => row.position,
            "kind" => if(steer?, do: "user_message", else: "turn_input"),
            "text" => truncate_text(text)
          }
        ]
    end
  end

  defp bound_user_messages(entries) when length(entries) <= @max_user_messages, do: entries

  defp bound_user_messages(entries) do
    steers = Enum.filter(entries, &(&1["kind"] == "user_message"))

    if length(steers) >= @max_user_messages do
      Enum.take(steers, -@max_user_messages)
    else
      remaining = @max_user_messages - length(steers)

      turn_inputs =
        entries |> Enum.reject(&(&1["kind"] == "user_message")) |> Enum.take(-remaining)

      kept = MapSet.new(steers ++ turn_inputs, &{&1["turn_id"], &1["position"]})
      Enum.filter(entries, &MapSet.member?(kept, {&1["turn_id"], &1["position"]}))
    end
  end

  defp turn_flags(%Turn{} = turn) do
    metadata = get_in(turn.trajectory || %{}, ["metadata"])

    %{
      redacted: is_map(metadata) and metadata["redacted"] == true,
      content_truncated: is_map(metadata) and metadata["content_truncated"] == true
    }
  end

  defp project_item(%TurnItem{item: %{"type" => type} = item} = row, %Turn{} = turn, flags)
       when is_binary(type) do
    case project_item_payload(type, item) do
      nil ->
        nil

      payload ->
        %{
          "job_id" => turn.job_id,
          "attempt" => turn.attempt,
          "turn_id" => turn.id,
          "position" => row.position,
          "started_at" => DateTime.to_iso8601(turn.started_at),
          "type" => type
        }
        |> maybe_put_true("redacted", flags.redacted)
        |> maybe_put_true("content_truncated", flags.content_truncated)
        |> Map.merge(payload)
    end
  end

  defp project_item(_row, _turn, _flags), do: nil

  defp project_item_payload("reasoning", _item), do: nil
  defp project_item_payload("hookPrompt", _item), do: nil

  defp project_item_payload("userMessage", item) do
    case user_content_text(item["content"]) do
      "" ->
        nil

      text ->
        %{"text" => text}
        |> Attrs.maybe_put("client_id", text_or_nil(item["clientId"]))
    end
  end

  defp project_item_payload("agentMessage", item) do
    case text_or_nil(item["text"]) do
      nil ->
        nil

      text ->
        %{"text" => text}
        |> Attrs.maybe_put("phase", text_or_nil(item["phase"]))
    end
  end

  defp project_item_payload("plan", item) do
    case text_or_nil(item["text"]) do
      nil -> nil
      text -> %{"text" => text}
    end
  end

  defp project_item_payload("commandExecution", item) do
    %{
      "command" => item["command"],
      "cwd" => item["cwd"],
      "status" => item["status"],
      "exit_code" => item["exitCode"],
      "output" => string_or_empty(item["aggregatedOutput"])
    }
    |> Attrs.maybe_put("duration_ms", item["durationMs"])
  end

  defp project_item_payload("fileChange", item) do
    %{"status" => item["status"], "changes" => item["changes"]}
  end

  defp project_item_payload("mcpToolCall", item) do
    %{
      "server" => item["server"],
      "tool" => item["tool"],
      "status" => item["status"],
      "arguments" => item["arguments"],
      "output" => item["result"] || item["error"]
    }
    |> Attrs.maybe_put("duration_ms", item["durationMs"])
  end

  defp project_item_payload("dynamicToolCall", item) do
    %{
      "tool" => item["tool"],
      "status" => item["status"],
      "arguments" => item["arguments"],
      "output" => item["contentItems"]
    }
    |> Attrs.maybe_put("namespace", text_or_nil(item["namespace"]))
    |> Attrs.maybe_put("success", item["success"])
    |> Attrs.maybe_put("duration_ms", item["durationMs"])
  end

  defp project_item_payload("collabAgentToolCall", item) do
    %{
      "tool" => item["tool"],
      "status" => item["status"],
      "receiver_thread_ids" => item["receiverThreadIds"]
    }
    |> Attrs.maybe_put("prompt", text_or_nil(item["prompt"]))
    |> Attrs.maybe_put("agents_states", item["agentsStates"])
  end

  defp project_item_payload("webSearch", item) do
    %{"query" => item["query"]}
    |> Attrs.maybe_put("action", item["action"])
  end

  defp project_item_payload("imageView", item), do: %{"path" => item["path"]}

  defp project_item_payload("imageGeneration", item),
    do: Map.drop(item, ["type"])

  defp project_item_payload("enteredReviewMode", item),
    do: %{"review" => string_or_empty(item["review"])}

  defp project_item_payload("exitedReviewMode", item),
    do: %{"review" => string_or_empty(item["review"])}

  defp project_item_payload("contextCompaction", _item),
    do: %{"status" => "completed"}

  defp project_item_payload("sleep", item),
    do: %{"duration_ms" => item["durationMs"]}

  defp project_item_payload(_other, _item), do: nil

  defp user_content_text(content) do
    content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) and text != "" -> [text]
      %{"type" => type} when is_binary(type) and type != "text" -> ["[#{type}]"]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _false), do: map

  defp truncate_optional(value) when is_binary(value) and value != "", do: truncate_text(value)
  defp truncate_optional(_value), do: nil

  defp truncate_text(value) when is_binary(value),
    do: Text.truncate_utf8_window(value, @lineage_text_bytes, @truncation_suffix)

  defp truncate_text(_value), do: ""

  defp text_or_nil(value) when is_binary(value) and value != "", do: value
  defp text_or_nil(_value), do: nil

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""
end
