defmodule Ankole.BackgroundAgentJobs.TurnEvidence do
  @moduledoc """
  Reads finished Jobs as evidence for skill-lesson reflection.

  This module owns the evidence contract over stored Turn items. It sends
  every selected item through `Ankole.BackgroundAgentJobs.TurnItemProjection`,
  so Brain does not decode the Worker item shape. The item `type` is used only
  to bound the rows loaded for the four evidence kinds.

  Human input is every user message after the first one, which is the Job task
  injection. Failed calls include shell commands with a nonzero exit code and
  local dynamic tool calls with `success: false`. Collaboration, MCP, and
  provider-hosted calls do not count.
  """

  import Ecto.Query

  alias Ankole.AIGateway.OpaqueContent
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.Repo

  @item_types ~w(userMessage commandExecution dynamicToolCall contextCompaction)
  @per_job_char_limit 3_000
  @task_head_chars 500
  @error_summary_chars 300
  @human_input_chars 400
  @human_input_limit 8
  @failed_call_chars 300
  @bypass_call_chars 200
  @failed_group_limit 10

  @type evidence_signal :: %{
          job_id: pos_integer(),
          human_input_count: non_neg_integer(),
          failed_call_count: non_neg_integer()
        }

  @doc """
  Returns evidence signals for finished Jobs of one Agent.

  `since_job_id` is the exclusive durable watermark. `completed_after` is the
  exclusive time window floor. Reflection Jobs and Jobs without a human input
  or failed call are excluded. Results are ordered newest Job first.
  """
  @spec evidence_signals(String.t(), non_neg_integer(), DateTime.t()) :: [evidence_signal()]
  def evidence_signals(agent_uid, since_job_id, %DateTime{} = completed_after)
      when is_binary(agent_uid) and is_integer(since_job_id) and since_job_id >= 0 do
    job_ids =
      Job
      |> where([job], job.agent_uid == ^agent_uid)
      |> where([job], job.status in ^Job.terminal_statuses())
      |> where([job], job.id > ^since_job_id)
      |> where([job], coalesce(job.completed_at, job.updated_at) > ^completed_after)
      |> Queries.excluding_reflection_jobs()
      |> order_by([job], desc: job.id)
      |> select([job], job.id)
      |> Repo.all()

    events_by_job = events_by_job(job_ids)

    job_ids
    |> Enum.map(fn job_id ->
      events = Map.get(events_by_job, job_id, [])

      %{
        job_id: job_id,
        human_input_count: events |> human_inputs() |> length(),
        failed_call_count: Enum.count(events, &failed_call?/1)
      }
    end)
    |> Enum.filter(&(&1.human_input_count > 0 or &1.failed_call_count > 0))
  end

  @doc """
  Returns one rendered evidence section per Job id, in the given order.

  Each section contains the bounded task, terminal reason, human input, failed
  calls and their next call in the same Turn, compaction count, and latest Turn
  usage.
  """
  @spec evidence_sections([pos_integer()]) :: [String.t()]
  def evidence_sections(job_ids) when is_list(job_ids) do
    jobs =
      Job
      |> where([job], job.id in ^job_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    events_by_job = events_by_job(job_ids)
    usage_by_job = last_turn_usage(job_ids)

    Enum.map(job_ids, fn job_id ->
      job_section(
        Map.fetch!(jobs, job_id),
        Map.get(events_by_job, job_id, []),
        Map.get(usage_by_job, job_id)
      )
    end)
  end

  defp events_by_job([]), do: %{}

  defp events_by_job(job_ids) do
    TurnItem
    |> join(:inner, [item], turn in Turn, on: item.turn_id == turn.id)
    |> where([_item, turn], turn.job_id in ^job_ids)
    |> where([item, _turn], fragment("? ->> 'type'", item.item) in ^@item_types)
    |> order_by([item, turn], asc: turn.started_at, asc: turn.id, asc: item.position)
    |> select([item, turn], %{job_id: turn.job_id, turn_id: turn.id, item: item.item})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      case projected_event(row.item) do
        nil -> []
        event -> [%{job_id: row.job_id, turn_id: row.turn_id, event: event}]
      end
    end)
    |> Enum.group_by(& &1.job_id)
  end

  defp projected_event(item) do
    {messages, _truncated?} = item |> OpaqueContent.reveal() |> TurnItemProjection.project()
    event_from_messages(messages)
  end

  defp event_from_messages([%{"role" => "user", "content" => content}]),
    do: {:user, user_text(content)}

  defp event_from_messages([%{"tool_calls" => [%{"function" => function}]} = call | result]) do
    cond do
      local_dynamic?(call, result) -> {:call, dynamic_call(function, result)}
      tool_identity(function) == {nil, "shell"} -> shell_event(function, result)
      tool_identity(function) == {nil, "context_compaction"} -> :compaction
      true -> nil
    end
  end

  defp event_from_messages(_messages), do: nil

  defp local_dynamic?(_call, [%{"metadata" => %{"execution_mechanism" => "local_dynamic"}}]),
    do: true

  defp local_dynamic?(call, []),
    do: get_in(call, ["metadata", "status"]) == "pending_user_input"

  defp local_dynamic?(_call, _result), do: false

  defp tool_identity(function), do: {function["namespace"], function["name"]}

  defp shell_event(function, [%{"metadata" => metadata} = result]) do
    exit_code = metadata["exit_code"]

    {:call,
     %{
       description: shell_command(function["arguments"]),
       error: result["content"] || "",
       failed?: not is_nil(exit_code) and to_string(exit_code) != "0"
     }}
  end

  defp shell_event(_function, _result), do: nil

  defp shell_command(arguments) do
    case Ankole.JSON.decode!(arguments) do
      %{"command" => command} when is_binary(command) -> command
      %{"truncated" => true, "preview" => preview} when is_binary(preview) -> preview
      _decoded -> ""
    end
  end

  defp dynamic_call(function, result) do
    tool =
      [function["namespace"], function["name"]]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(".")

    %{
      description: tool <> " args: " <> (function["arguments"] || "{}"),
      error: dynamic_error(result),
      failed?: dynamic_failed?(result)
    }
  end

  defp dynamic_failed?([%{"metadata" => metadata}]),
    do: metadata["success"] in [false, "false"]

  defp dynamic_failed?(_result), do: false

  defp dynamic_error([%{"content" => content} = result]) when is_binary(content) do
    if content == "", do: get_in(result, ["metadata", "status"]) || "", else: content
  end

  defp dynamic_error(_result), do: ""

  defp user_text(content) when is_binary(content), do: String.trim(content)

  defp user_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp human_inputs(events) do
    events
    |> Enum.filter(&match?(%{event: {:user, _text}}, &1))
    |> Enum.drop(1)
  end

  defp failed_call?(%{event: {:call, %{failed?: failed?}}}), do: failed?
  defp failed_call?(_entry), do: false

  defp last_turn_usage([]), do: %{}

  defp last_turn_usage(job_ids) do
    Turn
    |> where([turn], turn.job_id in ^job_ids)
    |> where([turn], not is_nil(turn.usage))
    |> order_by([turn], asc: turn.job_id, desc: turn.started_at, desc: turn.id)
    |> distinct([turn], turn.job_id)
    |> select([turn], {turn.job_id, turn.usage})
    |> Repo.all()
    |> Map.new()
  end

  defp job_section(job, events, usage) do
    [
      "### Job #{job.id} — #{job.title} (#{job.status})",
      "TASK: " <> head(job.task, @task_head_chars)
    ]
    |> Kernel.++(terminal_lines(job))
    |> Kernel.++(human_input_lines(events))
    |> Kernel.++(failed_call_lines(events))
    |> Kernel.++(compaction_line(events))
    |> Kernel.++(usage_line(usage))
    |> Enum.join("\n")
    |> head(@per_job_char_limit)
  end

  defp terminal_lines(job) do
    error = job.error || %{}
    metadata = job.metadata || %{}

    [
      error["summary"] && "ERROR: " <> head(error["summary"], @error_summary_chars),
      metadata["cancel_reason"] && "CANCEL REASON: " <> metadata["cancel_reason"],
      metadata["stop_reason"] && "STOP REASON: " <> metadata["stop_reason"]
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp human_input_lines(events) do
    inputs =
      events
      |> human_inputs()
      |> Enum.take(@human_input_limit)
      |> Enum.map(fn %{event: {:user, text}} ->
        "- \"" <> head(text, @human_input_chars) <> "\""
      end)

    case inputs do
      [] -> ["HUMAN INPUT DURING RUN: none."]
      inputs -> ["HUMAN INPUT DURING RUN:" | inputs]
    end
  end

  defp failed_call_lines(events) do
    groups =
      events
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _index} -> failed_call?(entry) end)
      |> Enum.map(fn {entry, index} -> failed_group(entry, index, events) end)
      |> Enum.uniq_by(& &1.dedup_key)
      |> Enum.take(@failed_group_limit)

    case groups do
      [] -> ["FAILED CALLS: none."]
      groups -> ["FAILED CALLS:" | Enum.flat_map(groups, & &1.lines)]
    end
  end

  defp failed_group(%{event: {:call, call}} = entry, index, events) do
    error_tail = tail(call.error, @failed_call_chars)

    bypass_lines =
      events
      |> Enum.drop(index + 1)
      |> Enum.find(fn next ->
        next.turn_id == entry.turn_id and match?({:call, _call}, next.event)
      end)
      |> case do
        nil ->
          []

        %{event: {:call, next}} ->
          ["  next call in turn: " <> head(next.description, @bypass_call_chars)]
      end

    %{
      dedup_key: {head(call.description, 80), head(error_tail, 80)},
      lines: [
        "- call: " <> head(call.description, @failed_call_chars),
        "  error tail: \"" <> error_tail <> "\""
        | bypass_lines
      ]
    }
  end

  defp compaction_line(events) do
    count = Enum.count(events, &(&1.event == :compaction))
    if count > 0, do: ["CONTEXT COMPACTIONS: #{count}"], else: []
  end

  defp usage_line(nil), do: []

  defp usage_line(usage) do
    total = usage["thread_total"] || %{}

    ["USAGE: input #{total["input_tokens"] || 0}, output #{total["output_tokens"] || 0} tokens"]
  end

  defp head(nil, _limit), do: ""
  defp head(text, limit) when is_binary(text), do: String.slice(text, 0, limit)

  defp tail(nil, _limit), do: ""

  defp tail(text, limit) when is_binary(text) do
    length = String.length(text)
    if length <= limit, do: text, else: String.slice(text, length - limit, limit)
  end
end
