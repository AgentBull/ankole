defmodule Ankole.Schedule.Routines do
  @moduledoc false

  require Ash.Query

  alias Ankole.AIGateway
  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.Principals.WorkAccess
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Delivery
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.AgentRoutine
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store
  alias Ankole.Sessions.Key
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Coalesce

  @spec execution_session_id(Ecto.UUID.t()) :: String.t()
  def execution_session_id(routine_id) when is_binary(routine_id),
    do: Key.routine(routine_id)

  @spec room_ids(AgentRoutine.t()) :: [Ecto.UUID.t()]
  def room_ids(%AgentRoutine{} = routine) do
    targets =
      for %{"conversation_id" => id} <- get_in(routine.delivery || %{}, ["targets"]) || [],
          is_binary(id),
          {:ok, uuid} <- [Ecto.UUID.cast(id)],
          do: uuid

    owner_room =
      case Key.parse(routine.owner_session_id) do
        {:conversation, id} -> id
        _ -> nil
      end

    [owner_room | targets]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec list_merged_run_entries(AgentRoutine.t(), pos_integer()) :: [
          {:signal, Ankole.Signals.Signal.t()} | {:event, ScheduledEvent.t()}
        ]
  def list_merged_run_entries(%AgentRoutine{} = routine, limit \\ 25)
      when is_integer(limit) and limit > 0 do
    session_id = execution_session_id(routine.id)
    signals = Ankole.Signals.list_session_execution_signals(routine.agent_uid, session_id, limit)

    cron_ids =
      [routine.id]
      |> schedules_by_owner_routines()
      |> Map.get(routine.id, [])
      |> Enum.map(& &1.id)

    unlinked_events = Ankole.Schedule.list_unlinked_cron_fire_events(cron_ids, limit)

    signal_entries =
      Enum.map(signals, fn signal ->
        instant =
          signal.last_attempt_at || signal.inserted_at || signal.occurred_at ||
            DateTime.from_unix!(0)

        {{DateTime.to_unix(instant, :microsecond), 1, signal.queue_sequence || 0},
         {:signal, signal}}
      end)

    event_entries =
      Enum.map(unlinked_events, fn event ->
        {{DateTime.to_unix(event.due_at, :microsecond), 0, event.id}, {:event, event}}
      end)

    (signal_entries ++ event_entries)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 1))
  end

  @spec get_routine_record(Ecto.UUID.t()) :: AgentRoutine.t() | nil
  def get_routine_record(routine_id) when is_binary(routine_id) do
    case Ecto.UUID.cast(routine_id) do
      {:ok, id} ->
        AgentRoutine
        |> Ash.Query.filter(id == ^id)
        |> read_one()

      :error ->
        nil
    end
  end

  @spec get_routine(Ecto.UUID.t()) :: {:ok, AgentRoutine.t()} | {:error, :not_found}
  def get_routine(routine_id) when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{} = routine -> {:ok, routine}
      nil -> {:error, :not_found}
    end
  end

  @spec get_routine_by_name(String.t(), String.t(), String.t()) ::
          {:ok, AgentRoutine.t()} | {:error, :not_found}
  def get_routine_by_name(agent_uid, owner_session_id, name)
      when is_binary(agent_uid) and is_binary(owner_session_id) and is_binary(name) do
    agent_uid = String.downcase(agent_uid)

    AgentRoutine
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and owner_session_id == ^owner_session_id and name == ^name and
        status != :deleted
    )
    |> read_one()
    |> case do
      %AgentRoutine{} = routine -> {:ok, routine}
      nil -> {:error, :not_found}
    end
  end

  @spec list_routines(String.t() | nil, String.t() | nil) :: [AgentRoutine.t()]
  def list_routines(agent_uid \\ nil, owner_session_id \\ nil) do
    AgentRoutine
    |> maybe_where_agent(agent_uid)
    |> Ash.Query.filter(status != :deleted)
    |> maybe_where_owner_session(owner_session_id)
    |> Ash.Query.sort(agent_uid: :asc, owner_session_id: :asc, name: :asc)
    |> read_all()
  end

  @spec list_board_routines() :: [AgentRoutine.t()]
  def list_board_routines do
    AgentRoutine
    |> Ash.Query.filter(status in [:active, :paused])
    |> Ash.Query.sort(updated_at: :desc, name: :asc)
    |> read_all()
  end

  @spec schedules_by_owner_routines([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [CronSchedule.t()]}
  def schedules_by_owner_routines([]), do: %{}

  def schedules_by_owner_routines(routine_ids) when is_list(routine_ids) do
    CronSchedule
    |> Ash.Query.filter(owner_routine_id in ^routine_ids and status != :deleted)
    |> Ash.Query.sort(next_fire_at: :asc_nils_last, name: :asc)
    |> read_all()
    |> Enum.group_by(& &1.owner_routine_id)
  end

  @spec bindings_by_owner_routines([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [struct()]}
  def bindings_by_owner_routines([]), do: %{}

  def bindings_by_owner_routines(routine_ids) when is_list(routine_ids) do
    routine_ids
    |> Ankole.Signals.external_bindings_for_routines()
    |> Enum.group_by(& &1.agent_routine_id)
  end

  @spec lock_routine_in_tx(Ecto.UUID.t()) :: AgentRoutine.t() | nil
  def lock_routine_in_tx(routine_id) when is_binary(routine_id) do
    AgentRoutine
    |> Ash.Query.filter(id == ^routine_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"agent_routines", routine_id})
  end

  @spec lock_routines_in_tx([Ecto.UUID.t()], :for_update | String.t()) :: [AgentRoutine.t()]
  def lock_routines_in_tx(routine_ids, lock_mode \\ :for_update)
  def lock_routines_in_tx([], _lock_mode), do: []

  def lock_routines_in_tx(routine_ids, lock_mode) when is_list(routine_ids) do
    ids = routine_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    if ids == [] do
      []
    else
      AgentRoutine
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(lock_mode)
      |> Ankole.Ash.read!(lock_identity: {"agent_routines", ids})
    end
  end

  @spec lock_by_idempotency(map()) :: {:ok, AgentRoutine.t()} | {:error, :routine_not_found}
  def lock_by_idempotency(attrs) do
    AgentRoutine
    |> Ash.Query.filter(
      agent_uid == ^attrs.agent_uid and owner_session_id == ^attrs.owner_session_id and
        idempotency_key == ^attrs.idempotency_key
    )
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {:rows, "agent_routines", :id})
    |> case do
      %AgentRoutine{} = routine -> {:ok, routine}
      nil -> {:error, :routine_not_found}
    end
  end

  @doc false
  def upsert_for_cron_in_tx(attrs) do
    task =
      case get_in(attrs, [:payload, "task"]) do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: attrs.name, else: trimmed

        _ ->
          attrs.name
      end

    routine_attrs = %{
      id: attrs.id,
      authorization_kind: attrs[:authorization_kind],
      human_uid: attrs[:human_uid],
      human_access_version: attrs[:human_access_version],
      status: attrs.status,
      agent_uid: attrs.agent_uid,
      owner_session_id: attrs.owner_session_id,
      binding_name: attrs.binding_name,
      name: attrs.name,
      task: task,
      delivery: attrs.delivery || %{},
      definition_version: 1,
      idempotency_key: attrs.idempotency_key,
      created_by: attrs.created_by || %{}
    }

    with {:ok, _attempted} <-
           Ankole.Ash.create(AgentRoutine, :create, routine_attrs, touch_update_defaults?: false),
         {:ok, persisted} <- lock_by_idempotency(routine_attrs) do
      {:ok, persisted}
    end
  end

  @doc false
  def resolve_routine_for_cron_update_in_tx(%CronSchedule{owner_job_id: id}, _attrs)
      when is_integer(id),
      do: {:ok, nil}

  def resolve_routine_for_cron_update_in_tx(%CronSchedule{} = schedule, attrs) do
    cond do
      Map.has_key?(attrs, :automation_job_id) and is_integer(attrs[:automation_job_id]) ->
        {:ok, nil}

      is_binary(schedule.owner_routine_id) ->
        {:ok, schedule.owner_routine_id}

      Map.has_key?(attrs, :automation_job_id) and is_nil(attrs[:automation_job_id]) ->
        attach_routine_for_cron_in_tx(schedule, attrs)

      true ->
        {:ok, schedule.owner_routine_id}
    end
  end

  defp attach_routine_for_cron_in_tx(%CronSchedule{} = schedule, attrs) do
    id = Ash.UUIDv7.generate()
    payload = attrs[:payload] || schedule.payload || %{}
    delivery = attrs[:delivery] || schedule.delivery || %{}
    name = attrs[:name] || schedule.name
    task = String.trim(payload["task"] || name)

    routine_attrs = %{
      id: id,
      authorization_kind: schedule.authorization_kind,
      human_uid: schedule.human_uid,
      human_access_version: schedule.human_access_version,
      status: schedule.status,
      agent_uid: schedule.agent_uid,
      owner_session_id: schedule.owner_session_id,
      binding_name: attrs[:binding_name] || schedule.binding_name,
      name: name,
      task: if(task == "", do: name, else: task),
      delivery: delivery,
      definition_version: 1,
      idempotency_key: "cron-reattach:#{schedule.id}:#{id}",
      created_by: schedule.created_by || %{}
    }

    with {:ok, routine} <-
           Ankole.Ash.create(AgentRoutine, :create, routine_attrs, touch_update_defaults?: false) do
      {:ok, routine.id}
    end
  end

  @doc false
  def sync_from_cron_update_in_tx(nil, _changes, _now), do: :ok

  def sync_from_cron_update_in_tx(routine_id, changes, now) when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      nil ->
        :ok

      %AgentRoutine{} = routine ->
        if is_integer(Map.get(changes, :automation_job_id)) do
          # Switching a standalone schedule into an Action detaches it from AgentRoutine.
          if not has_live_triggers_except_cron?(routine.id, Map.get(changes, :detached_cron_id)) do
            with {:ok, _} <- put_routine_status(routine, :deleted),
                 :ok <- end_routine_conversation_in_tx(routine, now),
                 do: :ok
          else
            :ok
          end
        else
          routine_changes =
            %{}
            |> Attrs.maybe_put(:name, changes[:name])
            |> Attrs.maybe_put(:delivery, changes[:delivery])
            |> Attrs.maybe_put(:binding_name, changes[:binding_name])
            |> maybe_put_task_from_payload(changes[:payload])

          if map_size(routine_changes) == 0 do
            :ok
          else
            with {:ok, _updated} <-
                   Ankole.Ash.update(routine, :update_definition, routine_changes) do
              :ok
            end
          end
        end
    end
  end

  @doc false
  def sync_after_cron_pause_in_tx(routine_id, now, opts \\ [])
  def sync_after_cron_pause_in_tx(nil, _now, _opts), do: {:ok, []}

  def sync_after_cron_pause_in_tx(routine_id, now, opts) when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{status: :active} = routine ->
        if has_enabled_external_bindings?(routine.id) or has_active_child_crons?(routine.id) do
          {:ok, []}
        else
          revocation = {routine.agent_uid, execution_session_id(routine.id), "routine_paused"}

          with {:ok, routine} <- put_routine_status(routine, :paused),
               {:ok, _} <- cancel_pending_routine_checkbacks_in_tx(routine, now, "routine_paused"),
               :ok <-
                 if(Keyword.get(opts, :defer_signal_revoke, false),
                   do: :ok,
                   else: revoke_unstarted_routine_signals_in_tx(routine, now, "routine_paused")
                 ) do
            {:ok, if(Keyword.get(opts, :defer_signal_revoke, false), do: [revocation], else: [])}
          end
        end

      _ ->
        {:ok, []}
    end
  end

  @doc false
  def sync_after_cron_resume_in_tx(nil), do: :ok

  def sync_after_cron_resume_in_tx(routine_id) when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{status: status} = routine when status in [:paused, :completed] ->
        with {:ok, _} <- put_routine_status(routine, :active), do: :ok

      _ ->
        :ok
    end
  end

  @doc false
  def sync_after_cron_remove_in_tx(routine_id, cron_id, now, opts \\ [])
  def sync_after_cron_remove_in_tx(nil, _cron_id, _now, _opts), do: {:ok, []}

  def sync_after_cron_remove_in_tx(routine_id, cron_id, now, opts)
      when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{status: status} = routine when status != :deleted ->
        if has_live_triggers_except_cron?(routine.id, cron_id) do
          {:ok, []}
        else
          revocation = {routine.agent_uid, execution_session_id(routine.id), "routine_deleted"}

          with {:ok, routine} <- put_routine_status(routine, :deleted),
               {:ok, _} <-
                 cancel_pending_routine_checkbacks_in_tx(routine, now, "routine_deleted"),
               :ok <- end_routine_conversation_in_tx(routine, now),
               :ok <-
                 if(Keyword.get(opts, :defer_signal_revoke, false),
                   do: :ok,
                   else: revoke_unstarted_routine_signals_in_tx(routine, now, "routine_deleted")
                 ) do
            {:ok, if(Keyword.get(opts, :defer_signal_revoke, false), do: [revocation], else: [])}
          end
        end

      _ ->
        {:ok, []}
    end
  end

  @doc false
  def maybe_complete_routine_after_binding_disabled_in_tx(routine_id, now)
      when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{status: :active} = routine ->
        if has_enabled_external_bindings?(routine.id) do
          :ok
        else
          crons =
            CronSchedule
            |> Ash.Query.filter(owner_routine_id == ^routine.id and status != :deleted)
            |> read_all()

          cond do
            crons == [] ->
              with {:ok, _routine} <- put_routine_status(routine, :paused), do: :ok

            Enum.all?(crons, &(&1.status == :completed)) ->
              with {:ok, routine} <- put_routine_status(routine, :completed),
                   :ok <- end_routine_conversation_in_tx(routine, now) do
                :ok
              end

            true ->
              :ok
          end
        end

      _ ->
        :ok
    end
  end

  @doc false
  def lock_routine_children_in_tx(routine_id) when is_binary(routine_id) do
    CronSchedule
    |> Ash.Query.filter(owner_routine_id == ^routine_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "cron_schedules", :id})
  end

  @doc false
  def reauthorize_routine_children_in_tx(routine_id, authorization) when is_binary(routine_id) do
    routine_id
    |> lock_routine_children_in_tx()
    |> Enum.reduce_while(:ok, fn cron, :ok ->
      case Ankole.Ash.update(cron, :reauthorize, authorization) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def maybe_complete_after_cron_exhausted_in_tx(nil, _cron_id, _now), do: :ok

  def maybe_complete_after_cron_exhausted_in_tx(routine_id, cron_id, now)
      when is_binary(routine_id) do
    case get_routine_record(routine_id) do
      %AgentRoutine{status: status} = routine when status in [:active, :paused] ->
        if has_enabled_external_bindings?(routine.id) or
             has_live_child_crons_except?(routine.id, cron_id) do
          :ok
        else
          with {:ok, routine} <- put_routine_status(routine, :completed),
               :ok <- end_routine_conversation_in_tx(routine, now) do
            :ok
          end
        end

      _ ->
        :ok
    end
  end

  @spec create_routine_in_tx(map(), keyword()) ::
          {:ok,
           %{
             status: :created | :already_exists,
             routine: AgentRoutine.t(),
             cron_schedule: CronSchedule.t() | nil
           }}
          | {:error, term()}
  def create_routine_in_tx(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with {:ok, normalized} <- normalize_routine_create_attrs(attrs, now, opts) do
      normalized =
        case Keyword.fetch(opts, :authorization) do
          {:ok, authorization} -> WorkAccess.merge(normalized, authorization)
          :error -> WorkAccess.inherit(normalized)
        end

      with :ok <- WorkAccess.check_attrs_in_tx(normalized),
           :ok <- WorkAccess.check_execution_target(normalized.agent_uid, normalized),
           :ok <- validate_native_delivery_in_tx(normalized.agent_uid, normalized.delivery) do
        insert_routine_in_tx(normalized, now, opts)
      end
    end
  end

  @spec update_routine_in_tx(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, AgentRoutine.t()} | {:error, term()}
  def update_routine_in_tx(routine_id, attrs, opts \\ [])
      when is_binary(routine_id) and is_map(attrs) do
    with {:ok, updated, _seals} <- update_routine_with_seals_in_tx(routine_id, attrs, opts) do
      {:ok, updated}
    end
  end

  @doc false
  def update_routine_with_seals_in_tx(routine_id, attrs, opts \\ [])
      when is_binary(routine_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    defer? = Keyword.get(opts, :defer_signal_revoke, false)
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with %AgentRoutine{} = snapshot <- get_routine_record(routine_id),
         {:ok, locked, _bindings, crons} <- lock_routine_tree_in_tx(routine_id),
         true <- locked.agent_uid == snapshot.agent_uid,
         :ok <- reject_terminal(locked),
         {:ok, routine_changes, schedule_op} <-
           normalize_routine_update_attrs(locked, crons, attrs, now, opts),
         :ok <-
           validate_native_delivery_in_tx(
             locked.agent_uid,
             routine_changes[:delivery] || locked.delivery
           ) do
      changeset = Ankole.Ash.for_update(locked, :update_definition, routine_changes)

      definition_bumped? =
        Ash.Changeset.changing_attribute?(changeset, :task) or
          Ash.Changeset.changing_attribute?(changeset, :delivery)

      payload_extra =
        case attrs["payload"] do
          %{} = payload -> Map.delete(payload, "task")
          _ -> %{}
        end

      with {:ok, updated} <- Ankole.Ash.update(changeset),
           :ok <- apply_schedule_op_in_tx(updated, crons, schedule_op, payload_extra, now, opts),
           :ok <-
             if(definition_bumped?,
               do: end_routine_conversation_in_tx(updated, now),
               else: :ok
             ),
           :ok <-
             if(definition_bumped? and not defer?,
               do: seal_open_coalesced_signals_in_tx(updated),
               else: :ok
             ) do
        seals = if definition_bumped? and defer?, do: [updated], else: []
        {:ok, updated, seals}
      end
    else
      nil -> {:error, :routine_not_found}
      false -> {:error, :routine_changed}
      {:error, _} = error -> error
    end
  end

  @spec pause_routine_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, AgentRoutine.t()} | {:error, term()}
  def pause_routine_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    with {:ok, routine, _revocations} <- pause_routine_with_revocations_in_tx(routine_id, opts) do
      {:ok, routine}
    end
  end

  @doc false
  def pause_routine_with_revocations_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    defer? = Keyword.get(opts, :defer_signal_revoke, false)

    with {:ok, routine, _bindings, crons} <- lock_routine_tree_in_tx(routine_id),
         :ok <- reject_terminal(routine),
         was_active? = routine.status == :active,
         {:ok, routine} <- put_routine_status(routine, :paused),
         :ok <- pause_child_crons_in_tx(crons),
         {:ok, _events} <-
           cancel_pending_routine_events_in_tx(routine, crons, now, "routine_paused"),
         :ok <-
           if(defer? or not was_active?,
             do: :ok,
             else: revoke_unstarted_routine_signals_in_tx(routine, now, "routine_paused")
           ) do
      revocations =
        if defer? and was_active?,
          do: [{routine.agent_uid, execution_session_id(routine.id), "routine_paused"}],
          else: []

      {:ok, routine, revocations}
    else
      {:error, _} = error -> error
    end
  end

  @spec resume_routine_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, AgentRoutine.t()} | {:error, term()}
  def resume_routine_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- WorkAccess.check_record_in_tx(AgentRoutine, routine_id),
         {:ok, routine, _bindings, crons} <- lock_routine_tree_in_tx(routine_id),
         :ok <- reject_terminal(routine),
         {:ok, routine} <- put_routine_status(routine, :active),
         :ok <- resume_child_crons_in_tx(routine, crons, now) do
      {:ok, get_routine_record(routine.id) || routine}
    end
  end

  @spec remove_routine_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, AgentRoutine.t()} | {:error, term()}
  def remove_routine_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    with {:ok, routine, _revocations} <- remove_routine_with_revocations_in_tx(routine_id, opts) do
      {:ok, routine}
    end
  end

  @doc false
  def remove_routine_with_revocations_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    defer? = Keyword.get(opts, :defer_signal_revoke, false)

    with {:ok, routine, bindings, crons} <- lock_routine_tree_in_tx(routine_id),
         was_deleted? = routine.status == :deleted,
         {:ok, routine} <- put_routine_status(routine, :deleted),
         :ok <- disable_external_bindings_in_tx(bindings),
         :ok <- delete_child_crons_in_tx(crons),
         {:ok, _events} <-
           cancel_pending_routine_events_in_tx(routine, crons, now, "routine_deleted"),
         :ok <- end_routine_conversation_in_tx(routine, now),
         :ok <-
           if(defer? or was_deleted?,
             do: :ok,
             else: revoke_unstarted_routine_signals_in_tx(routine, now, "routine_deleted")
           ) do
      revocations =
        if defer? and not was_deleted?,
          do: [{routine.agent_uid, execution_session_id(routine.id), "routine_deleted"}],
          else: []

      {:ok, routine, revocations}
    end
  end

  @spec run_routine_in_tx(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_routine_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    with {:ok, prepared} <- prepare_routine_run_in_tx(routine_id, opts) do
      case prepared do
        {:cron_event, run_result} ->
          {:ok, run_result}

        {:manual_signal, _routine, signal_attrs} ->
          with {:ok, signal} <- Ankole.Signals.accept_in_tx(signal_attrs) do
            {:ok, %{status: :scheduled, signal: signal, signals: [signal], scheduled_event: nil}}
          end
      end
    end
  end

  @doc false
  def prepare_routine_run_in_tx(routine_id, opts \\ []) when is_binary(routine_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- Ankole.Tenants.check_work_admission(Ankole.Repo.tenant_id!()),
         :ok <- WorkAccess.check_record_in_tx(AgentRoutine, routine_id),
         {:ok, routine, _bindings, crons} <- lock_routine_tree_in_tx(routine_id),
         :ok <- reject_terminal(routine),
         {:ok, request_id} <- manual_request_id(opts) do
      case Enum.find(crons, &(&1.status in [:active, :paused])) do
        %CronSchedule{} = schedule ->
          with {:ok, run_result} <-
                 Cron.run_locked_cron_schedule_in_tx(schedule, request_id, now, opts) do
            {:ok, {:cron_event, run_result}}
          end

        nil ->
          with {:ok, signal_attrs} <- manual_event_routine_signal_attrs(routine, request_id, now) do
            {:ok, {:manual_signal, routine, signal_attrs}}
          end
      end
    end
  end

  @doc "Pauses the active routines of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(uid, version, _now) do
    {:ok, routines} =
      AgentRoutine
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status == :active
      )
      |> Ankole.Ash.update_where(:stop_human_work, %{})

    {length(routines), nil}
  end

  defp manual_event_routine_signal_attrs(%AgentRoutine{} = routine, request_id, now) do
    with {:ok, primary_target} <-
           Delivery.primary_target(routine.delivery || %{}, routine.binding_name) do
      {:ok,
       %{
         producer: :kernel,
         source: "control-plane://routine/#{routine.id}",
         id: "routine-manual:#{routine.id}:#{request_id}",
         type: "routine.manual_run",
         subject: "routine:#{routine.id}",
         time: now,
         data: %{
           "trigger" => "manual",
           "routine_id" => routine.id,
           "routine_name" => routine.name,
           "requested_at" => DateTime.to_iso8601(now)
         },
         target: %{
           agent_uid: routine.agent_uid,
           session_id: execution_session_id(routine.id)
         },
         authorization: WorkAccess.fields(routine),
         reply_route: primary_target,
         internal_extensions: %{
           "ankole_routine" => %{
             "routine_id" => routine.id,
             "routine_name" => routine.name,
             "task" => routine.task,
             "delivery" => routine.delivery || %{},
             "definition_version" => routine.definition_version
           }
         }
       }}
    end
  end

  defp lock_routine_tree_in_tx(routine_id) do
    # Lock the owning AgentRoutine row FIRST (`agent_routines` -> `signal_bindings`
    # -> `cron_schedules`), then read and lock its current bindings and child
    # crons so concurrent child additions cannot be missed by parent updates.
    case lock_routine_in_tx(routine_id) do
      nil ->
        {:error, :routine_not_found}

      %AgentRoutine{} = routine ->
        crons_snapshot =
          CronSchedule
          |> Ash.Query.filter(owner_routine_id == ^routine_id)
          |> Ash.Query.sort(id: :asc)
          |> read_all()

        cron_refs = Enum.map(crons_snapshot, &"schedule://#{&1.id}")
        bindings_snapshot = Ankole.Signals.bindings_for_routine(routine_id, cron_refs)

        binding_ids = Enum.map(bindings_snapshot, & &1.id)
        bindings = Ankole.Signals.lock_bindings_in_tx(binding_ids)

        cron_ids = Enum.map(crons_snapshot, & &1.id)

        crons =
          if cron_ids == [] do
            []
          else
            CronSchedule
            |> Ash.Query.filter(id in ^cron_ids)
            |> Ash.Query.sort(id: :asc)
            |> Ash.Query.lock(:for_update)
            |> Ankole.Ash.read!(lock_identity: {"cron_schedules", cron_ids})
          end

        {:ok, routine, bindings, crons}
    end
  end

  defp normalize_routine_create_attrs(attrs, now, opts) do
    with {:ok, agent_uid} <- Attrs.required_text(attrs, "agent_uid"),
         {:ok, owner_session_id} <- Attrs.required_text(attrs, "owner_session_id"),
         :ok <- reject_reserved_owner_session(owner_session_id),
         binding_name = Attrs.map_text(attrs, "binding_name"),
         {:ok, name} <- Attrs.required_text(attrs, "name"),
         {:ok, task} <- resolve_routine_task(attrs),
         {:ok, idempotency_key} <- Attrs.required_text(attrs, "idempotency_key"),
         {:ok, delivery} <- Delivery.normalize(Attrs.map_value(attrs, "delivery"), binding_name),
         {:ok, status} <- normalize_status(Attrs.map_text(attrs, "status") || "active"),
         {:ok, cron_spec} <- normalize_optional_cron_spec(attrs, status, now, opts) do
      {:ok,
       %{
         status: status,
         agent_uid: agent_uid,
         owner_session_id: owner_session_id,
         binding_name: hd(delivery["targets"])["binding_name"],
         name: name,
         task: task,
         delivery: delivery,
         idempotency_key: idempotency_key,
         created_by: Keyword.get(opts, :created_by) || %{"kind" => "operator_api"},
         cron_spec: cron_spec
       }}
    end
  end

  defp resolve_routine_task(attrs) do
    task_candidate =
      case Attrs.map_text(attrs, "task") do
        nil -> get_in(Attrs.map_value(attrs, "payload") || %{}, ["task"])
        value -> value
      end

    case task_candidate do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :cron_task_required}, else: {:ok, trimmed}

      _ ->
        {:error, :cron_task_required}
    end
  end

  defp normalize_optional_cron_spec(attrs, status, now, opts) do
    case Attrs.map_value(attrs, "schedule") do
      nil ->
        {:ok, nil}

      schedule_input ->
        with {:ok, schedule, timezone} <-
               Planner.normalize_schedule_json(schedule_input, attrs, opts),
             {:ok, next_fire_at} <- Planner.next_fire_after(schedule, timezone, now),
             :ok <- reject_exhausted_bound(schedule, next_fire_at) do
          {:ok,
           %{
             schedule: schedule,
             timezone: timezone,
             next_fire_at: if(status == :active, do: next_fire_at, else: nil),
             payload: Map.put(Attrs.map_value(attrs, "payload") || %{}, "task", nil)
           }}
        end
    end
  end

  defp insert_routine_in_tx(normalized, _now, _opts) do
    id = Ash.UUIDv7.generate()

    routine_attrs =
      normalized
      |> Map.delete(:cron_spec)
      |> Map.put(:id, id)
      |> Map.put(:definition_version, 1)

    with {:ok, _attempted} <-
           Ankole.Ash.create(AgentRoutine, :create, routine_attrs, touch_update_defaults?: false),
         {:ok, routine} <- lock_by_idempotency(routine_attrs),
         {:ok, cron_schedule} <-
           maybe_insert_child_cron_in_tx(routine, normalized.cron_spec, routine.id == id) do
      status = if routine.id == id, do: :created, else: :already_exists
      {:ok, %{status: status, routine: routine, cron_schedule: cron_schedule}}
    end
  end

  defp maybe_insert_child_cron_in_tx(_routine, nil, _fresh?), do: {:ok, nil}

  defp maybe_insert_child_cron_in_tx(routine, _cron_spec, false) do
    existing =
      CronSchedule
      |> Ash.Query.filter(owner_routine_id == ^routine.id and status != :deleted)
      |> Ash.Query.sort(inserted_at: :asc)
      |> read_one()

    {:ok, existing}
  end

  defp maybe_insert_child_cron_in_tx(routine, cron_spec, true) do
    Cron.insert_routine_cron_in_tx(routine, cron_spec)
  end

  defp normalize_routine_update_attrs(routine, crons, attrs, now, opts) do
    active_cron = Enum.find(crons, &(&1.status != :deleted))

    with {:ok, name} <-
           if(Map.has_key?(attrs, "name"),
             do: Attrs.required_text(attrs, "name"),
             else: {:ok, nil}
           ),
         {:ok, task} <- normalize_updated_task(attrs),
         {:ok, delivery} <- normalize_updated_delivery(routine, attrs),
         {:ok, schedule_op} <-
           normalize_schedule_update_op(routine, active_cron, attrs, now, opts) do
      changes =
        %{}
        |> Attrs.maybe_put(:name, name)
        |> Attrs.maybe_put(:task, task)
        |> Attrs.maybe_put(:delivery, delivery)
        |> maybe_put_primary_binding(delivery)

      {:ok, changes, schedule_op}
    end
  end

  defp normalize_updated_task(attrs) do
    cond do
      Map.has_key?(attrs, "task") ->
        Attrs.required_text(attrs, "task")

      is_map(attrs["payload"]) and Map.has_key?(attrs["payload"], "task") ->
        Attrs.required_text(attrs["payload"], "task")

      true ->
        {:ok, nil}
    end
  end

  defp normalize_updated_delivery(routine, attrs) do
    case Map.fetch(attrs, "delivery") do
      {:ok, %{} = delivery} ->
        primary_binding =
          case delivery["targets"] do
            [%{"binding_name" => binding} | _] -> binding
            _ -> nil
          end

        Delivery.merge_update(
          routine.delivery,
          delivery,
          routine.binding_name || primary_binding
        )

      {:ok, invalid} ->
        Delivery.merge_update(routine.delivery, invalid, routine.binding_name)

      :error ->
        {:ok, nil}
    end
  end

  defp normalize_schedule_update_op(routine, active_cron, attrs, now, opts) do
    cond do
      Map.get(attrs, "remove_schedule") == true or
          (Map.has_key?(attrs, "schedule") and is_nil(attrs["schedule"])) ->
        if has_enabled_external_bindings?(routine.id) do
          {:ok, :remove}
        else
          {:error, :routine_trigger_required}
        end

      Map.has_key?(attrs, "schedule") or Map.has_key?(attrs, "timezone") ->
        schedule_input =
          case {Map.fetch(attrs, "schedule"), Map.fetch(attrs, "timezone"), active_cron} do
            {{:ok, schedule}, _, _} ->
              schedule

            {:error, {:ok, tz}, %CronSchedule{} = cron} ->
              Map.put(cron.schedule, "timezone", tz)

            {:error, {:ok, _tz}, nil} ->
              nil
          end

        if is_nil(schedule_input) do
          {:ok, :noop}
        else
          base = %{
            "timezone" => Map.get(attrs, "timezone") || (active_cron && active_cron.timezone)
          }

          with {:ok, schedule, timezone} <-
                 Planner.normalize_schedule_json(schedule_input, base, opts),
               {:ok, next_fire_at} <- Planner.next_fire_after(schedule, timezone, now),
               :ok <- reject_exhausted_bound(schedule, next_fire_at) do
            {:ok,
             {:upsert,
              %{
                schedule: schedule,
                timezone: timezone,
                next_fire_at: if(routine.status == :active, do: next_fire_at, else: nil)
              }}}
          end
        end

      not is_nil(active_cron) ->
        {:ok, :sync_metadata}

      true ->
        {:ok, :noop}
    end
  end

  defp apply_schedule_op_in_tx(_routine, _crons, :noop, _payload_extra, _now, _opts), do: :ok

  defp apply_schedule_op_in_tx(_routine, crons, :remove, _payload_extra, now, _opts) do
    live = Enum.filter(crons, &(&1.status != :deleted))

    with :ok <- delete_child_crons_in_tx(live),
         {:ok, _} <-
           cancel_pending_cron_fires_in_tx(Enum.map(live, & &1.id), now, "cron_schedule_deleted") do
      :ok
    end
  end

  defp apply_schedule_op_in_tx(routine, crons, :sync_metadata, payload_extra, _now, _opts) do
    case Enum.find(crons, &(&1.status != :deleted)) do
      nil ->
        :ok

      %CronSchedule{} = cron ->
        Cron.sync_child_cron_metadata_in_tx(cron, routine, payload_extra)
    end
  end

  defp apply_schedule_op_in_tx(routine, crons, {:upsert, cron_spec}, payload_extra, _now, _opts) do
    case Enum.find(crons, &(&1.status != :deleted)) do
      nil ->
        with {:ok, _cron} <-
               Cron.insert_routine_cron_in_tx(
                 routine,
                 Map.put(cron_spec, :payload, payload_extra)
               ),
             do: :ok

      %CronSchedule{} = cron ->
        Cron.update_child_cron_in_tx(cron, routine, cron_spec, payload_extra)
    end
  end

  defp pause_child_crons_in_tx(crons) do
    crons
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(&Ankole.Ash.update(&1, :pause, %{}))
    |> Attrs.collect_results()
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp resume_child_crons_in_tx(routine, crons, now) do
    crons
    |> Enum.filter(&(&1.status == :paused))
    |> Enum.reduce_while(:ok, fn cron, :ok ->
      case Cron.resume_locked_child_cron_in_tx(cron, routine, now) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp delete_child_crons_in_tx(crons) do
    crons
    |> Enum.filter(&(&1.status != :deleted))
    |> Enum.map(&Ankole.Ash.update(&1, :delete, %{}))
    |> Attrs.collect_results()
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp disable_external_bindings_in_tx(bindings) do
    Ankole.Signals.disable_external_bindings_in_tx(bindings)
  end

  defp cancel_pending_routine_events_in_tx(routine, crons, now, reason) do
    cron_ids = Enum.map(crons, & &1.id)
    session_id = execution_session_id(routine.id)
    agent_uid = routine.agent_uid

    query =
      if cron_ids == [] do
        Ash.Query.filter(
          ScheduledEvent,
          status == :scheduled and kind == "check_back_later" and agent_uid == ^agent_uid and
            session_id == ^session_id
        )
      else
        Ash.Query.filter(
          ScheduledEvent,
          status == :scheduled and
            ((kind == "cron_fire" and cron_schedule_id in ^cron_ids) or
               (kind == "check_back_later" and agent_uid == ^agent_uid and
                  session_id == ^session_id))
        )
      end

    Store.cancel_matching_in_tx(query, now, reason)
  end

  defp cancel_pending_routine_checkbacks_in_tx(routine, now, reason) do
    session_id = execution_session_id(routine.id)
    agent_uid = routine.agent_uid

    ScheduledEvent
    |> Ash.Query.filter(
      status == :scheduled and kind == "check_back_later" and agent_uid == ^agent_uid and
        session_id == ^session_id
    )
    |> Store.cancel_matching_in_tx(now, reason)
  end

  defp cancel_pending_cron_fires_in_tx([], _now, _reason), do: {:ok, []}

  defp cancel_pending_cron_fires_in_tx(cron_ids, now, reason) do
    ScheduledEvent
    |> Ash.Query.filter(
      status == :scheduled and kind == "cron_fire" and cron_schedule_id in ^cron_ids
    )
    |> Store.cancel_matching_in_tx(now, reason)
  end

  defp revoke_unstarted_routine_signals_in_tx(routine, now, reason) do
    session_id = execution_session_id(routine.id)
    :ok = Queue.lock_session_in_tx(routine.agent_uid, session_id)

    Ankole.Signals.cancel_unstarted_session_signals_in_tx(
      routine.agent_uid,
      session_id,
      now,
      reason
    )
  end

  @doc false
  def seal_open_coalesced_signals_in_tx(%AgentRoutine{} = routine, opts \\ []) do
    session_id = execution_session_id(routine.id)

    if Keyword.get(opts, :lock_session, true) do
      :ok = Queue.lock_session_in_tx(routine.agent_uid, session_id)
    end

    open =
      Ankole.Signals.lock_signals_in_tx(
        agent_uid: routine.agent_uid,
        session_id: session_id,
        status: :queued,
        last_attempt_at: [is_nil: true]
      )

    Enum.reduce_while(open, :ok, fn signal, :ok ->
      if is_map(get_in(signal.extensions || %{}, ["ankole_coalesce"])) and
           not Coalesce.sealed?(signal) do
        case Ankole.Signals.revise_input_signal(signal, %{
               extensions: Coalesce.seal_extensions(signal)
             }) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp end_routine_conversation_in_tx(%AgentRoutine{} = routine, now) do
    with {:ok, _} <-
           AIGateway.end_active_conversation_in_tx(
             routine.agent_uid,
             execution_session_id(routine.id),
             now
           ) do
      :ok
    end
  end

  defp has_enabled_external_bindings?(routine_id) do
    Ankole.Signals.routine_has_enabled_external_bindings?(routine_id)
  end

  defp has_active_child_crons?(routine_id) do
    CronSchedule
    |> Ash.Query.filter(owner_routine_id == ^routine_id and status == :active)
    |> Ankole.Ash.exists?()
  end

  defp has_live_child_crons_except?(routine_id, excluded_cron_id) do
    CronSchedule
    |> Ash.Query.filter(
      owner_routine_id == ^routine_id and id != ^excluded_cron_id and
        status in [:active, :paused]
    )
    |> Ankole.Ash.exists?()
  end

  defp has_live_triggers_except_cron?(routine_id, excluded_cron_id) do
    has_enabled_external_bindings?(routine_id) or
      has_non_deleted_child_crons_except?(routine_id, excluded_cron_id)
  end

  defp has_non_deleted_child_crons_except?(routine_id, nil) do
    CronSchedule
    |> Ash.Query.filter(owner_routine_id == ^routine_id and status != :deleted)
    |> Ankole.Ash.exists?()
  end

  defp has_non_deleted_child_crons_except?(routine_id, excluded_cron_id) do
    CronSchedule
    |> Ash.Query.filter(
      owner_routine_id == ^routine_id and id != ^excluded_cron_id and status != :deleted
    )
    |> Ankole.Ash.exists?()
  end

  defp validate_native_delivery_in_tx(agent_uid, delivery) do
    Enum.reduce_while(delivery["targets"] || [], :ok, fn target, :ok ->
      case StatementTarget.for_delivery_in_tx(agent_uid, target) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp maybe_put_task_from_payload(changes, %{"task" => task}) when is_binary(task) do
    trimmed = String.trim(task)
    if trimmed == "", do: changes, else: Map.put(changes, :task, trimmed)
  end

  defp maybe_put_task_from_payload(changes, _), do: changes

  defp maybe_put_primary_binding(changes, nil), do: changes

  defp maybe_put_primary_binding(changes, delivery),
    do: Map.put(changes, :binding_name, hd(delivery["targets"])["binding_name"])

  defp put_routine_status(%AgentRoutine{status: status} = routine, status),
    do: {:ok, routine}

  defp put_routine_status(%AgentRoutine{status: :completed} = routine, :active),
    do: Ankole.Ash.update(routine, :reactivate, %{})

  defp put_routine_status(routine, status) do
    action = %{active: :resume, paused: :pause, deleted: :delete, completed: :complete}[status]
    Ankole.Ash.update(routine, action, %{})
  end

  defp reject_terminal(%AgentRoutine{status: :deleted}), do: {:error, :routine_deleted}
  defp reject_terminal(%AgentRoutine{status: :completed}), do: {:error, :routine_completed}
  defp reject_terminal(%AgentRoutine{}), do: :ok

  defp reject_reserved_owner_session(owner_session_id) do
    if match?({:routine, _}, Key.parse(owner_session_id)),
      do: {:error, :cron_owner_session_reserved},
      else: :ok
  end

  defp reject_exhausted_bound(schedule, %DateTime{} = first_fire_at) do
    case Planner.occurrences_bound(schedule) do
      {:until, until} ->
        if DateTime.compare(first_fire_at, until) == :gt,
          do: {:error, :schedule_occurrences_exhausted},
          else: :ok

      _ ->
        :ok
    end
  end

  defp normalize_status("active"), do: {:ok, :active}
  defp normalize_status("paused"), do: {:ok, :paused}
  defp normalize_status(_), do: {:error, :invalid_cron_status}

  defp manual_request_id(opts) do
    case Keyword.get(opts, :tool_call_id) || Keyword.get(opts, :idempotency_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_text, :tool_call_id}}
          request_id -> {:ok, request_id}
        end

      _ ->
        {:error, {:missing_text, :tool_call_id}}
    end
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) when is_binary(agent_uid) do
    agent_uid = String.downcase(agent_uid)
    Ash.Query.filter(query, agent_uid == ^agent_uid)
  end

  defp maybe_where_owner_session(query, nil), do: query

  defp maybe_where_owner_session(query, owner_session_id),
    do: Ash.Query.filter(query, owner_session_id == ^owner_session_id)

  defp read_one(query, opts \\ []) do
    {:ok, record} = Ankole.Ash.read_one(query, opts)
    record
  end

  defp read_all(query) do
    {:ok, records} = Ankole.Ash.read(query)
    records
  end
end
