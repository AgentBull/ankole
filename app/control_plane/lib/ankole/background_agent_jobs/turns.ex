defmodule Ankole.BackgroundAgentJobs.Turns do
  @moduledoc """
  Records Worker turns and projects Turn rows.

  The recorder owns every write. The projections in this module read only
  Turn rows; each trajectory they carry comes from one
  `Ankole.BackgroundAgentJobs.TrajectoryReader.page/4` call with an explicit
  budget.
  """

  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.Trajectory
  alias Ankole.BackgroundAgentJobs.TrajectoryReader
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.BackgroundAgentJobs.TurnWatchdog
  alias Ankole.Text

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
  @model_page_bytes 24 * 1_024
  @model_page_budget %{groups: @trajectory_max_limit, bytes: @model_page_bytes}
  @console_page_budget @model_page_budget
  @replay_page_budget %{items: 200}
  @attempt_summary_bytes 2_000
  @attempt_summary_budget %{bytes: @attempt_summary_bytes}
  @truncation_suffix "...[truncated]"
  @internal_uuid_pattern ~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i

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

  @doc """
  Pages the lead-thread turn items of one Job's workspace lineage in
  chronological order.

  The Worker replays these items into a replacement Codex thread when the
  Worker-local native thread state is gone.
  """
  @spec replay_items_page(Job.t(), String.t() | nil) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def replay_items_page(%Job{} = job, cursor) do
    with {:ok, page} <- TrajectoryReader.page(job, :lineage_replay, cursor, @replay_page_budget) do
      {:ok, %{items: page.units, next_cursor: page.next_cursor}}
    end
  end

  @spec execution_projection(Job.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execution_projection(%Job{} = job, opts \\ []) do
    with {:ok, limit} <- trajectory_limit(Keyword.get(opts, :trajectory_limit)),
         turns = current_attempt_turns(job),
         lead_turns = Enum.filter(turns, &Turn.lead?(&1, job.runtime_thread_id)),
         {:ok, page} <-
           TrajectoryReader.page(
             job,
             {:current_attempt_lead, lead_turns},
             Keyword.get(opts, :trajectory_cursor),
             %{groups: limit, bytes: @model_page_bytes}
           ) do
      current = current_turn(turns, job.runtime_thread_id)

      execution = %{
        attempt: job.attempts,
        lead_turn_number: length(lead_turns),
        threads: thread_counts(turns, job.runtime_thread_id),
        turns: turn_counts(turns, job.runtime_thread_id),
        progress: aggregate_progress(turns, job),
        trajectory_page: trajectory_page(page),
        updated_at: execution_updated_at(turns, job)
      }

      {:ok,
       execution
       |> Ankole.Attrs.maybe_put(:current, current_projection(current))
       |> Ankole.Attrs.maybe_put(:usage, latest_lead_usage(turns, job.runtime_thread_id))}
    end
  end

  defp trajectory_page(page) do
    metadata =
      %{}
      |> maybe_put_true("redacted", Enum.any?(page.units, & &1.redacted))
      |> maybe_put_true("content_truncated", Enum.any?(page.units, & &1.content_truncated))

    %{
      format: "ankole_chatml",
      version: 1,
      messages: Enum.flat_map(page.units, & &1.messages)
    }
    |> Ankole.Attrs.maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))
    |> Ankole.Attrs.maybe_put(:next_cursor, page.next_cursor)
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
    {:ok, page} = TrajectoryReader.page(job, {:one_turn, turn}, nil, @model_page_budget)

    %{
      job_id: job.id,
      status: job.status,
      ready: true,
      last_turn_trajectory: turn_trajectory(turn, page.units),
      earlier_trajectory_omitted: page.next_cursor != nil,
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

  # The stored header carries the Worker's own integrity facts; the page adds
  # what projection or the byte budget removed.
  defp turn_trajectory(%Turn{} = turn, units) do
    header = turn.trajectory || empty_trajectory()

    header
    |> mark_content_truncated(Enum.any?(units, & &1.content_truncated))
    |> Map.put("messages", Enum.flat_map(units, & &1.messages))
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

    lead_turns = Enum.filter(turns, &Turn.lead?(&1, job.runtime_thread_id))
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
      ordered = Enum.sort_by(turns, &Turn.start_key/1)
      lead_thread_id = Turn.attempt_lead_thread_id(ordered)
      lead = Enum.filter(ordered, &Turn.lead?(&1, lead_thread_id))

      %{
        attempt: attempt,
        turn_statuses: ordered |> Enum.map(& &1.status) |> Enum.uniq(),
        summary: attempt_summary(job, lead) || attempt_summary(job, ordered),
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

  @doc """
  Projects one bounded page of a Job's runtime Turns for the Console.

  The page spans the newest Turns first. A Turn without a readable unit on
  the page still appears, so an operator sees a failed Turn that recorded
  no items.
  """
  @spec console_page(Job.t(), String.t() | nil) ::
          {:ok, %{turns: [map()], next_cursor: String.t() | nil}} | {:error, atom()}
  def console_page(%Job{} = job, cursor) do
    turns = list_for_job(job.id)

    with {:ok, page} <-
           TrajectoryReader.page(job, {:console_detail, turns}, cursor, @console_page_budget) do
      turns_by_id = Map.new(turns, &{&1.id, &1})
      units_by_turn = Enum.group_by(page.units, & &1.turn_id)

      projections =
        Enum.map(page.turn_ids, fn turn_id ->
          turn = Map.fetch!(turns_by_id, turn_id)
          projection(turn, turn_trajectory(turn, Map.get(units_by_turn, turn_id, [])))
        end)

      {:ok, %{turns: projections, next_cursor: page.next_cursor}}
    end
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

  defp thread_counts(turns, lead_thread_id) do
    thread_ids = turns |> Enum.map(& &1.runtime_thread_id) |> Enum.uniq()

    %{
      total: length(thread_ids),
      child: Enum.count(thread_ids, &(&1 != lead_thread_id))
    }
  end

  defp turn_counts(turns, lead_thread_id) do
    %{
      lead: Enum.count(turns, &Turn.lead?(&1, lead_thread_id)),
      child: Enum.count(turns, &(not Turn.lead?(&1, lead_thread_id))),
      compaction: Enum.count(turns, &(&1.kind == "compaction")),
      active: Enum.count(turns, &(&1.status in @active_statuses))
    }
  end

  defp current_turn(turns, lead_thread_id) do
    turns
    |> Enum.filter(&Turn.lead?(&1, lead_thread_id))
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
      Turn.lead?(turn, lead_thread_id) and is_map(turn.progress) and
        is_map(turn.progress["plan"])
    end)
    |> Enum.max_by(&Turn.update_key/1, fn -> nil end)
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
    |> Enum.sort_by(&Turn.update_key/1, :desc)
    |> Enum.flat_map(fn turn ->
      case turn.progress do
        %{"active_item" => %{"name" => name} = active_item} when is_binary(name) ->
          [
            %{
              scope: if(Turn.lead?(turn, job.runtime_thread_id), do: "lead", else: "child"),
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
    |> Enum.filter(&(Turn.lead?(&1, lead_thread_id) and is_map(&1.usage)))
    |> Enum.max_by(&Turn.update_key/1, fn -> nil end)
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
    |> Enum.max_by(&Turn.update_key/1)
    |> Map.fetch!(:updated_at)
    |> iso8601()
  end

  defp trajectory_limit(nil), do: {:ok, @trajectory_default_limit}

  defp trajectory_limit(limit)
       when is_integer(limit) and limit >= 1 and limit <= @trajectory_max_limit,
       do: {:ok, limit}

  defp trajectory_limit(_limit), do: {:error, :invalid_background_agent_job_trajectory_limit}

  defp mark_content_truncated(header, false), do: header

  defp mark_content_truncated(header, true) do
    metadata = if is_map(header["metadata"]), do: header["metadata"], else: %{}
    Map.put(header, "metadata", Map.put(metadata, "content_truncated", true))
  end

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, false), do: map

  # The waiting gate scans one Turn for an unanswered request. The scan is
  # part of the recorder's commit guard, so it reads the whole Turn instead
  # of a budgeted page whose ladder could drop the pending marker.
  defp trajectory_has_pending_tool_call?(
         %Turn{} = turn,
         required_tool
       )
       when is_binary(required_tool) do
    messages = turn_messages(turn)

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

  defp turn_messages(%Turn{id: turn_id}) do
    TurnItem
    |> where([row], row.turn_id == ^turn_id)
    |> order_by([row], asc: row.position)
    |> Repo.all()
    |> Enum.flat_map(fn row -> row.item |> TurnItemProjection.project() |> elem(0) end)
  end

  defp attempt_summary(%Job{} = job, turns) do
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

    error_summary || last_assistant_text(job, turns)
  end

  defp last_assistant_text(_job, []), do: nil

  defp last_assistant_text(%Job{} = job, turns) do
    {:ok, page} =
      TrajectoryReader.page(job, {:attempt_summary, turns}, nil, @attempt_summary_budget)

    case page.units do
      [%{text: text}] -> text
      [] -> nil
    end
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
