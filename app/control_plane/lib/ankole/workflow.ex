defmodule Ankole.Workflow do
  @moduledoc """
  Durable Workflow runs and replay-memo Agent calls.

  PostgreSQL owns lifecycle truth. This module is the stable context facade for
  creation, task transactions, cancellation, and owner-facing reads.
  """

  @behaviour Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ankole.BackgroundAgentJobs
  alias Ankole.I18n
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.Text
  alias Ankole.Workflow.Program
  alias Ankole.Workflow.ResultSchema
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  alias Ankole.Workflow.WorkerConfig

  @task_session_prefix "wf_task:"
  @task_session_prefix_size byte_size(@task_session_prefix)
  @minimum_id 1000
  @maximum_id 9_007_199_254_740_991
  @result_window_bytes 8_000
  @turn_error_retry_base_seconds 5
  @turn_error_retry_max_seconds 120
  @memo_budget_bytes 6 * 1_024 * 1_024
  @value_max_bytes 24 * 1_024
  @capacity_defer_reason "agent_capacity"
  @defer_reason_key "workflow_dispatch_deferred_reason"
  @max_wake_count 16
  @min_wake_after_ms 60_000
  @max_wake_after_ms 172_800_000
  @supported_create_fields ~w(
    agent_uid
    args
    concurrency
    max_agent_calls
    model_profile
    owner_session_id
    reply_route
    script
    source_actor_event_id
    source_tool_call_id
    title
  )

  @spec task_session_id(pos_integer()) :: String.t()
  def task_session_id(call_id)
      when is_integer(call_id) and call_id >= @minimum_id and call_id <= @maximum_id,
      do: @task_session_prefix <> Integer.to_string(call_id)

  defguard is_workflow_task_session_id(session_id)
           when is_binary(session_id) and byte_size(session_id) > @task_session_prefix_size and
                  binary_part(session_id, 0, @task_session_prefix_size) == @task_session_prefix

  @spec parse_run_id(term()) :: {:ok, pos_integer()} | :error
  def parse_run_id(value), do: parse_id(value)

  @spec parse_call_id(term()) :: {:ok, pos_integer()} | :error
  def parse_call_id(value), do: parse_id(value)

  @spec parse_task_session_id(term()) :: {:ok, pos_integer()} | :error
  def parse_task_session_id(@task_session_prefix <> call_id), do: parse_call_id(call_id)
  def parse_task_session_id(_other), do: :error

  @doc false
  def task_session_prefix, do: @task_session_prefix

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def dead_letter_after_turn_error?(%ActorEvent{}, _reason, _recoverable?), do: false

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def turn_error_retry_at(_reason, delivery_attempt_no, %DateTime{} = now)
      when is_integer(delivery_attempt_no) and delivery_attempt_no > 0 do
    exponential =
      round(@turn_error_retry_base_seconds * :math.pow(2, delivery_attempt_no - 1))

    DateTime.add(now, min(exponential, @turn_error_retry_max_seconds), :second)
  end

  @workflow_wakeup_notice_keys %{
    "workflow.run.completed" => "workflow_dead_letter_completed",
    "workflow.run.failed" => "workflow_dead_letter_failed"
  }

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def dead_letter_notice_text(%ActorEvent{type: type} = event)
      when is_map_key(@workflow_wakeup_notice_keys, type) do
    data = get_in(event.payload || %{}, ["data"]) || %{}
    counts = data["counts"] || %{}

    detail =
      [
        text_value(data["result_preview"]),
        workflow_failure_notice_lines(data["failure_summaries"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    I18n.t(
      "signals_gateway.reply.#{Map.fetch!(@workflow_wakeup_notice_keys, type)}",
      %{
        "run_id" => data["run_id"] || 0,
        "title" => text_value(data["title"]) || "",
        "succeeded" => counts["succeeded"] || 0,
        "failed" => counts["failed"] || 0,
        "total" => counts["total"] || 0,
        "detail" => detail
      }
    )
  end

  def dead_letter_notice_text(%ActorEvent{}), do: nil

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def compensate_turn_error_in_tx(
        repo,
        %{agent_uid: agent_uid, session_id: session_id},
        reason,
        %DateTime{} = now
      )
      when is_binary(agent_uid) and is_binary(session_id) and is_map(reason) do
    case parse_task_session_id(session_id) do
      {:ok, call_id} -> compensate_call_in_tx(repo, call_id, agent_uid, reason, now)
      :error -> {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(_repo, _event, _reason, %DateTime{}), do: {:ok, nil}

  @doc false
  @spec authorize_delegated_job_owner_in_tx(module(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def authorize_delegated_job_owner_in_tx(repo, agent_uid, owner_session_id)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(owner_session_id) do
    case parse_task_session_id(owner_session_id) do
      {:ok, call_id} -> authorize_delegated_job_in_tx(repo, call_id, agent_uid)
      :error -> :ok
    end
  end

  @spec submit_result(pos_integer(), String.t(), String.t(), map()) ::
          {:ok, %{accepted: boolean(), call: struct(), run: struct()}} | {:error, term()}
  def submit_result(call_id, agent_uid, session_id, outcome) do
    submit_result_in_storage(call_id, agent_uid, session_id, outcome)
    |> cleanup_terminal_transition()
  end

  @spec fail_unstarted_task(
          pos_integer(),
          String.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, %{accepted: boolean(), call: struct(), run: struct()}} | {:error, term()}
  def fail_unstarted_task(call_id, agent_uid, code, summary, available_at) do
    fail_unstarted_task_in_storage(call_id, agent_uid, code, summary, available_at)
    |> cleanup_terminal_transition()
  end

  def cancel(run_id, agent_uid), do: RunServer.cancel(run_id, agent_uid)

  @doc false
  @spec cleanup_terminal_transition(term()) :: term()
  def cleanup_terminal_transition({:ok, %{turn_error_compensation: compensation} = result}) do
    case cleanup_terminal_transition({:ok, compensation}) do
      {:ok, cleaned_compensation} ->
        {:ok, %{result | turn_error_compensation: cleaned_compensation}}

      other ->
        other
    end
  end

  def cleanup_terminal_transition({:ok, %{run: %Run{status: status} = run} = result})
      when status in ["completed", "failed", "cancelled"] do
    case cleanup_terminal_run(run) do
      {:ok, cleaned_run} ->
        {:ok, result |> Map.put(:run, cleaned_run) |> Map.put(:cleanup_errors, [])}

      {:error, {:workflow_terminal_cleanup_failed, cleanup_errors}} ->
        {:ok, Map.put(result, :cleanup_errors, cleanup_errors)}
    end
  end

  def cleanup_terminal_transition(
        {:ok,
         %{
           run: %Run{} = run,
           running_session_ids: running_session_ids
         } = result}
      )
      when is_list(running_session_ids) do
    cleanup_errors = stop_running_task_turns(run, running_session_ids)
    {:ok, Map.put(result, :cleanup_errors, cleanup_errors)}
  end

  def cleanup_terminal_transition(result), do: result

  @doc false
  @spec cleanup_terminal_run(struct()) ::
          {:ok, struct()} | {:error, {:workflow_terminal_cleanup_failed, [map()]}}
  def cleanup_terminal_run(%Run{cleanup_completed_at: %DateTime{}} = run), do: {:ok, run}

  def cleanup_terminal_run(%Run{status: status} = run)
      when status in ["completed", "failed", "cancelled"] do
    sessions = task_sessions(run.id)
    cancelled_session_ids = for {session_id, "cancelled"} <- sessions, do: session_id
    all_session_ids = Enum.map(sessions, &elem(&1, 0))

    cleanup_errors =
      stop_running_task_turns(run, cancelled_session_ids) ++
        stop_delegated_jobs(run, all_session_ids)

    case cleanup_errors do
      [] ->
        case complete_terminal_cleanup(run.id, DateTime.utc_now(:microsecond)) do
          {:ok, cleaned_run} ->
            {:ok, cleaned_run}

          {:error, reason} ->
            {:error, {:workflow_terminal_cleanup_failed, [%{run_id: run.id, reason: reason}]}}
        end

      errors ->
        {:error, {:workflow_terminal_cleanup_failed, errors}}
    end
  end

  @doc false
  @spec get_task_for_agent(pos_integer(), String.t()) ::
          {:ok, %{call: struct(), run: struct()}} | {:error, :workflow_task_not_found}
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

  @doc false
  @spec complete_task_event(ActorEvent.t(), DateTime.t()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def complete_task_event(%ActorEvent{} = actor_event, %DateTime{} = completed_at) do
    Repo.transact(fn repo ->
      with :ok <-
             Actors.lock_actor_session_in_tx(
               repo,
               actor_event.agent_uid,
               actor_event.session_id
             ) do
        case Actors.lock_actor_event_in_tx(repo, actor_event.id) do
          %ActorEvent{completed_at: %DateTime{}} = completed_event ->
            {:ok, completed_event}

          %ActorEvent{} = open_event ->
            Actors.mark_event_completed_in_tx(repo, open_event, completed_at)

          nil ->
            {:error, :workflow_task_event_not_found}
        end
      end
    end)
  end

  @spec get(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @max_task_message_bytes 8_192

  @doc """
  Appends one owner message to a live Workflow task session.

  A sleeping task wakes on delivery; a running task receives the message when
  its current Turn ends. The append is idempotent per source tool call.
  """
  @spec send_task_message(pos_integer(), non_neg_integer(), String.t(), String.t(), String.t()) ::
          {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def send_task_message(run_id, call_seq, agent_uid, message, source_tool_call_id)
      when is_integer(run_id) and is_integer(call_seq) and call_seq >= 0 and
             is_binary(agent_uid) and is_binary(message) and is_binary(source_tool_call_id) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- validate_task_message(message),
         :ok <- validate_source_tool_call_id(source_tool_call_id) do
      Repo.transact(fn repo ->
        with %Run{} = run <-
               repo.one(
                 from(run in Run, where: run.id == ^run_id and run.agent_uid == ^agent_uid)
               ),
             %AgentCall{} = call <-
               repo.one(
                 from(call in AgentCall,
                   where: call.run_id == ^run_id and call.call_seq == ^call_seq
                 )
               ),
             :ok <- ensure_task_message_target(run, call),
             {:ok, _event} <-
               append_task_message_event(repo, run, call, message, source_tool_call_id, now) do
          {:ok, %{call: call, run: run}}
        else
          nil -> {:error, :workflow_task_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp validate_task_message(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" -> {:error, :invalid_workflow_task_message}
      byte_size(message) > @max_task_message_bytes -> {:error, :workflow_task_message_too_large}
      true -> :ok
    end
  end

  defp validate_source_tool_call_id(value) do
    if String.trim(value) == "", do: {:error, :invalid_workflow_source_tool_call_id}, else: :ok
  end

  defp ensure_task_message_target(%Run{status: "running"}, %AgentCall{status: status})
       when status in ["queued", "running", "sleeping"],
       do: :ok

  defp ensure_task_message_target(%Run{status: "running"}, %AgentCall{status: status}),
    do: {:error, {:workflow_task_terminal, status}}

  defp ensure_task_message_target(%Run{status: status}, _call),
    do: {:error, {:workflow_run_terminal, status}}

  defp append_task_message_event(repo, run, call, message, source_tool_call_id, now) do
    source_event_id = "workflow:call:#{call.id}:msg:#{source_tool_call_id}"
    reply_route = run.reply_route || %{}

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name") do
      SignalsGateway.append_actor_event_in_tx(repo, %{
        agent_uid: run.agent_uid,
        binding_name: binding_name,
        session_id: task_session_id(call.id),
        source_event_id: source_event_id,
        signal_channel_id: nil,
        type: "workflow.task.message",
        available_at: now,
        payload: %{
          "specversion" => "1.0",
          "id" => source_event_id,
          "source" => "control-plane://workflow",
          "subject" => "workflow-call:#{call.id}",
          "time" => DateTime.to_iso8601(now),
          "type" => "workflow.task.message",
          "data" => %{
            "run_id" => run.id,
            "call_id" => call.id,
            "call_seq" => call.call_seq,
            "message" => message
          }
        }
      })
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
    end
  end

  @spec list(String.t(), keyword()) ::
          {:ok, %{runs: [map()], next_cursor: String.t() | nil}} | {:error, term()}
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
        if length(rows) > 32, do: page |> List.last() |> then(&Integer.to_string(&1.id))

      {:ok,
       %{
         runs:
           Enum.map(page, fn run ->
             %{
               "run_id" => Integer.to_string(run.id),
               "title" => run.title,
               "status" => run.status
             }
           end),
         next_cursor: next_cursor
       }}
    end
  end

  @doc false
  @spec counts(module(), pos_integer()) :: map()
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
      "queued" => Map.get(status_counts, "queued", 0),
      "running" => Map.get(status_counts, "running", 0),
      "sleeping" => Map.get(status_counts, "sleeping", 0),
      "succeeded" => Map.get(status_counts, "succeeded", 0),
      "failed" => Map.get(status_counts, "failed", 0),
      "cancelled" => Map.get(status_counts, "cancelled", 0)
    }
  end

  @doc false
  @spec live_tasks(module(), pos_integer()) :: [map()]
  def live_tasks(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id and call.status in ["queued", "running", "sleeping"])
    |> order_by([call], desc: call.attention, asc: call.call_seq)
    |> limit(32)
    |> repo.all()
    |> Enum.map(fn call ->
      %{
        "call_seq" => call.call_seq,
        "label" => call.label,
        "status" => call.status,
        "note" => call.sleep_note,
        "attention" => call.attention,
        "sleeping_until" => call.sleeping_until && DateTime.to_iso8601(call.sleeping_until),
        "wake_count" => call.wake_count
      }
    end)
  end

  @doc false
  @spec failure_summaries(module(), pos_integer()) :: [map()]
  def failure_summaries(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id and call.status == "failed")
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

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    Run
    |> where([run], is_nil(run.cleanup_completed_at))
    |> order_by([run], asc: run.id)
    |> select([run], run.id)
    |> Repo.all()
    |> Enum.map(fn run_id ->
      {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run_id}}
    end)
  end

  defp task_sessions(run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.id)
    |> select([call], {call.id, call.status})
    |> Repo.all()
    |> Enum.map(fn {call_id, status} -> {task_session_id(call_id), status} end)
  end

  defp stop_running_task_turns(run, session_ids) do
    now = DateTime.utc_now(:microsecond)

    Enum.flat_map(session_ids, fn session_id ->
      case append_stop_event(run, session_id, now) do
        {:ok, _event} -> []
        {:error, reason} -> [%{session_id: session_id, reason: reason}]
      end
    end)
  end

  defp append_stop_event(run, session_id, now) do
    reply_route = run.reply_route || %{}
    call_id = String.replace_prefix(session_id, task_session_prefix(), "")
    source_event_id = "workflow:call:#{call_id}:stop"

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name") do
      SignalsGateway.append_actor_event(%{
        agent_uid: run.agent_uid,
        binding_name: binding_name,
        session_id: session_id,
        source_event_id: source_event_id,
        signal_channel_id: nil,
        type: "command.stop",
        available_at: now,
        payload: %{
          "specversion" => "1.0",
          "id" => source_event_id,
          "source" => "control-plane://workflow",
          "subject" => "workflow-call:#{call_id}",
          "time" => DateTime.to_iso8601(now),
          "type" => "command.stop",
          "data" => %{
            "command" => %{
              "argsText" => task_stop_reason(run.status),
              "cancel_requested_by" => "workflow"
            }
          }
        }
      })
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
    end
  end

  defp task_stop_reason("cancelled"), do: "Workflow cancelled"
  defp task_stop_reason(status), do: "Workflow ended with status #{status}"

  # A task session is the owner session of every Job it created, so the task
  # session list is the complete delegated-Job index without a binding column.
  defp stop_delegated_jobs(%Run{} = run, session_ids) do
    session_ids
    |> BackgroundAgentJobs.live_job_ids_for_owner_sessions(run.agent_uid)
    |> Enum.flat_map(fn job_id ->
      case BackgroundAgentJobs.request_stop(job_id, %{
             "agent_uid" => run.agent_uid,
             "cancel_requested_by" => "workflow:#{run.id}"
           }) do
        {:ok, _result} -> []
        {:error, reason} -> [%{job_id: job_id, reason: reason}]
      end
    end)
  end

  defp text_value(value) when is_binary(value) and value != "", do: value
  defp text_value(_value), do: nil

  defp workflow_failure_notice_lines(failure_summaries) when is_list(failure_summaries) do
    failure_summaries
    |> Enum.take(3)
    |> Enum.map(fn summary -> text_value(summary["summary"]) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp workflow_failure_notice_lines(_failure_summaries), do: nil

  defp parse_id(value)
       when is_integer(value) and value >= @minimum_id and value <= @maximum_id,
       do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= @minimum_id and parsed <= @maximum_id ->
        if Integer.to_string(parsed) == value, do: {:ok, parsed}, else: :error

      _parsed ->
        :error
    end
  end

  defp parse_id(_value), do: :error

  defp list_statuses(nil), do: {:ok, ["running"]}
  defp list_statuses(""), do: {:ok, ["running"]}
  defp list_statuses("live"), do: {:ok, ["running"]}
  defp list_statuses("done"), do: {:ok, Run.terminal_statuses()}
  defp list_statuses(_status), do: {:error, :invalid_workflow_list_status}

  defp list_cursor(nil), do: {:ok, nil}
  defp list_cursor(""), do: {:ok, nil}

  defp list_cursor(cursor) do
    case parse_run_id(cursor) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_workflow_cursor}
    end
  end

  defp maybe_before_cursor(query, nil), do: query
  defp maybe_before_cursor(query, cursor), do: where(query, [run], run.id < ^cursor)

  defp result_projection(_run, nil),
    do: {:ok, %{result_output_text: "", result_output_total_bytes: nil}}

  defp result_projection(%Run{status: status}, _offset) when status != "completed",
    do: {:ok, %{result_output_text: "", result_output_total_bytes: 0}}

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

  defp result_projection(%Run{status: "completed"}, _offset),
    do: {:error, :workflow_result_output_missing}

  defp result_projection(_run, _offset), do: {:error, :invalid_workflow_result_offset}

  defp utf8_boundary?(_text, offset, total) when offset == total, do: true

  defp utf8_boundary?(text, offset, _total) do
    <<byte>> = binary_part(text, offset, 1)
    byte < 0x80 or byte >= 0xC0
  end

  @spec create_with_dispatch(map()) :: {:ok, %{run: struct()}} | {:error, term()}
  def create_with_dispatch(attrs) when is_map(attrs) do
    with :ok <- validate_string_keys(attrs),
         :ok <- reject_unsupported_fields(attrs),
         {:ok, agent_uid} <- Principals.normalize_uid(text(attrs, "agent_uid")),
         {:ok, owner_session_id} <- required_text(attrs, "owner_session_id"),
         {:ok, source_tool_call_id} <- required_text(attrs, "source_tool_call_id"),
         {:ok, reply_route} <- reply_route(attrs),
         {:ok, concurrency} <-
           bounded_limit(attrs, "concurrency", WorkerConfig.max_concurrency_per_run()),
         {:ok, max_agent_calls} <-
           bounded_limit(attrs, "max_agent_calls", WorkerConfig.max_agent_calls_per_run()) do
      attrs =
        attrs
        |> Map.put("agent_uid", agent_uid)
        |> Map.put("owner_session_id", owner_session_id)
        |> Map.put("source_tool_call_id", source_tool_call_id)
        |> Map.put("reply_route", reply_route)
        |> Map.put("concurrency", concurrency)
        |> Map.put("max_agent_calls", max_agent_calls)
        |> Map.put_new("args", %{})
        |> Map.put("status", "running")
        |> Map.put("error", %{})

      Repo.transact(fn repo -> persist_in_tx(repo, attrs) end)
    end
  end

  defp persist_in_tx(repo, attrs) do
    with :ok <- lock_idempotency(repo, attrs) do
      case find_existing(repo, attrs) do
        %Run{status: "running"} = run ->
          with :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id) do
            {:ok, %{run: run}}
          end

        %Run{} = run ->
          {:ok, %{run: run}}

        nil ->
          with {:ok, run} <- repo.insert(Run.creation_changeset(%Run{}, attrs)),
               :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id) do
            {:ok, %{run: run}}
          end
      end
    end
  end

  defp find_existing(repo, attrs) do
    Run
    |> where([run], run.agent_uid == ^attrs["agent_uid"])
    |> where([run], run.owner_session_id == ^attrs["owner_session_id"])
    |> where([run], run.source_tool_call_id == ^attrs["source_tool_call_id"])
    |> repo.one()
  end

  defp lock_idempotency(repo, attrs) do
    key =
      [
        "workflow:create",
        attrs["agent_uid"],
        attrs["owner_session_id"],
        attrs["source_tool_call_id"]
      ]
      |> Enum.join(":")

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_string_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(not is_binary(&1))) do
      nil -> :ok
      key -> {:error, {:invalid_workflow_attribute_key, key}}
    end
  end

  defp reject_unsupported_fields(attrs) do
    case Map.keys(attrs) |> Enum.reject(&(&1 in @supported_create_fields)) |> Enum.sort() do
      [] -> :ok
      fields -> {:error, {:unsupported_workflow_create_fields, fields}}
    end
  end

  defp reply_route(attrs) do
    case Map.get(attrs, "reply_route") do
      route when is_map(route) ->
        with :ok <- validate_string_keys(route),
             {:ok, binding_name} <- required_text(route, "binding_name") do
          {:ok, Map.put(route, "binding_name", binding_name)}
        end

      _value ->
        {:error, :invalid_workflow_reply_route}
    end
  end

  defp bounded_limit(attrs, "concurrency", configured_maximum) do
    case Map.get(attrs, "concurrency") do
      nil -> {:ok, configured_maximum}
      value when is_integer(value) and value in 1..32 -> {:ok, min(value, configured_maximum)}
      _value -> {:error, {:invalid_workflow_concurrency, %{min: 1, max: 32}}}
    end
  end

  defp bounded_limit(attrs, "max_agent_calls", configured_maximum) do
    case Map.get(attrs, "max_agent_calls") do
      nil ->
        {:ok, configured_maximum}

      value when is_integer(value) and value in 1..1_024 ->
        {:ok, min(value, configured_maximum)}

      _value ->
        {:error, {:invalid_workflow_max_agent_calls, %{min: 1, max: 1_024}}}
    end
  end

  defp required_text(attrs, "owner_session_id") do
    case text(attrs, "owner_session_id") do
      nil -> {:error, :workflow_owner_session_id_required}
      value -> {:ok, value}
    end
  end

  defp required_text(attrs, "source_tool_call_id") do
    case text(attrs, "source_tool_call_id") do
      nil -> {:error, :workflow_source_tool_call_id_required}
      value -> {:ok, value}
    end
  end

  defp required_text(attrs, "binding_name") do
    case text(attrs, "binding_name") do
      nil -> {:error, :workflow_reply_route_binding_missing}
      value -> {:ok, value}
    end
  end

  defp required_text(attrs, key) do
    case text(attrs, key) do
      nil -> {:error, :workflow_required_text_missing}
      value -> {:ok, value}
    end
  end

  defp text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  @doc false
  @spec commit_replay_pending(pos_integer(), [map()], non_neg_integer()) ::
          {:ok, %{run: struct(), new_calls: [struct()]}} | {:error, term()}
  def commit_replay_pending(run_id, pending_calls, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_list(pending_calls) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      commit_replay_pending_in_tx(repo, run_id, pending_calls, expected_memo_length)
    end)
  end

  @doc false
  @spec complete_replay(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, %{run: struct(), wakeup_event: struct() | nil}} | {:error, term()}
  def complete_replay(run_id, result_text, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_binary(result_text) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      case lock_run(repo, run_id) do
        %Run{status: "running"} = run ->
          calls = lock_run_calls_by_sequence(repo, run.id)

          with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
            conclude_run_in_tx(repo, run, "completed", result_text, %{}, now())
          end

        %Run{} = run ->
          {:ok, %{run: run, wakeup_event: nil}}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
  end

  @doc false
  @spec fail_replay(pos_integer(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, %{run: struct(), wakeup_event: struct() | nil}} | {:error, term()}
  def fail_replay(run_id, code, summary, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_binary(code) and is_binary(summary) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      case lock_run(repo, run_id) do
        %Run{status: "running"} = run ->
          calls = lock_run_calls_by_sequence(repo, run.id)

          with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
            error = %{
              "code" => Text.utf8_prefix(code, 128),
              "summary" => Text.utf8_prefix(summary, 2_000)
            }

            conclude_run_in_tx(repo, run, "failed", nil, error, now())
          end

        %Run{} = run ->
          {:ok, %{run: run, wakeup_event: nil}}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
  end

  @doc false
  @spec reconcile_stale_tasks(pos_integer(), DateTime.t(), DateTime.t()) ::
          {:ok,
           %{
             run: struct(),
             reconciled: non_neg_integer(),
             running_session_ids: [String.t()]
           }}
          | {:error, term()}
  def reconcile_stale_tasks(run_id, %DateTime{} = cutoff, %DateTime{} = reconciled_at)
      when is_integer(run_id) and run_id > 0 do
    Repo.transact(fn repo ->
      with %Run{} = snapshot <- repo.get(Run, run_id),
           :ok <- lock_agent_slots(repo, snapshot.agent_uid),
           %Run{} = run <- lock_run(repo, run_id, snapshot.agent_uid) do
        if run.status == "running" do
          calls =
            AgentCall
            |> where(
              [call],
              call.run_id == ^run.id and call.status == "running" and
                call.updated_at < ^cutoff
            )
            |> order_by([call], asc: call.call_seq)
            |> lock("FOR UPDATE")
            |> repo.all()

          calls
          |> Enum.reduce_while({:ok, 0, run, []}, fn call,
                                                     {:ok, count, current_run, running_ids} ->
            failure = %{
              "code" => "workflow_task_stale",
              "summary" => "The Workflow task Turn did not finish before the one-hour watchdog.",
              "retryable" => true
            }

            case commit_failure(
                   repo,
                   current_run,
                   call,
                   failure,
                   call.attempts < 3,
                   reconciled_at
                 ) do
              {:ok, %{run: %Run{} = next_run} = result} ->
                next =
                  {:ok, count + 1, next_run,
                   Map.get(result, :running_session_ids, []) ++ running_ids}

                if next_run.status == "running", do: {:cont, next}, else: {:halt, next}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, count, current_run, running_ids} ->
              with {:ok, overdue_count, current_run} <-
                     reconcile_overdue_sleeping(repo, current_run, cutoff, reconciled_at) do
                {:ok,
                 %{
                   run: current_run,
                   reconciled: count + overdue_count,
                   running_session_ids: Enum.reverse(running_ids)
                 }}
              end

            {:error, _reason} = error ->
              error
          end
        else
          {:ok, %{run: run, reconciled: 0, running_session_ids: []}}
        end
      else
        nil -> {:error, :workflow_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  # An overdue sleeping call has slept past its deadline plus the stale window.
  # An open mailbox event still owns redelivery, so a nudge is enough; a call
  # with no open event lost its wake and must fail instead of sleeping forever.
  defp reconcile_overdue_sleeping(_repo, %Run{status: status} = run, _cutoff, _now)
       when status != "running",
       do: {:ok, 0, run}

  defp reconcile_overdue_sleeping(repo, run, cutoff, now) do
    calls =
      AgentCall
      |> where(
        [call],
        call.run_id == ^run.id and call.status == "sleeping" and call.sleeping_until < ^cutoff
      )
      |> order_by([call], asc: call.call_seq)
      |> lock("FOR UPDATE")
      |> repo.all()

    Enum.reduce_while(calls, {:ok, 0, run}, fn call, {:ok, count, current_run} ->
      case recover_overdue_sleeping(repo, current_run, call, now) do
        :notified ->
          {:cont, {:ok, count + 1, current_run}}

        {:ok, %{run: %Run{} = next_run}} ->
          next = {:ok, count + 1, next_run}
          if next_run.status == "running", do: {:cont, next}, else: {:halt, next}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_overdue_sleeping(repo, run, call, now) do
    if open_task_event?(repo, call) do
      case notify_task_ready(repo, call, now) do
        :ok -> :notified
        {:error, _reason} = error -> error
      end
    else
      failure = %{
        "code" => "workflow_task_wake_lost",
        "summary" => "The Workflow task lost its wake event after its sleep deadline.",
        "retryable" => false
      }

      commit_failure(repo, run, call, failure, false, now)
    end
  end

  defp open_task_event?(repo, call) do
    session_id = task_session_id(call.id)

    ActorEvent
    |> where(
      [event],
      event.agent_uid == ^call.agent_uid and event.session_id == ^session_id and
        event.input_state == "open" and is_nil(event.completed_at)
    )
    |> repo.exists?()
  end

  @doc false
  @spec claim_task_in_tx(module(), pos_integer(), String.t(), pos_integer()) ::
          {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def claim_task_in_tx(repo, call_id, agent_uid, max_running_per_agent)
      when is_atom(repo) and is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and
             is_integer(max_running_per_agent) and max_running_per_agent > 0 do
    with :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid),
         :ok <- ensure_claimable(run, call),
         :ok <- enforce_capacity(repo, run, max_running_per_agent),
         {:ok, call} <-
           call
           |> AgentCall.changeset(%{
             status: "running",
             attempts: call.attempts + 1,
             attention: false,
             error: %{}
           })
           |> repo.update() do
      {:ok, %{call: call, run: run}}
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec authorize_delegated_job_in_tx(module(), pos_integer(), String.t()) ::
          :ok | {:error, term()}
  def authorize_delegated_job_in_tx(repo, call_id, agent_uid)
      when is_atom(repo) and is_integer(call_id) and call_id > 0 and is_binary(agent_uid) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid),
         :ok <- ensure_delegated_job_owner_running(run, call) do
      :ok
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec claim_task_for_dispatch_in_tx(
          module(),
          ActorEvent.t(),
          pos_integer(),
          String.t(),
          pos_integer()
        ) :: {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def claim_task_for_dispatch_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        call_id,
        agent_uid,
        max_running_per_agent
      ) do
    with {:ok, result} <- claim_task_in_tx(repo, call_id, agent_uid, max_running_per_agent),
         :ok <- clear_task_event_defer_in_tx(repo, actor_event) do
      {:ok, result}
    end
  end

  @doc false
  @spec defer_task_event(ActorEvent.t(), DateTime.t(), atom()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def defer_task_event(%ActorEvent{} = actor_event, %DateTime{} = available_at, reason)
      when is_atom(reason) do
    Repo.transact(fn repo ->
      with :ok <-
             Actors.lock_actor_session_in_tx(
               repo,
               actor_event.agent_uid,
               actor_event.session_id
             ) do
        case Actors.lock_actor_event_in_tx(repo, actor_event.id) do
          %ActorEvent{completed_at: %DateTime{}} = completed_event ->
            {:ok, completed_event}

          %ActorEvent{} = open_event ->
            with {:ok, deferred_event} <-
                   open_event
                   |> ActorEvent.changeset(%{
                     available_at: available_at,
                     payload: put_dispatch_defer_reason(open_event.payload, reason)
                   })
                   |> repo.update(),
                 :ok <-
                   RuntimeEvents.notify_actor_session_ready(
                     repo,
                     deferred_event.agent_uid,
                     deferred_event.session_id,
                     deferred_event.available_at
                   ) do
              {:ok, deferred_event}
            end

          nil ->
            {:error, :workflow_task_event_not_found}
        end
      end
    end)
  end

  @spec submit_result_in_storage(pos_integer(), String.t(), String.t(), map()) ::
          {:ok, %{accepted: boolean(), call: struct(), run: struct()}} | {:error, term()}
  defp submit_result_in_storage(call_id, agent_uid, session_id, outcome)
       when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and
              is_binary(session_id) and is_map(outcome) do
    Repo.transact(fn repo ->
      submit_result_in_tx(repo, call_id, agent_uid, session_id, outcome)
    end)
  end

  @doc false
  @spec submit_result_in_tx(module(), pos_integer(), String.t(), String.t(), map()) ::
          {:ok, %{accepted: boolean(), call: struct(), run: struct()}} | {:error, term()}
  def submit_result_in_tx(repo, call_id, agent_uid, session_id, outcome) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      submit_locked(repo, run, call, outcome, now())
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec sleep_task(pos_integer(), String.t(), String.t(), map()) ::
          {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def sleep_task(call_id, agent_uid, session_id, params)
      when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and
             is_binary(session_id) and is_map(params) do
    Repo.transact(fn repo -> sleep_task_in_tx(repo, call_id, agent_uid, session_id, params) end)
  end

  @doc false
  @spec sleep_task_in_tx(module(), pos_integer(), String.t(), String.t(), map()) ::
          {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def sleep_task_in_tx(repo, call_id, agent_uid, session_id, params) do
    with {:ok, wake_after_ms} <- validate_wake_after(Map.get(params, :wake_after_ms)),
         {:ok, note} <- validate_sleep_note(Map.get(params, :note)),
         :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      sleep_locked(repo, run, call, wake_after_ms, note, Map.get(params, :attention) == true)
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec requeue_unstarted_task(
          pos_integer(),
          String.t(),
          pos_integer(),
          DateTime.t()
        ) :: {:ok, %{call: struct(), run: struct()}} | {:error, term()}
  def requeue_unstarted_task(call_id, agent_uid, expected_attempt, %DateTime{} = available_at)
      when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and
             is_integer(expected_attempt) and expected_attempt > 0 do
    Repo.transact(fn repo ->
      with :ok <- lock_agent_slots(repo, agent_uid),
           {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
           %Run{} = run <- lock_run(repo, run_id, agent_uid),
           %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid) do
        requeue_unstarted_locked(repo, run, call, expected_attempt, available_at)
      else
        nil -> {:error, :workflow_task_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec fail_unstarted_task_in_storage(
          pos_integer(),
          String.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, %{accepted: boolean(), call: struct(), run: struct()}} | {:error, term()}
  defp fail_unstarted_task_in_storage(
         call_id,
         agent_uid,
         code,
         summary,
         %DateTime{} = available_at
       )
       when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and is_binary(code) and
              is_binary(summary) do
    Repo.transact(fn repo ->
      with :ok <- lock_agent_slots(repo, agent_uid),
           {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
           %Run{} = run <- lock_run(repo, run_id, agent_uid),
           %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid) do
        failure = %{
          "code" => Text.utf8_prefix(code, 128),
          "summary" => Text.utf8_prefix(summary, 2_000),
          "retryable" => false
        }

        cond do
          run.status != "running" ->
            {:ok, %{accepted: false, call: call, run: run}}

          call.status == "queued" ->
            commit_failure(repo, run, call, failure, false, available_at)

          call.status in AgentCall.terminal_statuses() ->
            {:ok, %{accepted: false, call: call, run: run}}

          true ->
            {:error, {:workflow_task_not_queued, call.status}}
        end
      else
        nil -> {:error, :workflow_task_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec cancel_in_storage(pos_integer(), String.t()) ::
          {:ok, %{run: struct(), running_session_ids: [String.t()]}} | {:error, term()}
  def cancel_in_storage(run_id, agent_uid)
      when is_integer(run_id) and run_id > 0 and is_binary(agent_uid) do
    Repo.transact(fn repo -> cancel_in_tx(repo, run_id, agent_uid) end)
  end

  @doc false
  @spec complete_terminal_cleanup(pos_integer(), DateTime.t()) ::
          {:ok, struct()} | {:error, term()}
  def complete_terminal_cleanup(run_id, %DateTime{} = completed_at)
      when is_integer(run_id) and run_id > 0 do
    Repo.transact(fn repo ->
      case lock_run(repo, run_id) do
        %Run{cleanup_completed_at: %DateTime{}} = run ->
          {:ok, run}

        %Run{status: status} = run when status in ["completed", "failed", "cancelled"] ->
          run
          |> Run.changeset(%{cleanup_completed_at: completed_at})
          |> repo.update()

        %Run{status: "running"} ->
          {:error, :workflow_run_not_terminal}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
  end

  defp cancel_in_tx(repo, run_id, agent_uid) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid) do
      if run.status == "running" do
        completed_at = now()

        with {:ok, running_ids} <- cancel_live_calls_in_tx(repo, run.id, completed_at),
             {:ok, run} <-
               run
               |> Run.changeset(%{status: "cancelled", completed_at: completed_at, error: %{}})
               |> repo.update(),
             :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id) do
          {:ok, %{run: run, running_session_ids: running_ids}}
        end
      else
        {:ok, %{run: run, running_session_ids: []}}
      end
    else
      nil -> {:error, :workflow_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp commit_replay_pending_in_tx(repo, run_id, pending_calls, expected_memo_length) do
    case lock_run(repo, run_id) do
      %Run{status: "running"} = run ->
        calls = lock_run_calls_by_sequence(repo, run.id)

        with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
          case Program.stall_diff(calls, pending_calls, run.max_agent_calls) do
            {:ok, %{new_calls: new_calls}} ->
              case prepare_new_calls(run, new_calls) do
                {:ok, call_changesets, memo_bytes} ->
                  case insert_and_dispatch_calls(repo, run, call_changesets, now()) do
                    {:ok, calls} ->
                      with {:ok, run} <- update_run_memo_bytes(repo, run, memo_bytes) do
                        {:ok, %{run: run, new_calls: calls}}
                      end

                    {:error, _reason} = error ->
                      error
                  end

                {:error, reason} ->
                  fail_pending_commit(repo, run, reason)
              end

            {:error, reason} ->
              fail_pending_commit(repo, run, reason)
          end
        end

      %Run{} = run ->
        {:ok, %{run: run, new_calls: []}}

      nil ->
        {:error, :workflow_not_found}
    end
  end

  defp ensure_replay_snapshot(calls, expected_memo_length) do
    {_memo, actual_memo_length} = Program.memo_prefix(calls)

    if actual_memo_length == expected_memo_length,
      do: :ok,
      else: {:error, :workflow_replay_snapshot_changed}
  end

  defp prepare_new_calls(run, new_calls) do
    with true <-
           is_binary(Map.get(run.reply_route || %{}, "binding_name")) ||
             {:error, :workflow_reply_route_binding_missing} do
      Enum.reduce_while(new_calls, {:ok, [], run.memo_bytes}, fn new_call,
                                                                 {:ok, changesets, bytes} ->
        arguments = new_call.arguments

        with :ok <- validate_agent_arguments(arguments),
             {:ok, encoded} <- Torque.encode(arguments),
             total = bytes + byte_size(encoded),
             true <- total <= @memo_budget_bytes || {:error, :workflow_memo_budget_exceeded},
             attrs = call_attrs(run, new_call.call_seq, arguments),
             %Ecto.Changeset{valid?: true} = changeset <-
               AgentCall.creation_changeset(%AgentCall{}, attrs) do
          {:cont, {:ok, [changeset | changesets], total}}
        else
          %Ecto.Changeset{} = changeset ->
            {:halt, {:error, {:invalid_workflow_agent_call, changeset.errors}}}

          {:error, reason} ->
            {:halt, {:error, reason}}

          false ->
            {:halt, {:error, :workflow_memo_budget_exceeded}}
        end
      end)
      |> case do
        {:ok, changesets, bytes} -> {:ok, Enum.reverse(changesets), bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp insert_and_dispatch_calls(repo, run, call_changesets, inserted_at) do
    Enum.reduce_while(call_changesets, {:ok, []}, fn changeset, {:ok, calls} ->
      with {:ok, call} <- repo.insert(changeset),
           {:ok, _event} <- append_dispatch_event(repo, run, call, inserted_at) do
        {:cont, {:ok, [call | calls]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _reason} = error -> error
    end
  end

  defp append_dispatch_event(repo, run, call, inserted_at) do
    source_event_id = "workflow:call:#{call.id}:dispatch"
    reply_route = run.reply_route || %{}
    arguments = call.arguments

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name") do
      SignalsGateway.append_actor_event_in_tx(repo, %{
        agent_uid: run.agent_uid,
        binding_name: binding_name,
        session_id: task_session_id(call.id),
        source_event_id: source_event_id,
        # Workflow tasks own an independent conversation. They have no Signal
        # channel origin even when the owner run came from one.
        signal_channel_id: nil,
        type: "workflow.task.dispatch",
        available_at: inserted_at,
        payload: %{
          "specversion" => "1.0",
          "id" => source_event_id,
          "source" => "control-plane://workflow",
          "subject" => "workflow-call:#{call.id}",
          "time" => DateTime.to_iso8601(inserted_at),
          "type" => "workflow.task.dispatch",
          "data" => %{
            "run_id" => run.id,
            "call_id" => call.id,
            "call_seq" => call.call_seq,
            "prompt" => Map.fetch!(arguments, "prompt"),
            "label" => call.label,
            "model_profile" => call.model_profile || run.model_profile,
            "schema" => Map.get(arguments, "schema", %{"type" => "string"}),
            "attempts" => call.attempts
          }
        }
      })
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
    end
  end

  defp fail_pending_commit(repo, run, reason) do
    {code, summary} = pending_failure(reason)
    error = %{"code" => code, "summary" => summary}

    with {:ok, result} <- conclude_run_in_tx(repo, run, "failed", nil, error, now()) do
      {:ok, result |> Map.put(:new_calls, [])}
    end
  end

  defp pending_failure({:workflow_replay_diverged, _details}) do
    {"workflow_replay_diverged",
     "Workflow replay no longer matches its durable Agent-call transcript."}
  end

  defp pending_failure({:workflow_agent_limit_exceeded, %{used: used, max: maximum}}) do
    {"workflow_agent_limit_exceeded",
     "Workflow replay requested #{used} Agent calls, above the run limit of #{maximum}. Reduce the fanout or split the "}
  end

  defp pending_failure(:workflow_memo_budget_exceeded) do
    {"workflow_memo_budget_exceeded",
     "Workflow memo data exceeded 6 MiB. Use fewer tasks, return summaries, or split the "}
  end

  defp pending_failure(reason) do
    {"workflow_agent_call_invalid",
     "Workflow replay produced an invalid Agent call: #{inspect(reason, limit: 10)}"}
  end

  defp conclude_run_in_tx(repo, run, status, result_text, error, completed_at) do
    with {:ok, running_ids} <- cancel_live_calls_in_tx(repo, run.id, completed_at),
         {:ok, run} <-
           run
           |> Run.changeset(%{
             status: status,
             result_text: result_text,
             error: error,
             completed_at: completed_at
           })
           |> repo.update(),
         {:ok, wakeup_event} <- append_wakeup_event(repo, run, completed_at),
         :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id) do
      {:ok, %{run: run, wakeup_event: wakeup_event, running_session_ids: running_ids}}
    end
  end

  defp cancel_live_calls_in_tx(repo, run_id, updated_at) do
    calls = lock_run_calls(repo, run_id)

    running_ids =
      for %AgentCall{status: "running", id: id} <- calls,
          do: task_session_id(id)

    with {_count, _rows} <-
           AgentCall
           |> where(
             [call],
             call.run_id == ^run_id and call.status in ["queued", "running", "sleeping"]
           )
           |> repo.update_all(
             set: [status: "cancelled", result: nil, error: %{}, updated_at: updated_at]
           ) do
      {:ok, running_ids}
    end
  end

  defp append_wakeup_event(repo, %Run{status: status} = run, completed_at)
       when status in ["completed", "failed"] do
    event_type = "workflow.run.#{status}"
    source_event_id = "workflow:#{run.id}:#{status}"
    reply_route = run.reply_route || %{}

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name") do
      SignalsGateway.append_actor_event_in_tx(repo, %{
        agent_uid: run.agent_uid,
        binding_name: binding_name,
        session_id: run.owner_session_id,
        source_event_id: source_event_id,
        signal_channel_id: Map.get(reply_route, "signal_channel_id"),
        provider_thread_id: Map.get(reply_route, "provider_thread_id"),
        source_entry_id: Map.get(reply_route, "source_entry_id"),
        type: event_type,
        available_at: completed_at,
        payload: wakeup_payload(run, source_event_id, event_type, completed_at, repo)
      })
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
    end
  end

  defp append_wakeup_event(_repo, %Run{}, _completed_at), do: {:ok, nil}

  defp wakeup_payload(run, source_event_id, event_type, completed_at, repo) do
    counts = counts(repo, run.id)

    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://workflow",
      "subject" => "workflow:#{run.id}",
      "time" => DateTime.to_iso8601(completed_at),
      "type" => event_type,
      "data" => %{
        "run_id" => run.id,
        "title" => run.title,
        "status" => run.status,
        "counts" => Map.take(counts, ["total", "succeeded", "failed"]),
        "failure_summaries" => failure_summaries(repo, run.id),
        "result_preview" => Text.utf8_prefix(run.result_text || "", 2_048),
        "reply_route" => run.reply_route || %{}
      }
    }
  end

  defp sleep_locked(repo, %Run{status: status} = run, call, _wake_after_ms, _note, _attention?)
       when status != "running" do
    if call.status == "running" do
      with {:ok, call} <-
             update_call(repo, call, %{status: "cancelled", result: nil, error: %{}}),
           :ok <- notify_task_ready(repo, call, now()) do
        {:ok, %{call: call, run: run}}
      end
    else
      {:ok, %{call: call, run: run}}
    end
  end

  defp sleep_locked(_repo, %Run{}, %AgentCall{status: status}, _wake_after_ms, _note, _attention?)
       when status != "running",
       do: {:error, {:workflow_task_not_running, status}}

  defp sleep_locked(
         _repo,
         %Run{},
         %AgentCall{wake_count: wake_count},
         _wake_after_ms,
         _note,
         _attention?
       )
       when wake_count >= @max_wake_count,
       do: {:error, :workflow_task_wake_budget_exhausted}

  defp sleep_locked(repo, run, call, wake_after_ms, note, attention?) do
    now = now()

    with {:ok, call} <-
           update_call(repo, call, %{
             status: "sleeping",
             attempts: 0,
             sleep_note: note,
             sleeping_until: DateTime.add(now, wake_after_ms, :millisecond),
             wake_count: call.wake_count + 1,
             attention: attention?,
             error: %{}
           }),
         {:ok, _wake_event} <- append_wake_event(repo, run, call, now),
         :ok <- maybe_append_attention_event(repo, run, call, attention?, now),
         :ok <- wake_next_capacity_deferred_task(repo, run, now) do
      {:ok, %{call: call, run: run}}
    end
  end

  defp append_wake_event(repo, run, call, now) do
    source_event_id = "workflow:call:#{call.id}:wake:#{call.wake_count}"
    reply_route = run.reply_route || %{}

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name") do
      SignalsGateway.append_actor_event_in_tx(repo, %{
        agent_uid: run.agent_uid,
        binding_name: binding_name,
        session_id: task_session_id(call.id),
        source_event_id: source_event_id,
        signal_channel_id: nil,
        type: "workflow.task.wakeup",
        available_at: call.sleeping_until,
        payload: %{
          "specversion" => "1.0",
          "id" => source_event_id,
          "source" => "control-plane://workflow",
          "subject" => "workflow-call:#{call.id}",
          "time" => DateTime.to_iso8601(now),
          "type" => "workflow.task.wakeup",
          "data" => %{
            "run_id" => run.id,
            "call_id" => call.id,
            "call_seq" => call.call_seq,
            "note" => call.sleep_note,
            "wake_count" => call.wake_count,
            "sleeping_until" => DateTime.to_iso8601(call.sleeping_until)
          }
        }
      })
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
    end
  end

  # One attention event per run per hour bucket: the idempotent source id makes
  # concurrent escalations collapse into the first stored event, and the owner
  # reads current detail through `show_workflow` instead of the payload.
  defp maybe_append_attention_event(_repo, _run, _call, false, _now), do: :ok

  defp maybe_append_attention_event(repo, run, call, true, now) do
    bucket = Calendar.strftime(now, "%Y%m%d%H")
    source_event_id = "workflow:#{run.id}:attention:#{bucket}"
    reply_route = run.reply_route || %{}

    with binding_name when is_binary(binding_name) <- Map.get(reply_route, "binding_name"),
         {:ok, _event} <-
           SignalsGateway.append_actor_event_in_tx(repo, %{
             agent_uid: run.agent_uid,
             binding_name: binding_name,
             session_id: run.owner_session_id,
             source_event_id: source_event_id,
             signal_channel_id: Map.get(reply_route, "signal_channel_id"),
             provider_thread_id: Map.get(reply_route, "provider_thread_id"),
             source_entry_id: Map.get(reply_route, "source_entry_id"),
             type: "workflow.run.attention",
             available_at: now,
             payload: %{
               "specversion" => "1.0",
               "id" => source_event_id,
               "source" => "control-plane://workflow",
               "subject" => "workflow:#{run.id}",
               "time" => DateTime.to_iso8601(now),
               "type" => "workflow.run.attention",
               "data" => %{
                 "run_id" => run.id,
                 "title" => run.title,
                 "call_seq" => call.call_seq,
                 "attention_note" => call.sleep_note
               }
             }
           }) do
      :ok
    else
      nil -> {:error, :workflow_reply_route_binding_missing}
      {:error, _reason} = error -> error
    end
  end

  defp validate_wake_after(value)
       when is_integer(value) and value >= @min_wake_after_ms and value <= @max_wake_after_ms,
       do: {:ok, value}

  defp validate_wake_after(_value), do: {:error, :invalid_workflow_wake_after}

  defp validate_sleep_note(value) when is_binary(value) do
    note = String.trim(value)

    if note != "" and String.length(note) <= 200,
      do: {:ok, note},
      else: {:error, :invalid_workflow_sleep_note}
  end

  defp validate_sleep_note(_value), do: {:error, :invalid_workflow_sleep_note}

  defp compensate_call_in_tx(repo, call_id, agent_uid, reason, now) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run.id, agent_uid) do
      cond do
        run.status != "running" and call.status == "running" ->
          with {:ok, call} <-
                 update_call(repo, call, %{status: "cancelled", result: nil, error: %{}}),
               :ok <- notify_task_ready(repo, call, now) do
            {:ok, %{accepted: false, call: call, run: run}}
          end

        run.status != "running" or call.status != "running" ->
          {:ok, nil}

        true ->
          failure = failure_from_reason(reason)
          commit_failure(repo, run, call, failure, call.attempts < 3, now)
      end
    else
      nil -> {:ok, nil}
      {:error, :workflow_task_not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp submit_locked(repo, %Run{status: status} = run, call, _outcome, now)
       when status != "running" do
    if call.status == "running" do
      with {:ok, call} <- update_call(repo, call, %{status: "cancelled", result: nil, error: %{}}),
           :ok <- notify_task_ready(repo, call, now) do
        {:ok, %{accepted: false, call: call, run: run}}
      end
    else
      {:ok, %{accepted: false, call: call, run: run}}
    end
  end

  defp submit_locked(_repo, %Run{}, %AgentCall{status: status}, _outcome, _now)
       when status != "running",
       do: {:error, {:workflow_task_not_running, status}}

  defp submit_locked(repo, run, call, outcome, now) do
    if outcome_value(outcome, "ok") == true do
      commit_success(repo, run, call, outcome_value(outcome, "value"), now)
    else
      with {:ok, failure} <- validate_failure(outcome) do
        commit_failure(repo, run, call, failure, failure["retryable"] and call.attempts < 3, now)
      end
    end
  end

  defp commit_success(_repo, _run, _call, nil, _now), do: {:error, :workflow_result_null}

  defp commit_success(repo, run, call, value, now) do
    schema = Map.get(call.arguments, "schema", %{"type" => "string"})

    with {:ok, encoded} <- Torque.encode(value),
         :ok <- ensure_result_value_size(encoded),
         {:ok, value} <- ResultSchema.validate(schema, value),
         envelope = %{"ok" => true, "value" => value},
         {:ok, envelope_encoded} <- Torque.encode(envelope),
         memo_bytes = run.memo_bytes + byte_size(envelope_encoded) do
      if memo_bytes > @memo_budget_bytes do
        fail_memo_budget(repo, run, call, now)
      else
        with {:ok, call} <-
               update_call(repo, call, %{status: "succeeded", result: envelope, error: %{}}),
             {:ok, run} <- update_run_memo_bytes(repo, run, memo_bytes),
             :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id),
             :ok <- notify_task_ready(repo, call, now),
             :ok <- wake_next_capacity_deferred_task(repo, run, now) do
          {:ok, %{accepted: true, call: call, run: run}}
        end
      end
    end
  end

  # A call that has slept returns to `sleeping`, not `queued`: its open wake
  # event owns redelivery, while the completed original dispatch event could
  # never re-dispatch a `queued` row.
  defp commit_failure(repo, run, call, failure, true, available_at) do
    with {:ok, call} <-
           update_call(repo, call, %{
             status: requeue_status(call),
             result: nil,
             error: Map.delete(failure, "retryable")
           }),
         :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id),
         :ok <- notify_task_ready(repo, call, available_at) do
      {:ok, %{accepted: true, call: call, run: run}}
    end
  end

  defp commit_failure(repo, run, call, failure, false, now) do
    released_capacity? = call.status == "running"
    envelope = failure |> Map.delete("retryable") |> Map.put("ok", false)

    with {:ok, envelope_encoded} <- Torque.encode(envelope),
         memo_bytes = run.memo_bytes + byte_size(envelope_encoded) do
      if memo_bytes > @memo_budget_bytes do
        fail_memo_budget(repo, run, call, now)
      else
        with {:ok, call} <-
               update_call(repo, call, %{
                 status: "failed",
                 result: envelope,
                 error: Map.delete(envelope, "ok")
               }),
             {:ok, run} <- update_run_memo_bytes(repo, run, memo_bytes),
             :ok <- RuntimeEvents.notify_workflow_run_ready(repo, run.id),
             :ok <- notify_task_ready(repo, call, now),
             :ok <- maybe_wake_next_capacity_deferred_task(repo, run, now, released_capacity?) do
          {:ok, %{accepted: true, call: call, run: run}}
        end
      end
    end
  end

  defp requeue_status(%AgentCall{sleeping_until: %DateTime{}}), do: "sleeping"
  defp requeue_status(%AgentCall{}), do: "queued"

  defp fail_memo_budget(repo, run, call, now) do
    error = %{
      "code" => "workflow_memo_budget_exceeded",
      "summary" =>
        "Workflow memo data exceeded 6 MiB. Use fewer tasks, return summaries, or split the "
    }

    with {:ok, call} <-
           update_call(repo, call, %{status: "failed", result: nil, error: error}),
         {:ok, terminal} <- conclude_run_in_tx(repo, run, "failed", nil, error, now),
         :ok <- notify_task_ready(repo, call, now) do
      {:ok, terminal |> Map.merge(%{accepted: true, call: call})}
    end
  end

  defp requeue_unstarted_locked(repo, run, call, expected_attempt, available_at) do
    cond do
      run.status != "running" and call.status == "running" ->
        with {:ok, call} <-
               update_call(repo, call, %{status: "cancelled", result: nil, error: %{}}),
             :ok <- notify_task_ready(repo, call, available_at) do
          {:ok, %{call: call, run: run}}
        end

      run.status != "running" ->
        {:ok, %{call: call, run: run}}

      call.status == "running" and call.attempts == expected_attempt ->
        with {:ok, call} <-
               update_call(repo, call, %{
                 status: requeue_status(call),
                 attempts: expected_attempt - 1,
                 result: nil,
                 error: %{}
               }),
             :ok <- notify_task_ready(repo, call, available_at) do
          {:ok, %{call: call, run: run}}
        end

      call.status in ["queued", "sleeping"] and call.attempts == expected_attempt - 1 ->
        with :ok <- notify_task_ready(repo, call, available_at) do
          {:ok, %{call: call, run: run}}
        end

      true ->
        {:error, :workflow_task_attempt_changed}
    end
  end

  defp notify_task_ready(repo, call, available_at) do
    RuntimeEvents.notify_actor_session_ready(
      repo,
      call.agent_uid,
      task_session_id(call.id),
      available_at
    )
  end

  defp maybe_wake_next_capacity_deferred_task(_repo, _run, _now, false), do: :ok

  defp maybe_wake_next_capacity_deferred_task(repo, run, now, true) do
    wake_next_capacity_deferred_task(repo, run, now)
  end

  defp wake_next_capacity_deferred_task(repo, run, now) do
    candidate =
      AgentCall
      |> join(:inner, [call], event in ActorEvent,
        on:
          event.agent_uid == call.agent_uid and
            fragment(
              "? = concat('workflow:call:', ?::text, ':dispatch')",
              event.source_event_id,
              call.id
            )
      )
      |> where(
        [call, event],
        call.run_id == ^run.id and call.status == "queued" and
          event.type == "workflow.task.dispatch" and event.input_state == "open" and
          is_nil(event.completed_at) and event.available_at > ^now and
          fragment(
            "?->'data'->>? = ?",
            event.payload,
            ^@defer_reason_key,
            ^@capacity_defer_reason
          )
      )
      |> order_by([call, event], asc: call.call_seq, asc: event.queue_sequence)
      |> select([_call, event], %{
        agent_uid: event.agent_uid,
        session_id: event.session_id,
        event_id: event.id
      })
      |> limit(1)
      |> repo.one()

    case candidate do
      %{agent_uid: agent_uid, session_id: session_id, event_id: event_id} ->
        :ok = Actors.lock_actor_session_in_tx(repo, agent_uid, session_id)

        case Actors.lock_actor_event_in_tx(repo, event_id) do
          %ActorEvent{} = event -> wake_capacity_deferred_event(repo, event, now)
          nil -> :ok
        end

      nil ->
        :ok
    end
  end

  defp wake_capacity_deferred_event(
         repo,
         %ActorEvent{
           type: "workflow.task.dispatch",
           input_state: "open",
           completed_at: nil,
           available_at: available_at,
           payload: payload
         } = event,
         now
       ) do
    deferred_reason = get_in(payload, ["data", @defer_reason_key])

    if deferred_reason == @capacity_defer_reason and DateTime.after?(available_at, now) do
      with {:ok, event} <-
             event
             |> ActorEvent.changeset(%{
               available_at: now,
               payload: clear_dispatch_defer_reason(payload)
             })
             |> repo.update(),
           :ok <-
             RuntimeEvents.notify_actor_session_ready(
               repo,
               event.agent_uid,
               event.session_id,
               now
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp wake_capacity_deferred_event(_repo, %ActorEvent{}, _now), do: :ok

  defp clear_dispatch_defer_reason(%{"data" => data} = payload) when is_map(data) do
    %{payload | "data" => Map.delete(data, @defer_reason_key)}
  end

  defp clear_dispatch_defer_reason(payload), do: payload

  defp put_dispatch_defer_reason(%{"data" => data} = payload, reason) when is_map(data) do
    %{payload | "data" => Map.put(data, @defer_reason_key, Atom.to_string(reason))}
  end

  defp put_dispatch_defer_reason(payload, _reason), do: payload

  defp clear_task_event_defer_in_tx(repo, %ActorEvent{} = actor_event) do
    :ok =
      Actors.lock_actor_session_in_tx(
        repo,
        actor_event.agent_uid,
        actor_event.session_id
      )

    case Actors.lock_actor_event_in_tx(repo, actor_event.id) do
      %ActorEvent{input_state: "open", completed_at: nil} = event ->
        payload = clear_dispatch_defer_reason(event.payload)

        if payload == event.payload do
          :ok
        else
          case event |> ActorEvent.changeset(%{payload: payload}) |> repo.update() do
            {:ok, _event} -> :ok
            {:error, _changeset} = error -> error
          end
        end

      %ActorEvent{} ->
        {:error, :workflow_task_event_not_open}

      nil ->
        {:error, :workflow_task_event_not_found}
    end
  end

  defp validate_agent_arguments(arguments) do
    with prompt when is_binary(prompt) <- Map.get(arguments, "prompt"),
         true <- String.trim(prompt) != "" || {:error, :workflow_agent_prompt_required},
         :ok <- ResultSchema.validate_schema(Map.get(arguments, "schema", %{"type" => "string"})) do
      :ok
    else
      nil -> {:error, :workflow_agent_prompt_required}
      false -> {:error, :workflow_agent_prompt_required}
      {:error, _reason} = error -> error
      _value -> {:error, :workflow_agent_prompt_required}
    end
  end

  defp call_attrs(run, call_seq, arguments) do
    %{
      run_id: run.id,
      agent_uid: run.agent_uid,
      call_seq: call_seq,
      arguments: arguments,
      label: optional_text(arguments, "label"),
      model_profile: optional_text(arguments, "model_profile"),
      status: "queued",
      attempts: 0,
      error: %{}
    }
  end

  defp ensure_claimable(%Run{status: "running"}, %AgentCall{status: status})
       when status in ["queued", "sleeping"],
       do: :ok

  defp ensure_claimable(%Run{status: status}, _call) when status != "running",
    do: {:error, {:workflow_run_terminal, status}}

  defp ensure_claimable(_run, %AgentCall{status: status}),
    do: {:error, {:workflow_task_not_queued, status}}

  defp ensure_delegated_job_owner_running(
         %Run{status: "running"},
         %AgentCall{status: "running"}
       ),
       do: :ok

  defp ensure_delegated_job_owner_running(%Run{status: status}, _call)
       when status != "running",
       do: {:error, {:workflow_run_terminal, status}}

  defp ensure_delegated_job_owner_running(_run, %AgentCall{status: status}),
    do: {:error, {:workflow_task_not_running, status}}

  defp enforce_capacity(repo, run, max_running_per_agent) do
    run_running =
      repo.aggregate(
        from(call in AgentCall,
          where: call.run_id == ^run.id and call.status == "running"
        ),
        :count
      )

    agent_running =
      repo.aggregate(
        from(call in AgentCall,
          where: call.agent_uid == ^run.agent_uid and call.status == "running"
        ),
        :count
      )

    if run_running < run.concurrency and agent_running < max_running_per_agent,
      do: :ok,
      else: {:error, :workflow_agent_at_capacity}
  end

  defp authorize_session(call, session_id) do
    if session_id == task_session_id(call.id),
      do: :ok,
      else: {:error, :workflow_task_session_mismatch}
  end

  defp lock_agent_slots(repo, agent_uid) do
    key = "workflow:running_slots:#{agent_uid}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_run_id(repo, call_id, agent_uid) do
    AgentCall
    |> where([call], call.id == ^call_id and call.agent_uid == ^agent_uid)
    |> select([call], call.run_id)
    |> repo.one()
    |> case do
      run_id when is_integer(run_id) -> {:ok, run_id}
      nil -> {:error, :workflow_task_not_found}
    end
  end

  defp lock_run(repo, run_id) do
    Run |> where([run], run.id == ^run_id) |> lock("FOR UPDATE") |> repo.one()
  end

  defp lock_run(repo, run_id, agent_uid) do
    Run
    |> where([run], run.id == ^run_id and run.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_call(repo, call_id, run_id, agent_uid) do
    AgentCall
    |> where(
      [call],
      call.id == ^call_id and call.run_id == ^run_id and call.agent_uid == ^agent_uid
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_run_calls(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp lock_run_calls_by_sequence(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.call_seq)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp update_call(repo, call, attrs), do: call |> AgentCall.changeset(attrs) |> repo.update()

  defp update_run_memo_bytes(_repo, %Run{memo_bytes: memo_bytes} = run, memo_bytes),
    do: {:ok, run}

  defp update_run_memo_bytes(repo, run, memo_bytes) do
    run
    |> Run.changeset(%{memo_bytes: memo_bytes})
    |> repo.update()
  end

  defp ensure_result_value_size(encoded) when byte_size(encoded) <= @value_max_bytes, do: :ok
  defp ensure_result_value_size(_encoded), do: {:error, :workflow_result_too_large}

  defp validate_failure(outcome) do
    code = optional_text(outcome, "code")
    summary = optional_text(outcome, "summary")

    cond do
      is_nil(code) ->
        {:error, :workflow_failure_code_required}

      byte_size(code) > 128 ->
        {:error, :workflow_failure_code_too_large}

      is_nil(summary) ->
        {:error, :workflow_failure_summary_required}

      byte_size(summary) > 2_000 ->
        {:error, :workflow_failure_summary_too_large}

      true ->
        {:ok,
         %{
           "code" => code,
           "summary" => summary,
           "retryable" => outcome_value(outcome, "retryable") == true
         }}
    end
  end

  defp failure_from_reason(reason) do
    code = optional_text(reason, "code") || "workflow_task_turn_failed"

    summary =
      optional_text(reason, "message") || optional_text(reason, "summary") ||
        "The Workflow task Turn failed before it submitted a result."

    %{
      "code" => Text.utf8_prefix(code, 128),
      "summary" => Text.utf8_prefix(summary, 2_000),
      "retryable" => true
    }
  end

  defp outcome_value(map, key) when is_map(map), do: Map.get(map, key)

  defp optional_text(map, key) do
    case outcome_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp now, do: DateTime.utc_now()
end
