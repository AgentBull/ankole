defmodule Ankole.BackgroundAgentJobs.Turns do
  @moduledoc false

  import Ecto.Query

  alias Ankole.AIGateway.OpaqueContent
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.Text
  alias Ankole.BackgroundAgentJobs.Trajectory
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.BackgroundAgentJobs.TurnWatchdog

  @worker_fields ~w(
    attempt
    runtime_thread_id
    runtime_turn_id
    kind
    status
    revision
    trajectory
    turn_items
    progress
    usage
    error
    started_at
    completed_at
  )
  @checkpoint_fields ~w(
    job_id
    attempt
    runtime_thread_id
    runtime_turn_id
    kind
    status
    revision
    trajectory
    progress
    usage
    error
    started_at
    completed_at
  )a
  @active_statuses ~w(in_progress)
  @terminal_turn_statuses ~w(completed failed interrupted)
  @message_ready_statuses ~w(waiting_on_user succeeded failed stopped)
  @trajectory_default_limit 3
  @trajectory_max_limit 20
  @trajectory_item_window_factor 4
  @trajectory_page_bytes 24 * 1_024
  @trajectory_page_reserve_bytes 512
  @model_string_bytes 4_000
  @attempt_summary_bytes 2_000
  @truncation_suffix "...[truncated]"
  @internal_uuid_pattern ~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i
  @cursor_version 1

  @doc false
  @spec upsert_from_worker_in_tx(module(), Job.t(), map()) ::
          {:ok, Turn.t()} | {:error, term()}
  def upsert_from_worker_in_tx(repo, %Job{} = job, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_worker_attrs(attrs, job),
         {turn_items, attrs} <- Map.pop(attrs, "turn_items", []),
         :ok <- validate_attempt(job, attrs),
         {:ok, turn} <- upsert_in_tx(repo, job, attrs, turn_items),
         :ok <- TurnWatchdog.notify_deadline_in_tx(repo, job.id) do
      {:ok, turn}
    end
  end

  @spec list_for_job(pos_integer(), keyword()) :: [Turn.t()]
  def list_for_job(job_id, opts \\ []) when is_integer(job_id) and job_id > 0 do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(200)

    Turn
    |> where([turn], turn.job_id == ^job_id)
    |> order_by([turn], desc: turn.started_at, desc: turn.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @replay_page_limit 200

  @doc """
  Pages the lead-thread turn items of one Job's workspace lineage in
  chronological order.

  The Worker replays these items into a replacement Codex thread when the
  Worker-local native thread state is gone. Child-agent threads stay out of
  the page: their context never survives their own turns.
  """
  @spec replay_items_page(Job.t(), String.t() | nil) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def replay_items_page(%Job{} = job, cursor) do
    with {:ok, cursor} <- decode_replay_cursor(cursor) do
      turns = lineage_lead_turns(job)
      turn_ids = Enum.map(turns, & &1.id)

      case cursor_turn_index(turn_ids, cursor) do
        :error ->
          {:error, :invalid_background_agent_job_replay_cursor}

        {:ok, start_index, after_position} ->
          {items, next_cursor} =
            collect_replay_items(
              Enum.drop(turns, start_index),
              after_position,
              @replay_page_limit
            )

          {:ok, %{items: items, next_cursor: next_cursor}}
      end
    end
  end

  defp lineage_lead_turns(%Job{} = job) do
    lineage_job_ids =
      Job
      |> where([row], row.workspace_owner_job_id == ^job.workspace_owner_job_id)
      |> where([row], row.agent_uid == ^job.agent_uid)
      |> select([row], row.id)
      |> Repo.all()

    Turn
    |> where([turn], turn.job_id in ^lineage_job_ids)
    |> order_by([turn], asc: turn.started_at, asc: turn.id)
    |> Repo.all()
    |> Enum.group_by(&{&1.job_id, &1.attempt})
    |> Enum.flat_map(fn {_key, attempt_turns} ->
      ordered = Enum.sort_by(attempt_turns, &turn_start_key/1)
      lead_thread_id = inferred_attempt_lead_thread_id(ordered)
      Enum.filter(ordered, &lead_turn?(&1, lead_thread_id))
    end)
    |> Enum.sort_by(&turn_start_key/1)
  end

  defp cursor_turn_index(_turn_ids, nil), do: {:ok, 0, nil}

  defp cursor_turn_index(turn_ids, %{turn_id: turn_id, position: position}) do
    case Enum.find_index(turn_ids, &(&1 == turn_id)) do
      nil -> :error
      index -> {:ok, index, position}
    end
  end

  defp collect_replay_items(turns, after_position, limit) do
    turns
    |> Enum.with_index()
    |> Enum.reduce_while({[], nil}, fn {turn, index}, {collected, _next} ->
      remaining = limit - length(collected)

      rows =
        TurnItem
        |> where([row], row.turn_id == ^turn.id)
        |> then(fn query ->
          if index == 0 and is_integer(after_position),
            do: where(query, [row], row.position > ^after_position),
            else: query
        end)
        |> order_by([row], asc: row.position)
        |> limit(^(remaining + 1))
        |> Repo.all()

      page_rows = Enum.take(rows, remaining)

      collected =
        collected ++
          Enum.map(page_rows, fn row ->
            %{
              runtime_thread_id: turn.runtime_thread_id,
              runtime_turn_id: turn.runtime_turn_id,
              position: row.position,
              item_key: row.item_key,
              item: OpaqueContent.reveal(row.item)
            }
          end)

      cond do
        length(rows) > remaining ->
          last = List.last(page_rows)
          {:halt, {collected, encode_replay_cursor(turn.id, last.position)}}

        length(collected) == limit ->
          # The page is exactly full; a later Turn may still hold items. Point
          # the cursor at the last delivered item so the next page proves it.
          last = List.last(page_rows)
          {:halt, {collected, encode_replay_cursor(turn.id, last.position)}}

        true ->
          {:cont, {collected, nil}}
      end
    end)
  end

  defp encode_replay_cursor(turn_id, position) do
    %{"v" => @cursor_version, "turn_id" => turn_id, "position" => position}
    |> Ankole.JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_replay_cursor(nil), do: {:ok, nil}
  defp decode_replay_cursor(""), do: {:ok, nil}

  defp decode_replay_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"v" => @cursor_version, "turn_id" => turn_id, "position" => position}} <-
           Ankole.JSON.decode(decoded),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         true <- is_integer(position) and position >= 0 do
      {:ok, %{turn_id: turn_id, position: position}}
    else
      _reason -> {:error, :invalid_background_agent_job_replay_cursor}
    end
  end

  defp decode_replay_cursor(_cursor),
    do: {:error, :invalid_background_agent_job_replay_cursor}

  @spec execution_projection(Job.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execution_projection(%Job{} = job, opts \\ []) do
    with {:ok, limit} <- trajectory_limit(Keyword.get(opts, :trajectory_limit)),
         {:ok, cursor} <-
           decode_trajectory_cursor(Keyword.get(opts, :trajectory_cursor), job.attempts) do
      turns = current_attempt_turns(job)

      with {:ok, trajectory_page} <-
             trajectory_page(turns, job, cursor, limit) do
        current = current_turn(turns, job.runtime_thread_id)

        execution = %{
          attempt: job.attempts,
          lead_turn_number: lead_turn_count(turns, job.runtime_thread_id),
          threads: thread_counts(turns, job.runtime_thread_id),
          turns: turn_counts(turns, job.runtime_thread_id),
          progress: aggregate_progress(turns, job),
          trajectory_page: trajectory_page,
          updated_at: execution_updated_at(turns, job)
        }

        {:ok,
         execution
         |> Ankole.Attrs.maybe_put(:current, current_projection(current))
         |> Ankole.Attrs.maybe_put(:usage, latest_lead_usage(turns, job.runtime_thread_id))}
      end
    end
  end

  @doc false
  @spec message_result(Job.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def message_result(%Job{} = job, command_event_id, caller_session_id)
      when is_binary(command_event_id) and is_binary(caller_session_id) do
    case command_event(job, command_event_id) do
      %ActorEvent{} = command_event ->
        case causal_message_turn(job, command_event_id) do
          %Turn{status: status} = turn when status in @terminal_turn_statuses ->
            ready_message_result(job, turn, caller_session_id)

          %Turn{} ->
            {:ok, pending_message_result(job)}

          nil ->
            message_without_trajectory(job, command_event)
        end

      nil ->
        {:error, :background_agent_job_message_command_not_found}
    end
  end

  defp ready_message_result(job, turn, caller_session_id) do
    newer_lead_turn = newer_lead_turn?(job, turn)

    cond do
      newer_lead_turn ->
        {:ok, completed_message_result(job, turn, nil)}

      job.status in @message_ready_statuses ->
        lifecycle_event = lifecycle_event_for_message(job, turn, caller_session_id)
        {:ok, completed_message_result(job, turn, lifecycle_event)}

      true ->
        {:ok, pending_message_result(job)}
    end
  end

  defp causal_message_turn(%Job{} = job, command_event_id) do
    item_key = "client:#{command_event_id}"

    TurnItem
    |> join(:inner, [row], turn in Turn, on: turn.id == row.turn_id)
    |> where([row, turn], row.item_key == ^item_key and turn.job_id == ^job.id)
    |> order_by([row, turn], asc: turn.started_at, asc: turn.id, asc: row.position)
    |> select([_row, turn], turn)
    |> limit(1)
    |> Repo.one()
  end

  defp newer_lead_turn?(%Job{} = job, %Turn{} = causal_turn) do
    lead_thread_ids =
      [causal_turn.runtime_thread_id, job.runtime_thread_id]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Turn
    |> where([turn], turn.job_id == ^job.id)
    |> where([turn], turn.runtime_thread_id in ^lead_thread_ids)
    |> where(
      [turn],
      turn.started_at > ^causal_turn.started_at or
        (turn.started_at == ^causal_turn.started_at and turn.id > ^causal_turn.id)
    )
    |> Repo.exists?()
  end

  defp completed_message_result(job, turn, lifecycle_event) do
    {trajectory, earlier_omitted} = message_turn_trajectory(turn)

    %{
      job_id: job.id,
      status: job.status,
      ready: true,
      last_turn_trajectory: trajectory,
      earlier_trajectory_omitted: earlier_omitted,
      lifecycle_actor_event_id: if(lifecycle_event, do: lifecycle_event.id)
    }
  end

  defp pending_message_result(job) do
    %{
      job_id: job.id,
      status: job.status,
      ready: false,
      last_turn_trajectory: nil,
      earlier_trajectory_omitted: false,
      lifecycle_actor_event_id: nil
    }
  end

  defp message_without_trajectory(job, command_event) do
    case command_event do
      %ActorEvent{input_state: "dead_letter"} ->
        {:error, :background_agent_job_message_delivery_failed}

      %ActorEvent{completed_at: %DateTime{}} ->
        {:error, :background_agent_job_message_delivery_failed}

      %ActorEvent{} when job.status in ~w(succeeded failed stopped) ->
        {:error, :background_agent_job_message_delivery_failed}

      %ActorEvent{} ->
        {:ok, pending_message_result(job)}
    end
  end

  defp command_event(job, command_event_id) do
    case Ecto.UUID.cast(command_event_id) do
      {:ok, event_id} ->
        ActorEvent
        |> where([event], event.id == ^event_id)
        |> where([event], event.agent_uid == ^job.agent_uid)
        |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job.id))
        |> where([event], event.type == "command.steer")
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp message_turn_trajectory(%Turn{} = turn) do
    groups =
      [turn.id]
      |> projection_units_by_turn()
      |> Map.get(turn.id, [])
      |> Enum.map(fn unit ->
        {messages, bound_truncated} =
          unit.messages
          |> OpaqueContent.reveal()
          |> bound_group()

        %{
          turn_id: turn.id,
          position: unit.position,
          messages: messages,
          content_truncated: unit.truncated or bound_truncated
        }
      end)

    selected = select_page_groups(groups, @trajectory_max_limit)
    messages = Enum.flat_map(selected, & &1.messages)
    header = turn.trajectory || empty_trajectory()
    header = mark_content_truncated(header, Enum.any?(selected, & &1.content_truncated))

    {Map.put(header, "messages", messages), length(groups) > length(selected)}
  end

  defp lifecycle_event_for_message(
         %Job{owner_session_id: caller_session_id, attempts: attempt} = job,
         %Turn{attempt: attempt},
         caller_session_id
       ) do
    case lifecycle_event_identity(job) do
      {event_type, source_event_id} ->
        ActorEvent
        |> where([event], event.agent_uid == ^job.agent_uid)
        |> where([event], event.session_id == ^caller_session_id)
        |> where([event], event.type == ^event_type)
        |> where([event], event.source_event_id == ^source_event_id)
        |> where([event], event.input_state == "open" and is_nil(event.completed_at))
        |> Repo.one()

      nil ->
        nil
    end
  end

  defp lifecycle_event_for_message(%Job{}, %Turn{}, _caller_session_id), do: nil

  defp lifecycle_event_identity(%Job{status: "waiting_on_user"} = job),
    do: {"background_agent_job.waiting", "background_agent_job:#{job.id}:waiting:#{job.attempts}"}

  defp lifecycle_event_identity(%Job{status: "succeeded"} = job),
    do:
      {"background_agent_job.completed",
       "background_agent_job:#{job.id}:succeeded:#{job.attempts}"}

  defp lifecycle_event_identity(%Job{status: "failed"} = job),
    do: {"background_agent_job.failed", "background_agent_job:#{job.id}:failed:#{job.attempts}"}

  defp lifecycle_event_identity(%Job{}), do: nil

  @doc false
  @spec ensure_lead_closed_for_current_attempt_in_tx(module(), Job.t(), keyword()) ::
          :ok | {:error, :background_agent_job_turn_trajectory_incomplete}
  def ensure_lead_closed_for_current_attempt_in_tx(repo, %Job{} = job, opts \\ []) do
    turns =
      Turn
      |> where([row], row.job_id == ^job.id)
      |> where([row], row.attempt == ^job.attempts)
      |> order_by([row], asc: row.started_at, asc: row.id)
      |> lock("FOR UPDATE")
      |> repo.all()

    lead_turns = Enum.filter(turns, &lead_turn?(&1, job.runtime_thread_id))
    lead_statuses = Enum.map(lead_turns, & &1.status)
    latest_lead = List.last(lead_turns)
    expected_status = Keyword.get(opts, :latest_status)
    expected_error_code = Keyword.get(opts, :latest_error_code)
    required_pending_tool = Keyword.get(opts, :require_pending_tool_call)

    cond do
      Keyword.get(opts, :require_turn, false) and is_nil(latest_lead) ->
        {:error, :background_agent_job_turn_trajectory_incomplete}

      Enum.any?(lead_statuses, &(&1 in @active_statuses)) ->
        {:error, :background_agent_job_turn_trajectory_incomplete}

      is_binary(expected_status) and
          (is_nil(latest_lead) or latest_lead.status != expected_status) ->
        {:error, :background_agent_job_turn_trajectory_incomplete}

      is_binary(expected_error_code) and
          (is_nil(latest_lead) or
             get_in(latest_lead.error || %{}, ["code"]) != expected_error_code) ->
        {:error, :background_agent_job_turn_trajectory_incomplete}

      is_binary(required_pending_tool) and
          not trajectory_has_pending_tool_call?(latest_lead, required_pending_tool) ->
        {:error, :background_agent_job_turn_trajectory_incomplete}

      true ->
        :ok
    end
  end

  @doc false
  @spec consecutive_lead_failures_in_tx(module(), Job.t(), pos_integer()) ::
          {non_neg_integer(), map() | nil}
  def consecutive_lead_failures_in_tx(
        repo,
        %Job{runtime_thread_id: lead_thread_id} = job,
        limit
      )
      when is_binary(lead_thread_id) and is_integer(limit) and limit > 0 do
    failures =
      Turn
      |> where([turn], turn.job_id == ^job.id)
      |> where([turn], turn.runtime_thread_id == ^lead_thread_id)
      |> order_by([turn], desc: turn.started_at, desc: turn.id)
      |> limit(^limit)
      |> repo.all()
      |> Enum.take_while(&(&1.status == "failed"))

    case failures do
      [] -> {0, nil}
      [latest | _rest] -> {length(failures), latest.error}
    end
  end

  def consecutive_lead_failures_in_tx(_repo, %Job{}, _limit), do: {0, nil}

  @doc false
  @spec interrupt_before_attempt_in_tx(module(), Job.t(), pos_integer(), DateTime.t()) ::
          :ok
  def interrupt_before_attempt_in_tx(
        repo,
        %Job{} = job,
        expected_attempt,
        %DateTime{} = now
      ) do
    Turn
    |> where([turn], turn.job_id == ^job.id)
    |> where([turn], turn.attempt < ^expected_attempt)
    |> interrupt_active_query(repo, now, %{
      "code" => "worker_attempt_replaced",
      "summary" => "The worker attempt ended before this runtime turn completed."
    })

    :ok
  end

  @doc false
  @spec interrupt_active_for_current_attempt_in_tx(
          module(),
          Job.t(),
          map(),
          DateTime.t()
        ) :: :ok
  def interrupt_active_for_current_attempt_in_tx(
        repo,
        %Job{} = job,
        %{} = error,
        %DateTime{} = now
      ) do
    Turn
    |> where([turn], turn.job_id == ^job.id)
    |> where([turn], turn.attempt == ^job.attempts)
    |> interrupt_active_query(repo, now, error)

    :ok
  end

  defp interrupt_active_query(query, repo, now, error) do
    query
    |> where([turn], turn.status in @active_statuses)
    |> update([turn],
      set: [
        status: "interrupted",
        error: ^error,
        completed_at: ^now,
        progress: fragment("? - 'active_item'", turn.progress),
        updated_at: ^now
      ],
      inc: [revision: 1]
    )
    |> repo.update_all([])
  end

  @spec attempt_history(Job.t()) :: [map()]
  def attempt_history(%Job{attempts: attempts}) when attempts <= 1, do: []

  def attempt_history(%Job{} = job) do
    first_attempt = max(job.attempts - 3, 1)

    Turn
    |> where([turn], turn.job_id == ^job.id)
    |> where([turn], turn.attempt >= ^first_attempt)
    |> where([turn], turn.attempt < ^job.attempts)
    |> order_by([turn], desc: turn.started_at, desc: turn.id)
    |> Repo.all()
    |> Enum.group_by(& &1.attempt)
    |> Enum.map(fn {attempt, turns} ->
      ordered = Enum.sort_by(turns, &turn_start_key/1)
      lead_thread_id = inferred_attempt_lead_thread_id(ordered)
      lead = Enum.filter(ordered, &lead_turn?(&1, lead_thread_id))

      %{
        attempt: attempt,
        turn_statuses: ordered |> Enum.map(& &1.status) |> Enum.uniq(),
        summary: attempt_summary(lead) || attempt_summary(ordered),
        used_skill_names:
          case attempt_used_skill_names(ordered) do
            [] -> nil
            names -> names
          end
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
    |> Enum.sort_by(& &1.attempt, :desc)
    |> Enum.take(3)
    |> Enum.reverse()
  end

  @spec console_projections([Turn.t()]) :: [map()]
  def console_projections([]), do: []

  def console_projections(turns) when is_list(turns) do
    messages_by_turn = trajectory_messages_by_turn(Enum.map(turns, & &1.id))

    Enum.map(turns, fn turn ->
      console_projection(turn, Map.get(messages_by_turn, turn.id, []))
    end)
  end

  defp console_projection(%Turn{} = turn, messages) do
    trajectory =
      messages
      |> OpaqueContent.reveal()
      |> then(&Map.put(turn.trajectory || empty_trajectory(), "messages", &1))

    projection(turn, trajectory)
  end

  @spec worker_projection(Turn.t()) :: map()
  def worker_projection(%Turn{} = turn) do
    projection(turn, turn.trajectory || empty_trajectory())
  end

  defp projection(turn, trajectory) do
    %{
      id: turn.id,
      attempt: turn.attempt,
      runtime_thread_id: turn.runtime_thread_id,
      runtime_turn_id: turn.runtime_turn_id,
      kind: turn.kind,
      status: turn.status,
      revision: turn.revision,
      trajectory: trajectory,
      progress: turn.progress || empty_progress(),
      usage: turn.usage,
      error: turn.error || %{},
      started_at: iso8601(turn.started_at),
      completed_at: iso8601(turn.completed_at),
      inserted_at: iso8601(turn.inserted_at),
      updated_at: iso8601(turn.updated_at)
    }
  end

  defp current_attempt_turns(%Job{} = job) do
    Turn
    |> where([turn], turn.job_id == ^job.id)
    |> where([turn], turn.attempt == ^job.attempts)
    |> order_by([turn], asc: turn.started_at, asc: turn.id)
    |> Repo.all()
  end

  defp upsert_in_tx(repo, %Job{} = job, attrs, turn_items) do
    runtime_turn_id = Map.fetch!(attrs, "runtime_turn_id")

    case get_in_tx(repo, job.id, runtime_turn_id, lock: "FOR UPDATE") do
      nil ->
        with {:ok, turn} <- %Turn{} |> Turn.changeset(attrs) |> repo.insert(),
             {:ok, turn} <- append_turn_items(repo, turn, turn_items) do
          {:ok, turn}
        end

      %Turn{} = turn ->
        update_existing(repo, turn, attrs, turn_items)
    end
  end

  defp update_existing(repo, %Turn{} = turn, attrs, turn_items) do
    revision = Map.fetch!(attrs, "revision")

    if revision < turn.revision do
      {:ok, turn}
    else
      next_status = Map.fetch!(attrs, "status")

      with {:ok, candidate} <-
             turn |> Turn.changeset(attrs) |> Ecto.Changeset.apply_action(:update) do
        cond do
          turn.attempt != candidate.attempt ->
            {:error, :background_agent_job_turn_attempt_mismatch}

          turn.runtime_thread_id != candidate.runtime_thread_id ->
            {:error, :background_agent_job_turn_runtime_thread_mismatch}

          revision == turn.revision and checkpoint_equal?(turn, candidate) ->
            with :ok <- checkpoint_items_equal?(repo, turn, revision, turn_items),
                 do: {:ok, turn}

          revision == turn.revision ->
            {:error, :background_agent_job_turn_revision_conflict}

          not Turn.transition_allowed?(turn.status, next_status) ->
            {:error, :background_agent_job_turn_status_transition_invalid}

          true ->
            with {:ok, updated} <- turn |> Turn.changeset(attrs) |> repo.update(),
                 {:ok, updated} <- append_turn_items(repo, updated, turn_items) do
              {:ok, updated}
            end
        end
      end
    end
  end

  defp get_in_tx(repo, job_id, runtime_turn_id, opts) do
    Turn
    |> where(
      [turn],
      turn.job_id == ^job_id and turn.runtime_turn_id == ^runtime_turn_id
    )
    |> maybe_lock(Keyword.get(opts, :lock))
    |> repo.one()
  end

  defp checkpoint_equal?(left, right) do
    Map.take(Map.from_struct(left), @checkpoint_fields) ==
      Map.take(Map.from_struct(right), @checkpoint_fields)
  end

  defp normalize_worker_attrs(attrs, job) do
    attrs =
      attrs
      |> Attrs.normalize()
      |> Map.take(@worker_fields)
      |> Map.put("job_id", job.id)
      |> Map.put_new("kind", "agent")
      |> Map.put_new("trajectory", Trajectory.empty_header())
      |> Map.put_new("progress", empty_progress())
      |> Map.put_new("error", %{})

    reject_trajectory_messages(attrs)
  end

  defp reject_trajectory_messages(%{"trajectory" => %{"messages" => messages}})
       when is_list(messages) and messages != [],
       do: {:error, :background_agent_job_trajectory_messages_unsupported}

  defp reject_trajectory_messages(attrs), do: {:ok, attrs}

  defp validate_attempt(%Job{attempts: attempts}, %{"attempt" => attempts}), do: :ok
  defp validate_attempt(%Job{}, _attrs), do: {:error, :background_agent_job_turn_attempt_mismatch}

  defp append_turn_items(_repo, %Turn{} = turn, []), do: {:ok, turn}

  defp append_turn_items(repo, %Turn{} = turn, items) when is_list(items) do
    with {:ok, truncated} <- insert_turn_items(repo, turn, items) do
      if truncated, do: mark_turn_content_truncated(repo, turn), else: {:ok, turn}
    end
  end

  defp append_turn_items(_repo, _turn, _items),
    do: {:error, :invalid_background_agent_job_turn_items}

  defp insert_turn_items(repo, %Turn{} = turn, items) do
    Enum.reduce_while(items, {:ok, false}, fn entry, {:ok, truncated} ->
      with {:ok, candidate, changeset} <- turn_item_candidate(turn, entry) do
        existing =
          TurnItem
          |> where([row], row.turn_id == ^turn.id)
          |> where(
            [row],
            row.position == ^candidate.position or row.item_key == ^candidate.item_key
          )
          |> lock("FOR UPDATE")
          |> repo.all()

        cond do
          existing == [] ->
            case repo.insert(changeset) do
              {:ok, _item} ->
                {_messages, projection_truncated} = TurnItemProjection.project(candidate.item)
                {:cont, {:ok, truncated or projection_truncated}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          Enum.any?(existing, &turn_item_equal?(&1, candidate)) and length(existing) == 1 ->
            {:cont, {:ok, truncated}}

          true ->
            {:halt, {:error, :background_agent_job_turn_item_conflict}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp turn_item_candidate(%Turn{} = turn, %{} = entry) do
    attrs = Attrs.normalize(entry)

    changeset =
      TurnItem.changeset(%TurnItem{}, %{
        turn_id: turn.id,
        position: attrs["position"],
        revision: turn.revision,
        item_key: attrs["item_key"],
        item: attrs["item"]
      })

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, candidate} -> {:ok, candidate, changeset}
      {:error, invalid} -> {:error, invalid}
    end
  end

  defp turn_item_candidate(_turn, _entry),
    do: {:error, :invalid_background_agent_job_turn_items}

  defp turn_item_equal?(stored, candidate) do
    stored.position == candidate.position and stored.item_key == candidate.item_key and
      stored.item == candidate.item
  end

  defp checkpoint_items_equal?(repo, turn, revision, items) do
    stored =
      TurnItem
      |> where([row], row.turn_id == ^turn.id)
      |> order_by([row], asc: row.position)
      |> repo.all()

    current = Enum.filter(stored, &(&1.revision == revision))

    candidates =
      Enum.map(items, fn entry ->
        attrs = Attrs.normalize(entry)

        %{
          position: attrs["position"],
          item_key: attrs["item_key"],
          item: attrs["item"]
        }
      end)

    if turn_item_lists_equal?(current, candidates) or
         turn_item_lists_equal?(stored, candidates),
       do: :ok,
       else: {:error, :background_agent_job_turn_revision_conflict}
  end

  defp turn_item_lists_equal?(stored, candidates) do
    length(stored) == length(candidates) and
      Enum.zip(stored, candidates)
      |> Enum.all?(fn {row, value} -> turn_item_equal?(row, value) end)
  end

  defp mark_turn_content_truncated(repo, %Turn{} = turn) do
    header = turn.trajectory || empty_trajectory()
    metadata = if is_map(header["metadata"]), do: header["metadata"], else: %{}

    if metadata["content_truncated"] == true do
      {:ok, turn}
    else
      header = Map.put(header, "metadata", Map.put(metadata, "content_truncated", true))

      turn
      |> Ecto.Changeset.change(trajectory: header)
      |> repo.update()
    end
  end

  defp lead_turn?(%Turn{} = turn, lead_thread_id),
    do: is_binary(lead_thread_id) and turn.runtime_thread_id == lead_thread_id

  defp inferred_attempt_lead_thread_id(turns) do
    turn = List.first(turns)
    if turn, do: turn.runtime_thread_id
  end

  defp lead_turn_count(turns, lead_thread_id) do
    Enum.count(turns, &lead_turn?(&1, lead_thread_id))
  end

  defp thread_counts(turns, lead_thread_id) do
    thread_ids = turns |> Enum.map(& &1.runtime_thread_id) |> Enum.uniq()

    %{
      total: length(thread_ids),
      child: Enum.count(thread_ids, &(&1 != lead_thread_id))
    }
  end

  defp turn_counts(turns, lead_thread_id) do
    %{
      lead: Enum.count(turns, &lead_turn?(&1, lead_thread_id)),
      child: Enum.count(turns, &(not lead_turn?(&1, lead_thread_id))),
      compaction: Enum.count(turns, &(&1.kind == "compaction")),
      active: Enum.count(turns, &(&1.status in @active_statuses))
    }
  end

  defp current_turn(turns, lead_thread_id) do
    turns
    |> Enum.filter(&lead_turn?(&1, lead_thread_id))
    |> List.last()
    |> case do
      nil -> List.last(turns)
      turn -> turn
    end
  end

  defp current_projection(nil), do: nil

  defp current_projection(%Turn{} = turn) do
    %{
      runtime_turn_id: turn.runtime_turn_id,
      kind: turn.kind,
      status: turn.status
    }
  end

  defp aggregate_progress(turns, %Job{} = job) do
    totals =
      Enum.reduce(
        turns,
        %{
          completed_items: 0,
          tool_calls: 0,
          tools: %{},
          tool_execution_mechanisms: %{},
          files: MapSet.new(),
          skills: MapSet.new()
        },
        fn
          %Turn{progress: progress}, acc when is_map(progress) ->
            %{
              completed_items: acc.completed_items + nonnegative(progress["completed_items"]),
              tool_calls: acc.tool_calls + nonnegative(progress["tool_calls"]),
              tools: merge_tool_usage(acc.tools, progress["tools_used"]),
              tool_execution_mechanisms:
                merge_tool_execution_mechanisms(
                  acc.tool_execution_mechanisms,
                  progress["tool_execution_mechanisms"]
                ),
              files: merge_files(acc.files, progress["files_changed"]),
              skills: merge_files(acc.skills, progress["skills_used"])
            }

          _turn, acc ->
            acc
        end
      )

    progress =
      %{
        completed_items: totals.completed_items,
        tool_calls: totals.tool_calls,
        tools_used:
          totals.tools
          |> Enum.sort_by(fn {{namespace, name}, _calls} -> {namespace || "", name} end)
          |> Enum.map(fn {{namespace, name}, calls} ->
            %{name: name, calls: calls}
            |> Ankole.Attrs.maybe_put(:namespace, namespace)
          end),
        tool_execution_mechanisms:
          totals.tool_execution_mechanisms
          |> Enum.sort_by(fn {{{namespace, name}, mechanism}, _calls} ->
            {namespace || "", name, mechanism}
          end)
          |> Enum.map(fn {{{namespace, name}, mechanism}, calls} ->
            %{name: name, execution_mechanism: mechanism, calls: calls}
            |> Ankole.Attrs.maybe_put(:namespace, namespace)
          end),
        files_changed: totals.files |> MapSet.to_list() |> Enum.sort(),
        active_items: active_items(turns, job)
      }
      |> then(fn progress ->
        case totals.skills |> MapSet.to_list() |> Enum.sort() do
          [] -> progress
          skills -> Map.put(progress, :skills_used, skills)
        end
      end)

    Ankole.Attrs.maybe_put(progress, :plan, latest_lead_plan(turns, job.runtime_thread_id))
  end

  defp merge_tool_usage(acc, tools) when is_list(tools) do
    Enum.reduce(tools, acc, fn
      %{"name" => name, "calls" => calls} = tool, result
      when is_binary(name) and is_integer(calls) and calls >= 0 ->
        case Map.get(tool, "namespace") do
          namespace when is_nil(namespace) or is_binary(namespace) ->
            Map.update(result, {namespace, name}, calls, &(&1 + calls))

          _invalid_namespace ->
            result
        end

      _tool, result ->
        result
    end)
  end

  defp merge_tool_usage(acc, _tools), do: acc

  defp merge_tool_execution_mechanisms(acc, executions) when is_list(executions) do
    Enum.reduce(executions, acc, fn
      %{"name" => name, "execution_mechanism" => mechanism, "calls" => calls} = execution, result
      when is_binary(name) and mechanism in ~w(local_dynamic provider_hosted) and
             is_integer(calls) and calls > 0 ->
        case Map.get(execution, "namespace") do
          namespace when is_nil(namespace) or is_binary(namespace) ->
            Map.update(result, {{namespace, name}, mechanism}, calls, &(&1 + calls))

          _invalid_namespace ->
            result
        end

      _execution, result ->
        result
    end)
  end

  defp merge_tool_execution_mechanisms(acc, _executions), do: acc

  defp merge_files(acc, files) when is_list(files) do
    Enum.reduce(files, acc, fn
      file, result when is_binary(file) -> MapSet.put(result, file)
      _file, result -> result
    end)
  end

  defp merge_files(acc, _files), do: acc

  defp latest_lead_plan(turns, lead_thread_id) do
    turns
    |> Enum.filter(fn turn ->
      lead_turn?(turn, lead_thread_id) and is_map(turn.progress) and
        is_map(turn.progress["plan"])
    end)
    |> Enum.max_by(&turn_update_key/1, fn -> nil end)
    |> case do
      %Turn{progress: %{"plan" => plan}} -> plan
      _turn -> nil
    end
  end

  defp active_items(_turns, %Job{status: status})
       when status in ~w(succeeded failed stopped),
       do: []

  defp active_items(turns, %Job{} = job) do
    turns
    |> Enum.filter(&(&1.status in @active_statuses))
    |> Enum.sort_by(&turn_update_key/1, :desc)
    |> Enum.flat_map(fn turn ->
      case turn.progress do
        %{"active_item" => %{"name" => name} = active_item} when is_binary(name) ->
          [
            %{
              scope: if(lead_turn?(turn, job.runtime_thread_id), do: "lead", else: "child"),
              name: name
            }
            |> Ankole.Attrs.maybe_put(:namespace, Map.get(active_item, "namespace"))
          ]

        _progress ->
          []
      end
    end)
    |> Enum.take(8)
  end

  defp latest_lead_usage(turns, lead_thread_id) do
    turns
    |> Enum.filter(&(lead_turn?(&1, lead_thread_id) and is_map(&1.usage)))
    |> Enum.max_by(&turn_update_key/1, fn -> nil end)
    |> case do
      %Turn{usage: usage} -> usage
      nil -> nil
    end
  end

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp execution_updated_at([], %Job{updated_at: updated_at}), do: iso8601(updated_at)

  defp execution_updated_at(turns, %Job{}) do
    turns
    |> Enum.max_by(&turn_update_key/1)
    |> Map.fetch!(:updated_at)
    |> iso8601()
  end

  defp turn_update_key(%Turn{} = turn) do
    {datetime_key(turn.updated_at || turn.started_at), turn.id}
  end

  defp turn_start_key(%Turn{} = turn) do
    {datetime_key(turn.started_at), turn.id}
  end

  defp datetime_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_key(_datetime), do: 0

  defp trajectory_limit(nil), do: {:ok, @trajectory_default_limit}

  defp trajectory_limit(limit)
       when is_integer(limit) and limit >= 1 and limit <= @trajectory_max_limit,
       do: {:ok, limit}

  defp trajectory_limit(_limit), do: {:error, :invalid_background_agent_job_trajectory_limit}

  defp trajectory_page(turns, job, cursor, limit) do
    lead_turns =
      turns
      |> Enum.filter(&lead_turn?(&1, job.runtime_thread_id))

    with {:ok, units} <- newest_lead_units_before_cursor(lead_turns, cursor, limit + 1) do
      selected = select_page_groups(units, limit)
      has_more = length(units) > length(selected)

      metadata =
        %{}
        |> maybe_put_true("redacted", Enum.any?(selected, & &1.redacted))
        |> maybe_put_true(
          "content_truncated",
          Enum.any?(selected, & &1.content_truncated)
        )

      page =
        %{
          format: "ankole_chatml",
          version: 1,
          messages: selected |> Enum.flat_map(& &1.messages)
        }
        |> Ankole.Attrs.maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))

      {:ok,
       if has_more and selected != [] do
         Map.put(
           page,
           :next_cursor,
           selected |> hd() |> encode_trajectory_cursor(job.attempts)
         )
       else
         page
       end}
    end
  end

  # Collects the newest `want` page units older than the cursor without
  # loading the whole attempt: TurnItem rows arrive through a windowed query
  # in newest-first (turn order, position) order and project in memory. The
  # item stream is the only readable trajectory form; a Turn recorded before
  # it existed has no item rows and renders empty. The returned list is
  # chronological.
  defp newest_lead_units_before_cursor([], nil, _want), do: {:ok, []}

  defp newest_lead_units_before_cursor([], _cursor, _want),
    do: {:error, :invalid_background_agent_job_trajectory_cursor}

  defp newest_lead_units_before_cursor(lead_turns, cursor, want) do
    turn_ids = Enum.map(lead_turns, & &1.id)
    turn_index = turn_ids |> Enum.with_index() |> Map.new()
    meta_by_turn = Map.new(lead_turns, &{&1.id, page_turn_meta(&1)})

    with :ok <- validate_page_cursor(cursor, turn_index) do
      items = %{
        buffer: [],
        done: turn_ids == [],
        boundary: item_window_boundary(cursor, turn_index, turn_ids),
        turn_ids: turn_ids,
        turn_index: turn_index,
        batch: want * @trajectory_item_window_factor,
        meta: meta_by_turn
      }

      {:ok, take_item_units(items, want, [])}
    end
  end

  # The cursor must hit one exact stored unit; anything else is invalid. An
  # attempt mismatch was already rejected while decoding the cursor.
  defp validate_page_cursor(nil, _turn_index), do: :ok

  defp validate_page_cursor(%{turn_id: turn_id, position: position}, turn_index) do
    if Map.has_key?(turn_index, turn_id) and cursor_item_unit_exists?(turn_id, position),
      do: :ok,
      else: {:error, :invalid_background_agent_job_trajectory_cursor}
  end

  defp cursor_item_unit_exists?(turn_id, position) do
    case Repo.get_by(TurnItem, turn_id: turn_id, position: position) do
      nil -> false
      %TurnItem{item: item} -> match?({[_ | _], _}, TurnItemProjection.project(item))
    end
  end

  defp item_window_boundary(nil, _turn_index, _turn_ids), do: nil

  defp item_window_boundary(%{turn_id: turn_id, position: position}, turn_index, turn_ids) do
    cursor_index = Map.fetch!(turn_index, turn_id)
    older_turn_ids = Enum.filter(turn_ids, &(Map.fetch!(turn_index, &1) < cursor_index))
    {turn_id, position, older_turn_ids}
  end

  defp take_item_units(_items, 0, acc), do: acc

  defp take_item_units(items, want, acc) do
    case peek_item_unit(items) do
      {nil, _items} -> acc
      {unit, items} -> take_item_units(pop_item_unit(items), want - 1, [unit | acc])
    end
  end

  defp peek_item_unit(%{buffer: [unit | _rest]} = items), do: {unit, items}
  defp peek_item_unit(%{done: true} = items), do: {nil, items}

  defp peek_item_unit(items) do
    rows = fetch_item_window(items)

    items = %{
      items
      | done: length(rows) < items.batch,
        boundary: next_item_window_boundary(rows, items),
        buffer: Enum.flat_map(rows, &item_page_unit(&1, items.meta))
    }

    peek_item_unit(items)
  end

  defp pop_item_unit(%{buffer: [_unit | rest]} = items), do: %{items | buffer: rest}

  defp fetch_item_window(%{turn_ids: turn_ids, boundary: boundary, batch: batch}) do
    TurnItem
    |> join(:inner, [row], turn in Turn, on: turn.id == row.turn_id)
    |> where([row], row.turn_id in ^turn_ids)
    |> item_window_below(boundary)
    |> order_by([row, turn], desc: turn.started_at, desc: turn.id, desc: row.position)
    |> limit(^batch)
    |> Repo.all()
  end

  defp item_window_below(query, nil), do: query

  defp item_window_below(query, {turn_id, position, older_turn_ids}) do
    where(
      query,
      [row],
      (row.turn_id == ^turn_id and row.position < ^position) or
        row.turn_id in ^older_turn_ids
    )
  end

  defp next_item_window_boundary([], %{boundary: boundary}), do: boundary

  defp next_item_window_boundary(rows, items) do
    last = List.last(rows)
    last_index = Map.fetch!(items.turn_index, last.turn_id)

    older_turn_ids =
      Enum.filter(items.turn_ids, &(Map.fetch!(items.turn_index, &1) < last_index))

    {last.turn_id, last.position, older_turn_ids}
  end

  defp item_page_unit(%TurnItem{} = row, meta_by_turn) do
    case TurnItemProjection.project(row.item) do
      {[], _truncated} ->
        []

      {messages, projection_truncated} ->
        {bounded, bound_truncated} = bound_group(messages)
        meta = Map.fetch!(meta_by_turn, row.turn_id)

        [
          %{
            turn_id: row.turn_id,
            position: row.position,
            messages: bounded,
            redacted: meta.redacted,
            content_truncated: meta.content_truncated or projection_truncated or bound_truncated
          }
        ]
    end
  end

  defp page_turn_meta(%Turn{} = turn) do
    metadata = get_in(turn.trajectory || %{}, ["metadata"])

    %{
      redacted: is_map(metadata) and metadata["redacted"] == true,
      content_truncated: is_map(metadata) and metadata["content_truncated"] == true
    }
  end

  defp select_page_groups(groups, limit) do
    groups
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn group, {selected, count} ->
      candidate = [group | selected]

      cond do
        count >= limit ->
          {:halt, {selected, count}}

        trajectory_messages_bytes(candidate) >
            @trajectory_page_bytes - @trajectory_page_reserve_bytes ->
          {:halt, {selected, count}}

        true ->
          {:cont, {candidate, count + 1}}
      end
    end)
    |> elem(0)
  end

  defp trajectory_messages_bytes(groups) do
    Ankole.JSON.encode!(%{
      format: "ankole_chatml",
      version: 1,
      messages: Enum.flat_map(groups, & &1.messages)
    })
    |> byte_size()
  end

  defp bound_group(messages) do
    trimmed = trim_group(messages, 16)

    bounded =
      [@model_string_bytes, 2_000, 1_000, 500, 200, 64]
      |> Enum.find_value(fn limit ->
        candidate = Enum.map(trimmed, &bound_value(&1, limit))

        if encoded_bytes(candidate) <= @trajectory_page_bytes - @trajectory_page_reserve_bytes,
          do: candidate
      end)
      |> case do
        nil -> minimal_group(trimmed)
        candidate -> candidate
      end

    {bounded, bounded != messages}
  end

  defp trim_group(
         [%{"role" => "assistant", "tool_calls" => tool_calls} = assistant | rest],
         max_calls
       )
       when is_list(tool_calls) do
    retained_calls = Enum.take(tool_calls, max_calls)
    retained_ids = retained_calls |> Enum.map(&Map.get(&1, "id")) |> MapSet.new()

    retained_results =
      Enum.filter(rest, fn
        %{"role" => "tool", "tool_call_id" => id} -> MapSet.member?(retained_ids, id)
        _message -> false
      end)

    [Map.put(assistant, "tool_calls", retained_calls) | retained_results]
  end

  defp trim_group(messages, _max_calls), do: Enum.take(messages, 1)

  defp minimal_group([
         %{"role" => "assistant", "tool_calls" => [tool_call | _]} = assistant | rest
       ]) do
    id = Map.get(tool_call, "id", "bounded-tool-call")
    name = get_in(tool_call, ["function", "name"]) || "bounded_tool"
    namespace = get_in(tool_call, ["function", "namespace"])

    call =
      assistant
      |> Map.put(
        "content",
        Text.truncate_utf8_window(Map.get(assistant, "content", ""), 64, @truncation_suffix)
      )
      |> Map.put("tool_calls", [
        %{
          "id" => id,
          "type" => "function",
          "function" =>
            %{"name" => name, "arguments" => "{}"}
            |> Ankole.Attrs.maybe_put("namespace", namespace)
        }
      ])
      |> Map.delete("metadata")

    result =
      Enum.find(rest, fn
        %{"role" => "tool", "tool_call_id" => ^id} -> true
        _message -> false
      end)

    case result do
      %{} -> [call, bound_value(result, 64)]
      nil -> [call]
    end
  end

  defp minimal_group([message]), do: [bound_value(message, 64)]
  defp minimal_group(_messages), do: []

  defp encoded_bytes(value), do: value |> Ankole.JSON.encode!() |> byte_size()

  defp bound_value(value, limit) when is_binary(value) do
    Text.truncate_utf8_window(value, limit, @truncation_suffix)
  end

  defp bound_value(value, limit) when is_list(value) do
    value |> Enum.take(32) |> Enum.map(&bound_value(&1, limit))
  end

  defp bound_value(value, limit) when is_map(value) do
    value
    |> Enum.take(32)
    |> Map.new(fn {key, nested} -> {key, bound_value(nested, limit)} end)
  end

  defp bound_value(value, _limit), do: value

  defp mark_content_truncated(header, false), do: header

  defp mark_content_truncated(header, true) do
    metadata = if is_map(header["metadata"]), do: header["metadata"], else: %{}
    Map.put(header, "metadata", Map.put(metadata, "content_truncated", true))
  end

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, false), do: map

  defp encode_trajectory_cursor(%{turn_id: turn_id, position: position}, attempt) do
    %{
      "v" => @cursor_version,
      "attempt" => attempt,
      "turn_id" => turn_id,
      "group_position" => position
    }
    |> Ankole.JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_trajectory_cursor(nil, _attempt), do: {:ok, nil}

  defp decode_trajectory_cursor("", _attempt),
    do: {:error, :invalid_background_agent_job_trajectory_cursor}

  defp decode_trajectory_cursor(cursor, attempt) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{
            "v" => @cursor_version,
            "attempt" => cursor_attempt,
            "turn_id" => turn_id,
            "group_position" => position
          }} <- Ankole.JSON.decode(decoded),
         true <- is_integer(cursor_attempt) and cursor_attempt > 0,
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         true <- is_integer(position) and position >= 0 do
      if cursor_attempt == attempt do
        {:ok, %{turn_id: turn_id, position: position}}
      else
        {:error, :background_agent_job_trajectory_cursor_stale}
      end
    else
      _reason -> {:error, :invalid_background_agent_job_trajectory_cursor}
    end
  end

  defp decode_trajectory_cursor(_cursor, _attempt),
    do: {:error, :invalid_background_agent_job_trajectory_cursor}

  defp trajectory_has_pending_tool_call?(
         %Turn{} = turn,
         required_tool
       )
       when is_binary(required_tool) do
    messages = trajectory_messages(turn)

    result_ids =
      messages
      |> Enum.flat_map(fn
        %{"role" => "tool", "tool_call_id" => id} when is_binary(id) -> [id]
        _message -> []
      end)
      |> MapSet.new()

    Enum.any?(messages, fn
      %{
        "role" => "assistant",
        "metadata" => %{"status" => "pending_user_input"},
        "tool_calls" => tool_calls
      }
      when is_list(tool_calls) ->
        Enum.any?(tool_calls, fn
          %{"id" => id, "function" => %{"name" => ^required_tool}} when is_binary(id) ->
            not MapSet.member?(result_ids, id)

          _tool_call ->
            false
        end)

      _message ->
        false
    end)
  end

  defp trajectory_has_pending_tool_call?(_turn, _required_tool), do: false

  defp last_turn_summary(turns) do
    turns
    |> Enum.reverse()
    |> Enum.find_value(&turn_summary/1)
  end

  defp attempt_summary(turns) do
    error_summary =
      turns
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Turn{status: status, error: error}
        when status in ["failed", "interrupted"] and is_map(error) ->
          Enum.find_value(["summary", "code"], fn key ->
            case Map.get(error, key) do
              value when is_binary(value) and value != "" ->
                value
                |> remove_internal_uuid_tokens()
                |> Text.truncate_utf8_window(@attempt_summary_bytes, @truncation_suffix)

              _value ->
                nil
            end
          end)

        _turn ->
          nil
      end)

    error_summary || last_turn_summary(turns)
  end

  defp attempt_used_skill_names(turns) do
    turns
    |> Enum.flat_map(fn
      %Turn{progress: %{"skills_used" => skills}} when is_list(skills) -> skills
      _turn -> []
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp remove_internal_uuid_tokens(text) when is_binary(text),
    do: Regex.replace(@internal_uuid_pattern, text, "[internal-id]")

  defp turn_summary(%Turn{} = turn) do
    turn
    |> trajectory_messages()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} when is_binary(content) and content != "" ->
        Text.truncate_utf8_window(content, @attempt_summary_bytes, @truncation_suffix)

      _message ->
        nil
    end)
  end

  defp trajectory_messages(%Turn{} = turn) do
    [turn.id] |> trajectory_messages_by_turn() |> Map.get(turn.id, [])
  end

  defp trajectory_messages_by_turn(turn_ids) do
    turn_ids
    |> projection_units_by_turn()
    |> Map.new(fn {turn_id, units} ->
      {turn_id, Enum.flat_map(units, & &1.messages)}
    end)
  end

  # Returns the position-ordered message units of each Turn, projected from
  # the stored TurnItem stream. An item whose projection is empty stays
  # replay-only. A Turn recorded before the item stream existed has no item
  # rows and no readable form.
  defp projection_units_by_turn([]), do: %{}

  defp projection_units_by_turn(turn_ids) do
    TurnItem
    |> where([row], row.turn_id in ^turn_ids)
    |> order_by([row], asc: row.turn_id, asc: row.position)
    |> Repo.all()
    |> Enum.group_by(& &1.turn_id)
    |> Map.new(fn {turn_id, rows} ->
      {turn_id,
       Enum.flat_map(rows, fn row ->
         case TurnItemProjection.project(row.item) do
           {[], _truncated} ->
             []

           {messages, truncated} ->
             [%{position: row.position, messages: messages, truncated: truncated}]
         end
       end)}
    end)
  end

  defp empty_progress do
    %{
      "completed_items" => 0,
      "tool_calls" => 0,
      "tools_used" => [],
      "files_changed" => []
    }
  end

  defp empty_trajectory, do: Trajectory.empty_header()

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
