defmodule Ankole.Schedule.Cron do
  @moduledoc false

  require Ash.Query

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIGateway
  alias Ankole.AutomationJobs
  alias Ankole.Principals.WorkAccess
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Delivery
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Routines
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store
  alias Ankole.Schedule.Jobs.FireCron

  @doc """
  Builds the durable execution session id for one cron schedule or routine.

  Every fire of a routine's schedule runs in `routine:<routine_id>`, so all
  triggers of that routine stay serialized and share bounded conversation
  history, while the owner conversation and other routines run concurrently.
  """
  @spec execution_session_id(CronSchedule.t() | Ecto.UUID.t()) :: String.t()
  def execution_session_id(%CronSchedule{owner_routine_id: routine_id, id: id}),
    do: Ankole.Sessions.Key.routine(routine_id || id)

  def execution_session_id(cron_schedule_id) when is_binary(cron_schedule_id) do
    case Store.get_cron_schedule(cron_schedule_id) do
      %CronSchedule{owner_routine_id: routine_id} when is_binary(routine_id) ->
        Ankole.Sessions.Key.routine(routine_id)

      _ ->
        Ankole.Sessions.Key.routine(cron_schedule_id)
    end
  end

  @doc "The raw prefix, only for storage-boundary prefix matching."
  @spec execution_session_prefix() :: String.t()
  def execution_session_prefix, do: Ankole.Sessions.Key.routine("")

  @spec create_cron_schedule_in_tx(map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  def create_cron_schedule_in_tx(attrs, opts) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, attrs} <- Normalizer.cron_schedule_attrs(attrs, now, opts) do
      attrs =
        case Keyword.fetch(opts, :authorization) do
          {:ok, authorization} -> WorkAccess.merge(attrs, authorization)
          :error -> WorkAccess.inherit(attrs)
        end

      with :ok <- WorkAccess.check_attrs_in_tx(attrs),
           :ok <- validate_native_delivery_in_tx(attrs.agent_uid, attrs.delivery),
           :ok <-
             AutomationJobs.authorize_bindable_in_tx(
               attrs.agent_uid,
               attrs.automation_job_id
             ) do
        insert_cron_schedule_in_tx(attrs)
      end
    end
  end

  def create_job_schedule_in_tx(attrs, job, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, attrs} <- Normalizer.job_schedule_attrs(attrs, job, now, opts),
         do: insert_cron_schedule_in_tx(attrs)
  end

  defp validate_native_delivery_in_tx(nil, nil), do: :ok

  defp validate_native_delivery_in_tx(agent_uid, delivery) do
    Enum.reduce_while(delivery["targets"], :ok, fn target, :ok ->
      case StatementTarget.for_delivery_in_tx(agent_uid, target) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec update_cron_schedule_in_tx(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule_in_tx(cron_schedule_id, attrs, opts)
      when is_binary(cron_schedule_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %CronSchedule{} = snapshot <- Store.get_cron_schedule(cron_schedule_id),
         {:ok, job_id} <- Normalizer.automation_job_id(attrs),
         %CronSchedule{} = schedule <-
           Store.lock_cron_schedule(cron_schedule_id, job_id),
         true <- schedule.agent_uid == snapshot.agent_uid,
         :ok <- AutomationJobs.authorize_bindable_in_tx(schedule.agent_uid, job_id),
         :ok <- Store.reject_terminal(schedule),
         {:ok, attrs} <- Normalizer.cron_schedule_update_attrs(schedule, attrs, now, opts),
         :ok <-
           validate_native_delivery_in_tx(
             schedule.agent_uid,
             attrs[:delivery] || schedule.delivery
           ),
         {:ok, next_routine_id} <- Routines.resolve_routine_for_cron_update_in_tx(schedule, attrs),
         :ok <- maybe_update_binding(schedule, attrs, next_routine_id),
         update_attrs =
           attrs
           |> Map.delete(:automation_job_id)
           |> maybe_put_owner_routine_id(schedule, next_routine_id),
         changeset =
           Ankole.Ash.for_update(
             schedule,
             :update_definition,
             update_attrs
           ),
         recurrence_changed? =
           Ash.Changeset.changing_attribute?(changeset, :schedule) or
             Ash.Changeset.changing_attribute?(changeset, :timezone),
         task_context_changed? =
           Ash.Changeset.changing_attribute?(changeset, :payload) or
             Ash.Changeset.changing_attribute?(changeset, :delivery),
         {:ok, updated} <- Ankole.Ash.update(changeset),
         :ok <-
           Routines.sync_from_cron_update_in_tx(
             schedule.owner_routine_id,
             Map.put(attrs, :detached_cron_id, schedule.id),
             now
           ),
         :ok <-
           maybe_end_execution_conversation_in_tx(updated, task_context_changed?, now),
         {:ok, updated} <-
           sync_after_update_in_tx(updated, recurrence_changed?, now, opts),
         :ok <-
           if(
             task_context_changed? and is_binary(updated.owner_routine_id) and
               not Keyword.get(opts, :defer_signal_revoke, false),
             do:
               case Routines.get_routine_record(updated.owner_routine_id) do
                 nil -> :ok
                 routine -> Routines.seal_open_coalesced_signals_in_tx(routine)
               end,
             else: :ok
           ) do
      {:ok, updated}
    else
      nil -> {:error, :cron_schedule_not_found}
      false -> {:error, :cron_schedule_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec pause_cron_schedule_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def pause_cron_schedule_in_tx(cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    with {:ok, schedule, _revocations} <-
           pause_cron_schedule_with_revocations_in_tx(cron_schedule_id, opts) do
      {:ok, schedule}
    end
  end

  @doc false
  def pause_cron_schedule_with_revocations_in_tx(cron_schedule_id, opts \\ [])
      when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(cron_schedule_id),
         :ok <- Store.reject_terminal(schedule),
         {:ok, schedule} <- put_schedule_status(schedule, :paused),
         {:ok, revocations} <-
           Routines.sync_after_cron_pause_in_tx(schedule.owner_routine_id, now, opts) do
      {:ok, schedule, revocations}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec resume_cron_schedule_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def resume_cron_schedule_in_tx(cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <-
           Ankole.Principals.WorkAccess.check_record_in_tx(CronSchedule, cron_schedule_id) do
      case Store.lock_cron_schedule(cron_schedule_id) do
        %CronSchedule{status: :paused} = schedule ->
          resume_paused_in_tx(schedule, now, opts)

        %CronSchedule{status: :active} = schedule ->
          with :ok <-
                 Normalizer.validate_cron_task(
                   schedule.payload,
                   Ankole.Signals.source_routing_mode(schedule)
                 ),
               :ok <- Routines.sync_after_cron_resume_in_tx(schedule.owner_routine_id),
               :ok <- schedule_wake_in_tx(schedule) do
            {:ok, schedule}
          end

        %CronSchedule{status: :completed} ->
          {:error, :cron_schedule_completed}

        %CronSchedule{status: :deleted} ->
          {:error, :cron_schedule_deleted}

        nil ->
          {:error, :cron_schedule_not_found}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp resume_paused_in_tx(schedule, now, _opts) do
    with :ok <-
           Normalizer.validate_cron_task(
             schedule.payload,
             Ankole.Signals.source_routing_mode(schedule)
           ),
         {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      # A bound that ran out while the schedule was paused makes resume
      # complete it: that is the schedule's true state, not an error.
      if bound_spent?(schedule, next_fire_at) do
        complete_schedule_in_tx(schedule, now)
      else
        with {:ok, schedule} <- put_schedule_status(schedule, :active),
             :ok <- Routines.sync_after_cron_resume_in_tx(schedule.owner_routine_id) do
          schedule_next_fire_in_tx(schedule, next_fire_at)
        end
      end
    end
  end

  @spec remove_cron_schedule_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule_in_tx(cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    with {:ok, schedule, _revocations} <-
           remove_cron_schedule_with_revocations_in_tx(cron_schedule_id, opts) do
      {:ok, schedule}
    end
  end

  @doc false
  def remove_cron_schedule_with_revocations_in_tx(cron_schedule_id, opts \\ [])
      when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(cron_schedule_id),
         {:ok, schedule} <- put_schedule_status(schedule, :deleted),
         {:ok, _events} <- Store.cancel_pending_cron_events(schedule, now),
         {:ok, revocations} <-
           if(schedule.owner_routine_id,
             do:
               Routines.sync_after_cron_remove_in_tx(
                 schedule.owner_routine_id,
                 schedule.id,
                 now,
                 opts
               ),
             else: with(:ok <- end_execution_conversation_in_tx(schedule, now), do: {:ok, []})
           ) do
      {:ok, schedule, revocations}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec run_cron_schedule_in_tx(Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def run_cron_schedule_in_tx(cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- Ankole.Tenants.check_work_admission(Ankole.Repo.tenant_id!()),
         :ok <-
           Ankole.Principals.WorkAccess.check_record_in_tx(CronSchedule, cron_schedule_id),
         %CronSchedule{} = schedule <- Store.lock_cron_schedule(cron_schedule_id),
         :ok <- Store.reject_terminal(schedule),
         {:ok, request_id} <- manual_request_id(opts),
         {:ok, result} <- run_locked_cron_schedule_in_tx(schedule, request_id, now, opts) do
      {:ok, result}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def run_locked_cron_schedule_in_tx(schedule, request_id, now, opts) do
    with :ok <-
           Normalizer.validate_cron_task(
             schedule.payload,
             Ankole.Signals.source_routing_mode(schedule)
           ) do
      arm_manual_cron_fire_in_tx(schedule, request_id, now, opts)
    end
  end

  @doc false
  # The administrator is the audit actor; the selected Agent runs this service work.
  def console_create_in_tx(args, %Ankole.Principals.Principal{} = actor) do
    created_by = %{
      "kind" => "operator_api",
      "principal_uid" => actor |> Ankole.ActorRef.from_principal() |> to_string()
    }

    case create_cron_schedule_in_tx(args,
           created_by: created_by,
           authorization: WorkAccess.service()
         ) do
      {:ok, %{cron_schedule: schedule}} -> {:ok, console_result(schedule)}
      error -> Ankole.Errors.not_found(error, [:not_found], CronSchedule)
    end
  end

  @doc false
  def console_update_in_tx(args),
    do:
      for_agent(
        args,
        &update_cron_schedule_in_tx(&1, Map.drop(args, [:agent_uid, :id]), [])
      )

  @doc false
  def console_pause_in_tx(args),
    do: for_agent(args, &pause_cron_schedule_in_tx(&1, []))

  @doc false
  def console_resume_in_tx(args),
    do: for_agent(args, &resume_cron_schedule_in_tx(&1, []))

  @doc false
  def console_remove_in_tx(args),
    do: for_agent(args, &remove_cron_schedule_in_tx(&1, []))

  @doc false
  def console_run_in_tx(args) do
    for_agent(args, fn id ->
      with {:ok, %{scheduled_event: event}} <-
             run_cron_schedule_in_tx(id, idempotency_key: args.idempotency_key) do
        {:ok, event}
      end
    end)
  end

  # The Console addresses a schedule through its Agent. The schedule of another
  # Agent reads as not found.
  defp for_agent(%{agent_uid: agent_uid, id: id}, operation) do
    case Store.get_cron_schedule(id) do
      %CronSchedule{agent_uid: ^agent_uid} ->
        case operation.(id) do
          {:ok, %CronSchedule{} = schedule} ->
            {:ok, console_result(schedule)}

          result ->
            Ankole.Errors.not_found(result, [:cron_schedule_not_found, :not_found], CronSchedule)
        end

      _other ->
        {:error, Ankole.Errors.Invalid.NotFound.exception(resource: CronSchedule, id: id)}
    end
  end

  defp console_result(schedule),
    do: Ankole.Ash.load!(schedule, [:execution_session_id])

  @spec validate_fire_schedule(CronSchedule.t()) :: :ok | {:cancel, atom()}
  def validate_fire_schedule(%CronSchedule{status: status} = schedule)
      when status in [:active, :paused], do: validate_fire_preconditions(schedule)

  def validate_fire_schedule(%CronSchedule{}), do: {:cancel, :cron_schedule_not_active}

  # A schedule that cannot say what to run, or where to deliver the result, is
  # cancelled rather than fired. Both are durable facts of the stored row, so a
  # later attempt cannot clear them.
  defp validate_fire_preconditions(%CronSchedule{} = schedule) do
    with :ok <- validate_fire_task(schedule),
         {:ok, _primary_target} <- primary_delivery_target(schedule) do
      :ok
    else
      {:cancel, _reason} = cancel -> cancel
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp validate_fire_task(%CronSchedule{} = schedule) do
    case Normalizer.validate_cron_task(
           schedule.payload,
           Ankole.Signals.source_routing_mode(schedule)
         ) do
      :ok -> :ok
      {:error, reason} -> {:cancel, reason}
    end
  end

  # Manual requests and fire validation use the same stored delivery route.
  defp primary_delivery_target(%CronSchedule{owner_job_id: id}) when is_integer(id),
    do: {:ok, %{}}

  defp primary_delivery_target(%CronSchedule{} = schedule),
    do: Delivery.primary_target(schedule.delivery || %{}, schedule.binding_name)

  @doc false
  def advance_after_fire(%CronSchedule{} = schedule, slot_at, now) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
         {:ok, schedule} <-
           schedule
           |> Ankole.Ash.update(:record_fire, %{last_fire_at: slot_at}) do
      advance_within_bound(schedule, next_fire_at, now)
    end
  end

  @doc false
  def advance_after_terminal_failure(%CronSchedule{} = schedule, now) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      advance_within_bound(schedule, next_fire_at, now)
    end
  end

  # Arms the next slot, or completes the schedule when the occurrence bound is
  # spent. The bound counts due slots, so the check runs after the current
  # slot's event row reached a consumed status.
  defp advance_within_bound(
         %CronSchedule{} = schedule,
         %DateTime{} = next_fire_at,
         now
       ) do
    if bound_spent?(schedule, next_fire_at) do
      complete_schedule_in_tx(schedule, now)
    else
      schedule_next_fire_in_tx(schedule, next_fire_at)
    end
  end

  # Whether the recurrence must not arm the next slot: the count budget is used
  # up by consumed slots, or the next occurrence falls past the inclusive
  # cutoff. Unbounded schedules never spend out.
  defp bound_spent?(%CronSchedule{} = schedule, %DateTime{} = next_fire_at) do
    case Planner.occurrences_bound(schedule.schedule) do
      {:count, count} -> Store.count_consumed_cron_slots(schedule.id) >= count
      {:until, until} -> DateTime.compare(next_fire_at, until) == :gt
      nil -> false
    end
  end

  defp complete_schedule_in_tx(schedule, now) do
    with {:ok, schedule} <- put_schedule_status(schedule, :completed),
         :ok <-
           if(schedule.owner_routine_id,
             do:
               Routines.maybe_complete_after_cron_exhausted_in_tx(
                 schedule.owner_routine_id,
                 schedule.id,
                 now
               ),
             else: end_execution_conversation_in_tx(schedule, now)
           ) do
      {:ok, schedule}
    end
  end

  defp maybe_end_execution_conversation_in_tx(_schedule, false, _now), do: :ok

  defp maybe_end_execution_conversation_in_tx(schedule, true, now),
    do: end_execution_conversation_in_tx(schedule, now)

  defp end_execution_conversation_in_tx(%CronSchedule{owner_job_id: id}, _now)
       when is_integer(id), do: :ok

  defp end_execution_conversation_in_tx(%CronSchedule{} = schedule, now) do
    with {:ok, _conversation} <-
           AIGateway.end_active_conversation_in_tx(
             schedule.agent_uid,
             execution_session_id(schedule),
             now
           ) do
      :ok
    end
  end

  defp schedule_next_fire_in_tx(%CronSchedule{} = schedule, next_fire_at) do
    with {:ok, schedule} <- put_next_fire_at(schedule, next_fire_at),
         :ok <- schedule_wake_in_tx(schedule) do
      {:ok, schedule}
    end
  end

  defp schedule_wake_in_tx(%CronSchedule{status: :active} = schedule) do
    Ankole.Job.schedule_in_tx(
      FireCron,
      %{"cron_schedule_id" => schedule.id},
      schedule.next_fire_at
    )
  end

  defp schedule_wake_in_tx(%CronSchedule{}), do: :ok

  defp maybe_put_owner_routine_id(attrs, schedule, next_routine_id) do
    if schedule.owner_routine_id != next_routine_id,
      do: Map.put(attrs, :owner_routine_id, next_routine_id),
      else: attrs
  end

  defp maybe_update_binding(schedule, attrs, next_routine_id) do
    if Map.has_key?(attrs, :automation_job_id) do
      session_id = Ankole.Sessions.Key.routine(next_routine_id || schedule.id)

      Ankole.Signals.put_source_binding_in_tx(
        "schedule://#{schedule.id}",
        schedule.agent_uid,
        session_id,
        attrs.automation_job_id,
        next_routine_id
      )
    else
      :ok
    end
  end

  defp insert_cron_schedule_in_tx(attrs) do
    attempted_id = Ash.UUIDv7.generate()
    attrs = Map.put(attrs, :id, attempted_id)

    with {:ok, attrs} <- maybe_upsert_owning_routine_in_tx(attrs),
         {:ok, _attempted} <-
           Ankole.Ash.create(
             CronSchedule,
             if(attrs[:owner_job_id], do: :create_job, else: :create),
             Map.delete(attrs, :automation_job_id),
             touch_update_defaults?: false
           ),
         {:ok, persisted} <- Store.lock_cron_by_idempotency(attrs),
         fresh? = persisted.id == attempted_id,
         :ok <-
           if(fresh?,
             do:
               Ankole.Signals.put_source_binding_in_tx(
                 "schedule://#{persisted.id}",
                 persisted.agent_uid,
                 execution_session_id(persisted),
                 attrs.automation_job_id,
                 persisted.owner_routine_id
               ),
             else: :ok
           ),
         :ok <- schedule_wake_in_tx(persisted) do
      status = if fresh?, do: :created, else: :already_exists
      {:ok, %{status: status, cron_schedule: persisted}}
    end
  end

  defp maybe_upsert_owning_routine_in_tx(%{owner_job_id: job_id} = attrs)
       when is_integer(job_id),
       do: {:ok, attrs}

  defp maybe_upsert_owning_routine_in_tx(%{automation_job_id: job_id} = attrs)
       when is_integer(job_id),
       do: {:ok, attrs}

  defp maybe_upsert_owning_routine_in_tx(%{owner_routine_id: routine_id} = attrs)
       when is_binary(routine_id) do
    case Routines.lock_routine_in_tx(routine_id) do
      nil ->
        {:error, :routine_not_found}

      %{status: :deleted} ->
        {:error, :routine_deleted}

      routine ->
        payload = Map.put(attrs[:payload] || %{}, "task", routine.task)

        {:ok,
         Map.merge(attrs, %{
           name: routine.name,
           binding_name: routine.binding_name,
           payload: payload,
           delivery: routine.delivery
         })}
    end
  end

  defp maybe_upsert_owning_routine_in_tx(attrs) do
    with {:ok, routine} <- Routines.upsert_for_cron_in_tx(attrs) do
      {:ok, Map.merge(attrs, %{id: routine.id, owner_routine_id: routine.id})}
    end
  end

  @doc false
  def insert_routine_cron_in_tx(routine, cron_spec) do
    cron_id =
      if is_nil(Store.get_cron_schedule(routine.id)),
        do: routine.id,
        else: Ash.UUIDv7.generate()

    status = if routine.status == :paused, do: :paused, else: :active

    attrs = %{
      id: cron_id,
      authorization_kind: routine.authorization_kind,
      human_uid: routine.human_uid,
      human_access_version: routine.human_access_version,
      status: status,
      agent_uid: routine.agent_uid,
      owner_session_id: routine.owner_session_id,
      owner_routine_id: routine.id,
      binding_name: routine.binding_name,
      name: routine.name,
      schedule: cron_spec.schedule,
      timezone: cron_spec.timezone,
      payload: %{"task" => routine.task},
      delivery: routine.delivery,
      next_fire_at: cron_spec.next_fire_at,
      idempotency_key: "routine-cron:#{routine.id}:#{cron_id}",
      created_by: routine.created_by || %{}
    }

    with {:ok, persisted} <-
           Ankole.Ash.create(CronSchedule, :create, attrs, touch_update_defaults?: false),
         :ok <-
           Ankole.Signals.put_source_binding_in_tx(
             "schedule://#{persisted.id}",
             persisted.agent_uid,
             execution_session_id(persisted),
             nil,
             routine.id
           ),
         :ok <- schedule_wake_in_tx(persisted) do
      {:ok, persisted}
    end
  end

  @doc false
  def sync_child_cron_metadata_in_tx(cron, routine, payload_extra \\ %{}) do
    changes = %{
      name: routine.name,
      binding_name: routine.binding_name,
      delivery: routine.delivery,
      payload:
        (cron.payload || %{})
        |> Map.merge(payload_extra)
        |> Map.put("task", routine.task)
    }

    with {:ok, _} <- Ankole.Ash.update(cron, :update_definition, changes), do: :ok
  end

  @doc false
  def update_child_cron_in_tx(cron, routine, cron_spec, payload_extra \\ %{}) do
    changes = %{
      name: routine.name,
      binding_name: routine.binding_name,
      delivery: routine.delivery,
      payload:
        (cron.payload || %{})
        |> Map.merge(payload_extra)
        |> Map.put("task", routine.task),
      schedule: cron_spec.schedule,
      timezone: cron_spec.timezone
    }

    with {:ok, cron} <- Ankole.Ash.update(cron, :update_definition, changes),
         {:ok, cron} <-
           if(cron.status == :completed and routine.status == :active,
             do: Ankole.Ash.update(cron, :reactivate, %{}),
             else: {:ok, cron}
           ),
         {:ok, _cron} <-
           if(cron.status == :active and not is_nil(cron_spec.next_fire_at),
             do: schedule_next_fire_in_tx(cron, cron_spec.next_fire_at),
             else: {:ok, cron}
           ) do
      :ok
    end
  end

  @doc false
  def resume_locked_child_cron_in_tx(cron, _routine, now) do
    resume_paused_in_tx(cron, now, [])
  end

  defp sync_after_update_in_tx(%CronSchedule{status: :active} = schedule, true, now, _opts) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      if bound_spent?(schedule, next_fire_at) do
        {:error, :schedule_occurrences_exhausted}
      else
        schedule_next_fire_in_tx(schedule, next_fire_at)
      end
    end
  end

  defp sync_after_update_in_tx(
         %CronSchedule{status: :active} = schedule,
         false,
         _now,
         _opts
       ) do
    with :ok <- schedule_wake_in_tx(schedule), do: {:ok, schedule}
  end

  defp sync_after_update_in_tx(%CronSchedule{} = schedule, _changed, _now, _opts),
    do: {:ok, schedule}

  defp arm_manual_cron_fire_in_tx(schedule, request_id, now, opts) do
    with {:ok, attrs} <-
           event_attrs(
             schedule,
             now,
             now,
             now,
             "manual",
             Store.cron_manual_idempotency_key(schedule.id, request_id),
             request_id
           ) do
      Store.insert_idempotent_event_and_wake_in_tx(attrs, opts)
    end
  end

  @doc false
  def event_attrs(schedule, slot_at, due_at, now, trigger, idempotency_key, tool_call_id) do
    with {:ok, primary_target} <- primary_delivery_target(schedule) do
      {:ok,
       event_attrs(
         schedule,
         primary_target,
         slot_at,
         due_at,
         now,
         trigger,
         idempotency_key,
         tool_call_id
       )}
    end
  end

  @doc false
  def event_attrs(
        schedule,
        primary_target,
        slot_at,
        due_at,
        now,
        trigger,
        idempotency_key,
        tool_call_id
      ) do
    %{
      authorization_kind: schedule.authorization_kind,
      human_uid: schedule.human_uid,
      human_access_version: schedule.human_access_version,
      kind: "cron_fire",
      agent_uid: schedule.agent_uid,
      session_id: if(schedule.owner_job_id, do: nil, else: execution_session_id(schedule)),
      binding_name: schedule.binding_name,
      conversation_id: primary_target["conversation_id"],
      provider_thread_id: primary_target["provider_thread_id"],
      due_at: due_at,
      timezone: schedule.timezone,
      requested_at: now,
      idempotency_key: idempotency_key,
      tool_call_id: tool_call_id,
      cron_schedule_id: schedule.id,
      cron_fire_slot_at: slot_at,
      origin_ai_message_id: Attrs.map_text(schedule.created_by || %{}, "origin_ai_message_id"),
      source_provenance: %{
        "cron_schedule_id" => schedule.id,
        "trigger" => trigger
      },
      wake_payload: wake_payload(schedule, slot_at, due_at, trigger),
      last_fire_error: %{}
    }
  end

  defp wake_payload(schedule, slot_at, due_at, trigger) do
    %{
      "trigger" => trigger,
      "cron_schedule_id" => schedule.id,
      "cron_schedule_name" => schedule.name,
      "cron_fire_slot_at" => DateTime.to_iso8601(slot_at),
      "due_at" => DateTime.to_iso8601(due_at),
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "delivery" => schedule.delivery || %{}
    }
  end

  defp put_schedule_status(%CronSchedule{status: status} = schedule, status),
    do: {:ok, schedule}

  defp put_schedule_status(schedule, status) do
    schedule
    |> Ankole.Ash.update(
      %{active: :resume, paused: :pause, deleted: :delete, completed: :complete}[status],
      %{}
    )
  end

  defp put_next_fire_at(schedule, %DateTime{} = next_fire_at) do
    case schedule.next_fire_at do
      %DateTime{} = current ->
        if same_datetime?(current, next_fire_at) do
          {:ok, schedule}
        else
          schedule
          |> Ankole.Ash.update(:schedule_fire, %{next_fire_at: next_fire_at})
        end

      _current ->
        schedule
        |> Ankole.Ash.update(:schedule_fire, %{next_fire_at: next_fire_at})
    end
  end

  defp manual_request_id(opts) do
    case Keyword.get(opts, :tool_call_id) || Keyword.get(opts, :idempotency_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_text, :tool_call_id}}
          request_id -> {:ok, request_id}
        end

      _value ->
        {:error, {:missing_text, :tool_call_id}}
    end
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  @doc "Pauses the active schedules of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(uid, version, _now) do
    {:ok, schedules} =
      CronSchedule
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status == :active
      )
      |> Ankole.Ash.update_where(:stop_human_work, %{})

    {length(schedules), nil}
  end

  def job_source_operation_in_tx(job, :list, _attrs) do
    CronSchedule
    |> Ash.Query.filter(owner_job_id == ^job.id and status != :deleted)
    |> Ash.Query.sort(name: :asc)
    |> Ankole.Ash.read()
  end

  def job_source_operation_in_tx(job, :put, attrs) do
    current =
      if attrs["id"] do
        Store.get_cron_schedule(attrs["id"])
      else
        CronSchedule
        |> Ash.Query.filter(
          owner_job_id == ^job.id and name == ^attrs["name"] and status != :deleted
        )
        |> Ankole.Ash.read_one!()
      end

    case current do
      nil when is_map_key(attrs, "id") ->
        {:error, :not_found}

      nil ->
        attrs = Map.put_new(attrs, "idempotency_key", Ash.UUIDv7.generate())

        with {:ok, %{cron_schedule: schedule}} <-
               create_job_schedule_in_tx(attrs, job, created_by: attrs["created_by"]),
             do: {:ok, schedule}

      %CronSchedule{owner_job_id: id} when id == job.id ->
        update_cron_schedule_in_tx(
          current.id,
          Map.take(attrs, ~w(name schedule timezone payload)),
          []
        )

      _ ->
        {:error, :not_found}
    end
  end

  def job_source_operation_in_tx(job, operation, %{"id" => id} = attrs) do
    with %CronSchedule{owner_job_id: owner} <- Store.get_cron_schedule(id),
         true <- owner == job.id do
      case operation do
        :pause -> pause_cron_schedule_in_tx(id, [])
        :resume -> resume_cron_schedule_in_tx(id, [])
        :delete -> remove_cron_schedule_in_tx(id, [])
        :run -> run_cron_schedule_in_tx(id, idempotency_key: attrs["idempotency_key"])
        :runs -> schedule_runs(id)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def job_source_operation_in_tx(_, _, _), do: {:error, :invalid_request}

  defp schedule_runs(id) do
    events =
      ScheduledEvent
      |> Ash.Query.filter(cron_schedule_id == ^id)
      |> Ash.Query.sort(due_at: :desc, id: :desc)
      |> Ash.Query.limit(100)
      |> Ankole.Ash.read!()

    receipts = Ankole.Signals.source_deliveries("schedule://#{id}")
    {:ok, %{events: events, deliveries: receipts}}
  end

  def job_source_ids(job_ids) do
    CronSchedule
    |> Ash.Query.filter(owner_job_id in ^job_ids)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  def purge_job_sources_in_tx(ids) do
    CronSchedule
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "cron_schedules", :id})

    with {:ok, _} <-
           ScheduledEvent
           |> Ash.Query.filter(cron_schedule_id in ^ids)
           |> Ankole.Ash.destroy_where(:remove),
         {:ok, _} <-
           CronSchedule |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.destroy_where(:remove),
         do: :ok
  end
end
