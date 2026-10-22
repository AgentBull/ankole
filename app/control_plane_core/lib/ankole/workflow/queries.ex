defmodule Ankole.Workflow.Queries do
  @moduledoc "Reads workflow and task facts."
  import Ecto.Query, warn: false
  require Ankole.ModelIntegerID
  alias Ankole.Repo
  alias Ankole.Text
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  @result_window_bytes 8000

  def task_session_id(call_id) when Ankole.ModelIntegerID.valid?(call_id) do
    Ankole.Sessions.Key.workflow_task(call_id)
  end

  defp parse_run_id(value) do
    parse_id(value)
  end

  defp parse_call_id(value) do
    parse_id(value)
  end

  def parse_task_session_id(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:workflow_task, id} -> parse_call_id(id)
      _ -> :error
    end
  end

  def task_session_prefix do
    Ankole.Sessions.Key.workflow_task("")
  end

  def get_task_for_agent(call_id, agent_uid)
      when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) do
    query =
      from(call in AgentCall,
        join: run in Run,
        on: run.id == call.run_id,
        where: call.id == ^call_id and call.agent_uid == ^agent_uid,
        select: {call, run}
      )

    case Repo.one(query) do
      {%AgentCall{} = call, %Run{} = run} -> {:ok, %{call: call, run: run}}
      nil -> {:error, :workflow_task_not_found}
    end
  end

  def get(run_id, agent_uid, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(agent_uid) and is_list(opts) do
    case Repo.one(from(run in Run, where: run.id == ^run_id and run.agent_uid == ^agent_uid)) do
      %Run{} = run ->
        with {:ok, result} <- result_projection(run, Keyword.get(opts, :result_offset)) do
          {:ok,
           Map.merge(result, %{
             run: run,
             counts: counts(Repo, run.id),
             failure_summaries: failure_summaries(Repo, run.id),
             live_tasks: live_tasks(Repo, run.id)
           })}
        end

      nil ->
        {:error, :workflow_not_found}
    end
  end

  def list(agent_uid, opts \\ []) when is_binary(agent_uid) and is_list(opts) do
    with {:ok, statuses} <- list_statuses(Keyword.get(opts, :status)),
         {:ok, cursor} <- list_cursor(Keyword.get(opts, :cursor)) do
      query =
        from(run in Run,
          where: run.agent_uid == ^agent_uid and run.status in ^statuses,
          order_by: [desc: run.id],
          limit: 33
        )
        |> maybe_before_cursor(cursor)

      rows = Repo.all(query)
      page = Enum.take(rows, 32)

      next_cursor =
        if length(rows) > 32 do
          page |> List.last() |> then(&Integer.to_string(&1.id))
        end

      {:ok,
       %{
         runs:
           Enum.map(page, fn run ->
             %{
               "run_id" => run.id,
               "title" => run.title,
               "status" => Atom.to_string(run.status)
             }
           end),
         next_cursor: next_cursor
       }}
    end
  end

  def counts(repo, run_id) do
    status_counts =
      AgentCall
      |> where([call], call.run_id == ^run_id)
      |> group_by([call], call.status)
      |> select([call], {call.status, count(call.id)})
      |> repo.all()
      |> Map.new()

    %{
      "total" => Enum.sum(Map.values(status_counts)),
      "queued" => Map.get(status_counts, :queued, 0),
      "running" => Map.get(status_counts, :running, 0),
      "sleeping" => Map.get(status_counts, :sleeping, 0),
      "succeeded" => Map.get(status_counts, :succeeded, 0),
      "failed" => Map.get(status_counts, :failed, 0),
      "cancelled" => Map.get(status_counts, :cancelled, 0)
    }
  end

  def live_tasks(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id and call.status in [:queued, :running, :sleeping])
    |> order_by([call], desc: call.attention, asc: call.call_seq)
    |> limit(32)
    |> repo.all()
    |> Enum.map(fn call ->
      %{
        "call_seq" => call.call_seq,
        "label" => call.label,
        "status" => Atom.to_string(call.status),
        "note" => call.sleep_note,
        "attention" => call.attention,
        "wake_at" => call.wake_at && DateTime.to_iso8601(call.wake_at),
        "wake_count" => call.wake_count
      }
    end)
  end

  def failure_summaries(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id and call.status == :failed)
    |> order_by([call], asc: call.call_seq)
    |> limit(10)
    |> repo.all()
    |> Enum.map(fn call ->
      result = call.result || call.error || %{}

      %{
        "call_seq" => call.call_seq,
        "label" => call.label,
        "code" => Map.get(result, "code", "workflow_task_failed"),
        "summary" => Map.get(result, "summary", "The Workflow task failed.")
      }
    end)
  end

  def task_sessions(run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.id)
    |> select([call], {call.id, call.status})
    |> Repo.all()
    |> Enum.map(fn {call_id, status} -> {task_session_id(call_id), status} end)
  end

  def text_value(value) when is_binary(value) and value != "" do
    value
  end

  def text_value(_value) do
    nil
  end

  def workflow_failure_notice_lines(failure_summaries) when is_list(failure_summaries) do
    failure_summaries
    |> Enum.take(3)
    |> Enum.map(fn summary -> text_value(summary["summary"]) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  def workflow_failure_notice_lines(_failure_summaries) do
    nil
  end

  defp parse_id(value) do
    Ankole.ModelIntegerID.parse(value)
  end

  defp list_statuses(nil) do
    {:ok, [:running]}
  end

  defp list_statuses("") do
    {:ok, [:running]}
  end

  defp list_statuses("live") do
    {:ok, [:running]}
  end

  defp list_statuses("done") do
    {:ok, Run.terminal_statuses()}
  end

  defp list_statuses(_status) do
    {:error, :invalid_workflow_list_status}
  end

  defp list_cursor(nil) do
    {:ok, nil}
  end

  defp list_cursor("") do
    {:ok, nil}
  end

  defp list_cursor(cursor) do
    case parse_run_id(cursor) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_workflow_cursor}
    end
  end

  defp maybe_before_cursor(query, nil) do
    query
  end

  defp maybe_before_cursor(query, cursor) do
    where(query, [run], run.id < ^cursor)
  end

  defp result_projection(_run, nil) do
    {:ok, %{result_output_text: "", result_output_total_bytes: nil}}
  end

  defp result_projection(%Run{status: status}, offset)
       when status != :completed and is_integer(offset) and offset >= 0 do
    {:ok, %{result_output_text: "", result_output_total_bytes: 0}}
  end

  defp result_projection(%Run{result_text: result_text}, offset)
       when is_binary(result_text) and is_integer(offset) and offset >= 0 do
    total = byte_size(result_text)

    cond do
      offset > total ->
        {:error, :invalid_workflow_result_offset}

      not utf8_boundary?(result_text, offset, total) ->
        {:error, :invalid_workflow_result_offset}

      true ->
        remaining = binary_part(result_text, offset, total - offset)

        {:ok,
         %{
           result_output_text: Text.utf8_prefix(remaining, @result_window_bytes),
           result_output_total_bytes: total
         }}
    end
  end

  defp result_projection(%Run{status: :completed}, offset)
       when is_integer(offset) and offset >= 0 do
    {:error, :workflow_result_output_missing}
  end

  defp result_projection(_run, _offset) do
    {:error, :invalid_workflow_result_offset}
  end

  defp utf8_boundary?(_text, offset, total) when offset == total do
    true
  end

  defp utf8_boundary?(text, offset, _total) do
    <<byte>> = binary_part(text, offset, 1)
    byte < 128 or byte >= 192
  end
end
