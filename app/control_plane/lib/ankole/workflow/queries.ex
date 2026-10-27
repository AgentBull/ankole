defmodule Ankole.Workflow.Queries do
  @moduledoc "Reads workflow and task facts."
  import Ecto.Query, only: [from: 2]
  require Ankole.ModelIntegerID
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Text
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  @result_window_bytes 8000
  @call_statuses [:queued, :running, :sleeping, :succeeded, :failed, :cancelled]

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
    with {:ok, %AgentCall{} = call} <-
           AgentCall
           |> Ash.Query.filter(id == ^call_id and agent_uid == ^agent_uid)
           |> Ankole.Ash.read_one(),
         {:ok, %Run{} = run} <-
           Run |> Ash.Query.filter(id == ^call.run_id) |> Ankole.Ash.read_one() do
      {:ok, %{call: call, run: run}}
    else
      {:ok, nil} -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  def get(run_id, agent_uid, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(agent_uid) and is_list(opts) do
    offset = Keyword.get(opts, :result_offset)

    query =
      Run
      |> Ash.Query.filter(id == ^run_id and agent_uid == ^agent_uid)
      |> Ash.Query.select([:id, :agent_uid, :title, :status, :error])

    query =
      if is_integer(offset) and offset >= 0 do
        Ash.Query.load(query, [
          :result_output_bytes,
          result_output_window: [from: offset + 1, bytes: @result_window_bytes]
        ])
      else
        query
      end

    case Ankole.Ash.read_one(query) do
      {:ok, %Run{} = run} ->
        with {:ok, result} <- result_projection(run, offset) do
          details =
            if is_nil(offset) do
              %{
                counts: counts(run.id),
                failure_summaries: failure_summaries(run.id),
                live_tasks: live_tasks(run.id)
              }
            else
              %{}
            end

          {:ok, result |> Map.merge(details) |> Map.put(:run, run)}
        end

      {:ok, nil} ->
        {:error, :workflow_not_found}

      {:error, _} = error ->
        error
    end
  end

  def list(agent_uid, opts \\ []) when is_binary(agent_uid) and is_list(opts) do
    with {:ok, statuses} <- list_statuses(Keyword.get(opts, :status)),
         {:ok, cursor} <- list_cursor(Keyword.get(opts, :cursor)) do
      {:ok, page} =
        Run
        |> Ash.Query.filter(agent_uid == ^agent_uid and status in ^statuses)
        |> maybe_before_cursor(cursor)
        |> Ash.Query.sort(id: :desc)
        |> Ankole.Ash.read(action: :list_page, page: [limit: 32])

      next_cursor =
        if page.more? do
          page.results |> List.last() |> then(&Integer.to_string(&1.id))
        end

      {:ok,
       %{
         runs:
           Enum.map(page.results, fn run ->
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

  def counts(run_id), do: run_id |> List.wrap() |> run_counts() |> Map.fetch!(run_id)

  @doc """
  Counts the calls of each run by status. The result maps each run id to
  `"total"` and one count for each call status.
  """
  def run_counts([]), do: %{}

  def run_counts(run_ids) do
    query =
      Enum.reduce(
        @call_statuses,
        Run |> Ash.Query.filter(id in ^run_ids) |> Ash.Query.select([:id]),
        fn status, query ->
          Ash.Query.aggregate(query, status, :count, :agent_calls,
            query: [filter: [status: status]],
            default: 0,
            authorize?: false
          )
        end
      )

    {:ok, runs} = Ankole.Ash.read(query)

    Map.new(runs, fn run ->
      counts = Map.new(@call_statuses, &{Atom.to_string(&1), Map.fetch!(run.aggregates, &1)})
      {run.id, Map.put(counts, "total", Enum.sum(Map.values(counts)))}
    end)
  end

  def live_tasks(run_id) do
    {:ok, calls} =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id and status in [:queued, :running, :sleeping])
      |> Ash.Query.sort(attention: :desc, call_seq: :asc)
      |> Ash.Query.limit(32)
      |> Ankole.Ash.read()

    Enum.map(calls, fn call ->
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

  def failure_summaries(run_id) do
    {:ok, calls} =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id and status == :failed)
      |> Ash.Query.sort(call_seq: :asc)
      |> Ash.Query.limit(10)
      |> Ankole.Ash.read()

    Enum.map(calls, fn call ->
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
    {:ok, calls} =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.select([:id, :status])
      |> Ankole.Ash.read()

    Enum.map(calls, &{task_session_id(&1.id), &1.status})
  end

  @doc """
  Selects the oldest capacity waiter of an Agent that can run now.

  The waiter is a queued call whose run has free concurrency and whose task
  Signal is deferred past `now`. This read model joins calls, runs, and
  Signals and gives only identifiers.
  """
  def capacity_candidate(agent_uid, now) do
    running_calls =
      from(call in AgentCall,
        where: call.agent_uid == ^agent_uid and call.status == :running,
        group_by: call.run_id,
        select: %{run_id: call.run_id, count: count(call.id)}
      )

    from(call in AgentCall,
      join: run in Run,
      on: run.id == call.run_id,
      left_join: running in subquery(running_calls),
      on: running.run_id == call.run_id,
      join: event in Signal,
      on:
        event.agent_uid == call.agent_uid and
          fragment("? = concat('wf_task:', ?::text)", event.session_id, call.id),
      where:
        call.agent_uid == ^agent_uid and call.status == :queued and run.status == :running and
          coalesce(running.count, 0) < run.concurrency and
          event.status in [:queued, :running] and event.available_at > ^now and
          call.wake_kind == :agent_capacity,
      order_by: [asc: event.inserted_at, asc: event.queue_sequence, asc: call.id],
      select: %{
        run_id: call.run_id,
        call_id: call.id,
        session_id: event.session_id,
        event_id: event.id
      },
      limit: 1
    )
    |> Repo.one()
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
    Ash.Query.filter(query, id < ^cursor)
  end

  defp result_projection(_run, nil) do
    {:ok, %{result_output_text: "", result_output_total_bytes: nil}}
  end

  defp result_projection(%Run{status: status}, offset)
       when status != :completed and is_integer(offset) and offset >= 0 do
    {:ok, %{result_output_text: "", result_output_total_bytes: 0}}
  end

  defp result_projection(%Run{result_output_window: text, result_output_bytes: total}, offset)
       when is_binary(text) and is_integer(total) and is_integer(offset) and offset >= 0 do
    cond do
      offset > total ->
        {:error, :invalid_workflow_result_offset}

      not utf8_boundary?(text, 0, byte_size(text)) ->
        {:error, :invalid_workflow_result_offset}

      true ->
        {:ok,
         %{
           result_output_text: Text.utf8_prefix(text, @result_window_bytes),
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
