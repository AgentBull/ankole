defmodule Ankole.BackgroundAgentJobs.Turns do
  @moduledoc false

  import Ecto.Query

  alias Ankole.AIGateway.OpaqueContent
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.TrajectoryGroup
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Text
  alias Ankole.BackgroundAgentJobs.Trajectory

  @worker_fields ~w(
    attempt
    runtime_thread_id
    runtime_turn_id
    kind
    status
    revision
    trajectory
    trajectory_groups
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
  )
  @active_statuses ~w(in_progress)
  @terminal_turn_statuses ~w(completed failed interrupted)
  @message_ready_statuses ~w(waiting_on_user succeeded failed stopped)
  @trajectory_default_limit 3
  @trajectory_max_limit 20
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
         {trajectory_groups, attrs} <- Map.pop(attrs, "trajectory_groups", []),
         :ok <- validate_attempt(job, attrs),
         {:ok, turn} <- upsert_in_tx(repo, job, attrs, trajectory_groups) do
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
         |> maybe_put(:current, current_projection(current))
         |> maybe_put(:usage, latest_lead_usage(turns, job.runtime_thread_id))}
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

    TrajectoryGroup
    |> join(:inner, [group], turn in Turn, on: turn.id == group.turn_id)
    |> where([group, turn], group.item_key == ^item_key and turn.job_id == ^job.id)
    |> where([_group, turn], turn.kind == "agent")
    |> order_by([group, turn], asc: turn.started_at, asc: turn.id, asc: group.position)
    |> select([_group, turn], turn)
    |> limit(1)
    |> Repo.one()
  end

  defp newer_lead_turn?(%Job{} = job, %Turn{} = causal_turn) do
    lead_thread_ids =
      [causal_turn.runtime_thread_id, job.runtime_thread_id]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Turn
    |> where([turn], turn.job_id == ^job.id and turn.kind == "agent")
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
      TrajectoryGroup
      |> where([group], group.turn_id == ^turn.id)
      |> order_by([group], asc: group.position)
      |> Repo.all()
      |> Enum.map(fn group ->
        %{
          turn_id: group.turn_id,
          position: group.position,
          messages: group.content["messages"] |> OpaqueContent.reveal() |> bound_group()
        }
      end)

    selected = select_page_groups(groups, @trajectory_max_limit)
    messages = Enum.flat_map(selected, & &1.messages)
    header = turn.trajectory || empty_trajectory()

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
      |> where([turn], turn.kind == "agent")
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

  @spec console_projection(Turn.t()) :: map()
  def console_projection(%Turn{} = turn) do
    trajectory =
      turn
      |> trajectory_messages()
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

  defp upsert_in_tx(repo, %Job{} = job, attrs, trajectory_groups) do
    runtime_turn_id = Map.fetch!(attrs, "runtime_turn_id")

    case get_in_tx(repo, job.id, runtime_turn_id, lock: "FOR UPDATE") do
      nil ->
        with {:ok, turn} <- %Turn{} |> Turn.changeset(attrs) |> repo.insert(),
             :ok <- append_trajectory_groups(repo, turn, trajectory_groups) do
          {:ok, turn}
        end

      %Turn{} = turn ->
        update_existing(repo, turn, attrs, trajectory_groups)
    end
  end

  defp update_existing(repo, %Turn{} = turn, attrs, trajectory_groups) do
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
            with :ok <- checkpoint_groups_equal?(repo, turn, revision, trajectory_groups),
                 do: {:ok, turn}

          revision == turn.revision ->
            {:error, :background_agent_job_turn_revision_conflict}

          not Turn.transition_allowed?(turn.status, next_status) ->
            {:error, :background_agent_job_turn_status_transition_invalid}

          true ->
            with {:ok, updated} <- turn |> Turn.changeset(attrs) |> repo.update(),
                 :ok <- append_trajectory_groups(repo, updated, trajectory_groups) do
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

  defp append_trajectory_groups(_repo, _turn, []), do: :ok

  defp append_trajectory_groups(repo, %Turn{} = turn, groups) when is_list(groups) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      with {:ok, candidate, changeset} <- trajectory_group_candidate(turn, group) do
        existing =
          TrajectoryGroup
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
              {:ok, _group} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          Enum.any?(existing, &trajectory_group_equal?(&1, candidate)) and length(existing) == 1 ->
            {:cont, :ok}

          true ->
            {:halt, {:error, :background_agent_job_trajectory_group_conflict}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_trajectory_groups(_repo, _turn, _groups),
    do: {:error, :invalid_background_agent_job_trajectory_groups}

  defp trajectory_group_candidate(%Turn{} = turn, %{} = group) do
    attrs = Attrs.normalize(group)

    changeset =
      TrajectoryGroup.changeset(%TrajectoryGroup{}, %{
        turn_id: turn.id,
        position: attrs["position"],
        revision: turn.revision,
        item_key: attrs["item_key"],
        content: %{"messages" => attrs["messages"]}
      })

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, candidate} -> {:ok, candidate, changeset}
      {:error, invalid} -> {:error, invalid}
    end
  end

  defp trajectory_group_candidate(_turn, _group),
    do: {:error, :invalid_background_agent_job_trajectory_groups}

  defp checkpoint_groups_equal?(repo, turn, revision, groups) do
    stored =
      TrajectoryGroup
      |> where([row], row.turn_id == ^turn.id)
      |> order_by([row], asc: row.position)
      |> repo.all()

    current = Enum.filter(stored, &(&1.revision == revision))

    candidates =
      Enum.map(groups, fn group ->
        attrs = Attrs.normalize(group)

        %{
          position: attrs["position"],
          item_key: attrs["item_key"],
          content: %{"messages" => attrs["messages"]}
        }
      end)

    if trajectory_group_lists_equal?(current, candidates) or
         trajectory_group_lists_equal?(stored, candidates),
       do: :ok,
       else: {:error, :background_agent_job_turn_revision_conflict}
  end

  defp trajectory_group_lists_equal?(stored, candidates) do
    length(stored) == length(candidates) and
      Enum.zip(stored, candidates)
      |> Enum.all?(fn {row, value} -> trajectory_group_equal?(row, value) end)
  end

  defp trajectory_group_equal?(group, value) do
    group.position == value.position and group.item_key == value.item_key and
      group.content == value.content
  end

  defp lead_turn?(%Turn{} = turn, lead_thread_id),
    do: is_binary(lead_thread_id) and turn.runtime_thread_id == lead_thread_id

  defp inferred_attempt_lead_thread_id(turns) do
    turn = Enum.find(turns, &(&1.kind == "agent")) || List.first(turns)
    if turn, do: turn.runtime_thread_id
  end

  defp lead_turn_count(turns, lead_thread_id) do
    Enum.count(turns, &(&1.kind == "agent" and lead_turn?(&1, lead_thread_id)))
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
      lead: Enum.count(turns, &(&1.kind == "agent" and lead_turn?(&1, lead_thread_id))),
      child: Enum.count(turns, &(&1.kind == "agent" and not lead_turn?(&1, lead_thread_id))),
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
          files: MapSet.new(),
          skills: MapSet.new()
        },
        fn
          %Turn{progress: progress}, acc when is_map(progress) ->
            %{
              completed_items: acc.completed_items + nonnegative(progress["completed_items"]),
              tool_calls: acc.tool_calls + nonnegative(progress["tool_calls"]),
              tools: merge_tool_usage(acc.tools, progress["tools_used"]),
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
          |> Enum.sort_by(fn {name, _calls} -> name end)
          |> Enum.map(fn {name, calls} -> %{name: name, calls: calls} end),
        files_changed: totals.files |> MapSet.to_list() |> Enum.sort(),
        active_items: active_items(turns, job)
      }
      |> then(fn progress ->
        case totals.skills |> MapSet.to_list() |> Enum.sort() do
          [] -> progress
          skills -> Map.put(progress, :skills_used, skills)
        end
      end)

    maybe_put(progress, :plan, latest_lead_plan(turns, job.runtime_thread_id))
  end

  defp merge_tool_usage(acc, tools) when is_list(tools) do
    Enum.reduce(tools, acc, fn
      %{"name" => name, "calls" => calls}, result
      when is_binary(name) and is_integer(calls) and calls >= 0 ->
        Map.update(result, name, calls, &(&1 + calls))

      _tool, result ->
        result
    end)
  end

  defp merge_tool_usage(acc, _tools), do: acc

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
        %{"active_item" => %{"name" => name}} when is_binary(name) ->
          [
            %{
              scope: if(lead_turn?(turn, job.runtime_thread_id), do: "lead", else: "child"),
              name: name
            }
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
      |> Enum.filter(&(&1.kind == "agent" and lead_turn?(&1, job.runtime_thread_id)))

    groups =
      if lead_turns == [] do
        []
      else
        turn_ids = Enum.map(lead_turns, & &1.id)

        stored_by_turn =
          TrajectoryGroup
          |> where([group], group.turn_id in ^turn_ids)
          |> Repo.all()
          |> Enum.group_by(& &1.turn_id)

        Enum.flat_map(lead_turns, fn turn ->
          stored_by_turn
          |> Map.get(turn.id, [])
          |> Enum.sort_by(& &1.position)
          |> Enum.map(fn group ->
            %{
              turn_id: group.turn_id,
              position: group.position,
              messages: bound_group(group.content["messages"])
            }
          end)
        end)
      end

    with {:ok, older_groups} <- groups_before_cursor(groups, cursor) do
      selected = select_page_groups(older_groups, limit)
      has_more = length(older_groups) > length(selected)

      page = %{
        format: "ankole_chatml",
        version: 1,
        messages: selected |> Enum.flat_map(& &1.messages)
      }

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

  defp groups_before_cursor(groups, nil), do: {:ok, groups}

  defp groups_before_cursor(groups, %{turn_id: turn_id, position: position}) do
    case Enum.find_index(groups, &(&1.turn_id == turn_id and &1.position == position)) do
      nil -> {:error, :invalid_background_agent_job_trajectory_cursor}
      index -> {:ok, Enum.take(groups, index)}
    end
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

    [@model_string_bytes, 2_000, 1_000, 500, 200, 64]
    |> Enum.find_value(fn limit ->
      bounded = Enum.map(trimmed, &bound_value(&1, limit))

      if encoded_bytes(bounded) <= @trajectory_page_bytes - @trajectory_page_reserve_bytes,
        do: bounded
    end)
    |> case do
      nil -> minimal_group(trimmed)
      bounded -> bounded
    end
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
          "function" => %{"name" => name, "arguments" => "{}"}
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
    TrajectoryGroup
    |> where([group], group.turn_id == ^turn.id)
    |> order_by([group], asc: group.position)
    |> Repo.all()
    |> Enum.flat_map(&Map.get(&1.content, "messages", []))
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
