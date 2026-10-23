defmodule Ankole.Schedule.Cron do
  @moduledoc false

  require Ash.Query

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIGateway
  alias Ankole.AutomationJobs
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Delivery
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store
  alias Ankole.Schedule.Jobs.FireCron

  @doc """
  Builds the durable execution session id for one cron schedule.

  Every fire of one schedule runs in this stable session, so one schedule
  stays serialized and keeps its own bounded conversation history, while the
  owner conversation and other schedules run concurrently. The stored
  `owner_session_id` remains the management scope only.
  """
  @spec execution_session_id(Ecto.UUID.t()) :: String.t()
  def execution_session_id(cron_schedule_id) when is_binary(cron_schedule_id),
    do: Ankole.Sessions.Key.cron(cron_schedule_id)

  @doc "Returns the schedule id whose fires run in this session, or nil."
  @spec execution_schedule_id(String.t()) :: Ecto.UUID.t() | nil
  def execution_schedule_id(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:cron, id} -> id
      _ -> nil
    end
  end

  @doc "The raw prefix, only for storage-boundary prefix matching."
  @spec execution_session_prefix() :: String.t()
  def execution_session_prefix, do: Ankole.Sessions.Key.cron("")

  @spec create_cron_schedule_in_tx(module(), map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  def create_cron_schedule_in_tx(repo, attrs, opts) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, attrs} <- Normalizer.cron_schedule_attrs(attrs, now, opts) do
      attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

      with :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
           :ok <- validate_native_delivery_in_tx(repo, attrs.agent_uid, attrs.delivery),
           :ok <-
             AutomationJobs.validate_bindable_in_tx(
               repo,
               attrs.automation_job_id,
               attrs.agent_uid
             ) do
        insert_cron_schedule_in_tx(repo, attrs)
      end
    end
  end

  defp validate_native_delivery_in_tx(repo, agent_uid, delivery) do
    Enum.reduce_while(delivery["targets"], :ok, fn target, :ok ->
      case StatementTarget.for_delivery_in_tx(repo, agent_uid, target) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec update_cron_schedule_in_tx(module(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule_in_tx(repo, cron_schedule_id, attrs, opts)
      when is_binary(cron_schedule_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %CronSchedule{} = snapshot <- Store.get_cron_schedule(cron_schedule_id),
         {:ok, job_id} <- Normalizer.automation_job_id(attrs),
         :ok <- AutomationJobs.validate_bindable_in_tx(repo, job_id, snapshot.agent_uid),
         %CronSchedule{} = schedule <-
           Store.lock_cron_schedule(repo, cron_schedule_id, job_id),
         true <- schedule.agent_uid == snapshot.agent_uid,
         :ok <- Store.reject_terminal(schedule),
         {:ok, attrs} <- Normalizer.cron_schedule_update_attrs(schedule, attrs, now, opts),
         :ok <-
           validate_native_delivery_in_tx(
             repo,
             schedule.agent_uid,
             attrs[:delivery] || schedule.delivery
           ),
         changeset = Ankole.Ash.for_update(schedule, :update_definition, attrs),
         recurrence_changed? =
           Ash.Changeset.changing_attribute?(changeset, :schedule) or
             Ash.Changeset.changing_attribute?(changeset, :timezone),
         task_context_changed? =
           Ash.Changeset.changing_attribute?(changeset, :payload) or
             Ash.Changeset.changing_attribute?(changeset, :delivery),
         {:ok, schedule} <- Ankole.Ash.update(changeset),
         :ok <-
           maybe_end_execution_conversation_in_tx(repo, schedule, task_context_changed?, now),
         {:ok, schedule} <-
           sync_after_update_in_tx(repo, schedule, recurrence_changed?, now, opts) do
      {:ok, schedule}
    else
      nil -> {:error, :cron_schedule_not_found}
      false -> {:error, :cron_schedule_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec pause_cron_schedule_in_tx(module(), Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def pause_cron_schedule_in_tx(repo, cron_schedule_id, _opts) when is_binary(cron_schedule_id) do
    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
         :ok <- Store.reject_terminal(schedule),
         {:ok, schedule} <- put_schedule_status(repo, schedule, :paused) do
      {:ok, schedule}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec resume_cron_schedule_in_tx(module(), Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def resume_cron_schedule_in_tx(repo, cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <-
           Ankole.Principals.WorkAccess.check_record_in_tx(repo, CronSchedule, cron_schedule_id) do
      case Store.lock_cron_schedule(repo, cron_schedule_id) do
        %CronSchedule{status: :paused} = schedule ->
          resume_paused_in_tx(repo, schedule, now, opts)

        %CronSchedule{status: :active} = schedule ->
          with :ok <-
                 Normalizer.validate_cron_task(schedule.payload, schedule.automation_job_id),
               :ok <- schedule_wake_in_tx(repo, schedule) do
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

  defp resume_paused_in_tx(repo, schedule, now, _opts) do
    with :ok <-
           Normalizer.validate_cron_task(schedule.payload, schedule.automation_job_id),
         {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      # A bound that ran out while the schedule was paused makes resume
      # complete it: that is the schedule's true state, not an error.
      if bound_spent?(repo, schedule, next_fire_at) do
        complete_schedule_in_tx(repo, schedule, now)
      else
        with {:ok, schedule} <- put_schedule_status(repo, schedule, :active) do
          schedule_next_fire_in_tx(repo, schedule, next_fire_at)
        end
      end
    end
  end

  @spec remove_cron_schedule_in_tx(module(), Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule_in_tx(repo, cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
         {:ok, schedule} <- put_schedule_status(repo, schedule, :deleted),
         :ok <- end_execution_conversation_in_tx(repo, schedule, now),
         {:ok, _events} <- Store.cancel_pending_cron_events(repo, schedule, now) do
      {:ok, schedule}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec run_cron_schedule_in_tx(module(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def run_cron_schedule_in_tx(repo, cron_schedule_id, opts) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- Ankole.Tenants.check_work_admission(Ankole.Repo.tenant_id!()),
         :ok <-
           Ankole.Principals.WorkAccess.check_record_in_tx(repo, CronSchedule, cron_schedule_id),
         %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
         :ok <- Store.reject_terminal(schedule),
         :ok <- Normalizer.validate_cron_task(schedule.payload, schedule.automation_job_id),
         {:ok, request_id} <- manual_request_id(opts),
         {:ok, result} <- arm_manual_cron_fire_in_tx(repo, schedule, request_id, now, opts) do
      {:ok, result}
    else
      nil -> {:error, :cron_schedule_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # The Console creates a schedule for the Console Principal (the actor).
  def console_create_in_tx(repo, args, actor) do
    created_by =
      if actor,
        do: %{
          "kind" => "operator_api",
          "principal_uid" => actor |> Ankole.ActorRef.from_principal() |> to_string()
        },
        else: %{"kind" => "operator_api"}

    case create_cron_schedule_in_tx(repo, args, created_by: created_by) do
      {:ok, %{cron_schedule: schedule}} -> {:ok, console_result(schedule)}
      error -> Ankole.Errors.not_found(error, [:not_found], CronSchedule)
    end
  end

  @doc false
  def console_update_in_tx(repo, args),
    do:
      for_agent(
        args,
        &update_cron_schedule_in_tx(repo, &1, Map.drop(args, [:agent_uid, :id]), [])
      )

  @doc false
  def console_pause_in_tx(repo, args),
    do: for_agent(args, &pause_cron_schedule_in_tx(repo, &1, []))

  @doc false
  def console_resume_in_tx(repo, args),
    do: for_agent(args, &resume_cron_schedule_in_tx(repo, &1, []))

  @doc false
  def console_remove_in_tx(repo, args),
    do: for_agent(args, &remove_cron_schedule_in_tx(repo, &1, []))

  @doc false
  def console_run_in_tx(repo, args) do
    for_agent(args, fn id ->
      with {:ok, %{scheduled_event: event}} <-
             run_cron_schedule_in_tx(repo, id, idempotency_key: args.idempotency_key) do
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
    do:
      Ash.load!(schedule, [:execution_session_id],
        tenant: Ankole.Repo.tenant_id(),
        authorize?: false
      )

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
    case Normalizer.validate_cron_task(schedule.payload, schedule.automation_job_id) do
      :ok -> :ok
      {:error, reason} -> {:cancel, reason}
    end
  end

  # Manual requests and fire validation use the same stored delivery route.
  defp primary_delivery_target(%CronSchedule{} = schedule),
    do: Delivery.primary_target(schedule.delivery || %{}, schedule.binding_name)

  @doc false
  def advance_after_fire(repo, %CronSchedule{} = schedule, slot_at, now) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
         {:ok, schedule} <-
           schedule
           |> Ankole.Ash.update(:record_fire, %{last_fire_at: slot_at}) do
      advance_within_bound(repo, schedule, next_fire_at, now)
    end
  end

  @doc false
  def advance_after_terminal_failure(repo, %CronSchedule{} = schedule, now) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      advance_within_bound(repo, schedule, next_fire_at, now)
    end
  end

  # Arms the next slot, or completes the schedule when the occurrence bound is
  # spent. The bound counts due slots, so the check runs after the current
  # slot's event row reached a consumed status.
  defp advance_within_bound(
         repo,
         %CronSchedule{} = schedule,
         %DateTime{} = next_fire_at,
         now
       ) do
    if bound_spent?(repo, schedule, next_fire_at) do
      complete_schedule_in_tx(repo, schedule, now)
    else
      schedule_next_fire_in_tx(repo, schedule, next_fire_at)
    end
  end

  # Whether the recurrence must not arm the next slot: the count budget is used
  # up by consumed slots, or the next occurrence falls past the inclusive
  # cutoff. Unbounded schedules never spend out.
  defp bound_spent?(repo, %CronSchedule{} = schedule, %DateTime{} = next_fire_at) do
    case Planner.occurrences_bound(schedule.schedule) do
      {:count, count} -> Store.count_consumed_cron_slots(repo, schedule.id) >= count
      {:until, until} -> DateTime.compare(next_fire_at, until) == :gt
      nil -> false
    end
  end

  defp complete_schedule_in_tx(repo, schedule, now) do
    with {:ok, schedule} <- put_schedule_status(repo, schedule, :completed),
         :ok <- end_execution_conversation_in_tx(repo, schedule, now) do
      {:ok, schedule}
    end
  end

  defp maybe_end_execution_conversation_in_tx(_repo, _schedule, false, _now), do: :ok

  defp maybe_end_execution_conversation_in_tx(repo, schedule, true, now),
    do: end_execution_conversation_in_tx(repo, schedule, now)

  # The execution session's conversation carries the task history and the
  # delivery channel's origin (channel id, channel kind, and DM peer id),
  # set once when the conversation is created and never re-derived on
  # reuse. A changed payload makes that history a wrong prefix for the next
  # fire, and a changed delivery channel would leave the recorded origin
  # naming the old channel: a stale console label, not a functional
  # failure. Ending the conversation here makes the next fire start fresh,
  # with history and origin both matching the current schedule facts;
  # timing-only changes keep history. A fire running right now is
  # unaffected: turn completion resolves its conversation by id, not by
  # active lookup. A terminal schedule also ends its conversation so the
  # daily reset stops selecting the dead session.
  defp end_execution_conversation_in_tx(repo, %CronSchedule{} = schedule, now) do
    with {:ok, _conversation} <-
           AIGateway.end_active_conversation_in_tx(
             repo,
             schedule.agent_uid,
             execution_session_id(schedule.id),
             now
           ) do
      :ok
    end
  end

  defp schedule_next_fire_in_tx(repo, %CronSchedule{} = schedule, next_fire_at) do
    with {:ok, schedule} <- put_next_fire_at(repo, schedule, next_fire_at),
         :ok <- schedule_wake_in_tx(repo, schedule) do
      {:ok, schedule}
    end
  end

  defp schedule_wake_in_tx(repo, %CronSchedule{status: :active} = schedule) do
    Ankole.Job.schedule_in_tx(
      repo,
      FireCron,
      %{"cron_schedule_id" => schedule.id},
      schedule.next_fire_at
    )
  end

  defp schedule_wake_in_tx(_repo, %CronSchedule{}), do: :ok

  defp insert_cron_schedule_in_tx(repo, attrs) do
    attrs = Map.put(attrs, :id, Ankole.Kernel.gen_uuid_v7())

    with {:ok, _attempted} <-
           Ankole.Ash.create(CronSchedule, :create, attrs, touch_update_defaults?: false),
         {:ok, persisted} <- Store.lock_cron_by_idempotency(repo, attrs),
         :ok <- schedule_wake_in_tx(repo, persisted) do
      status = if attrs.id == persisted.id, do: :created, else: :already_exists
      {:ok, %{status: status, cron_schedule: persisted}}
    end
  end

  defp sync_after_update_in_tx(repo, %CronSchedule{status: :active} = schedule, true, now, _opts) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      if bound_spent?(repo, schedule, next_fire_at) do
        {:error, :schedule_occurrences_exhausted}
      else
        schedule_next_fire_in_tx(repo, schedule, next_fire_at)
      end
    end
  end

  defp sync_after_update_in_tx(
         repo,
         %CronSchedule{status: :active} = schedule,
         false,
         _now,
         _opts
       ) do
    with :ok <- schedule_wake_in_tx(repo, schedule), do: {:ok, schedule}
  end

  defp sync_after_update_in_tx(_repo, %CronSchedule{} = schedule, _changed, _now, _opts),
    do: {:ok, schedule}

  defp arm_manual_cron_fire_in_tx(repo, schedule, request_id, now, opts) do
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
      Store.insert_idempotent_event_and_wake_in_tx(repo, attrs, opts)
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
      session_id: execution_session_id(schedule.id),
      binding_name: schedule.binding_name,
      conversation_id: primary_target["conversation_id"],
      provider_thread_id: primary_target["provider_thread_id"],
      due_at: due_at,
      timezone: schedule.timezone,
      requested_at: now,
      idempotency_key: idempotency_key,
      tool_call_id: tool_call_id,
      cron_schedule_id: schedule.id,
      automation_job_id: schedule.automation_job_id,
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

  defp put_schedule_status(_repo, %CronSchedule{status: status} = schedule, status),
    do: {:ok, schedule}

  defp put_schedule_status(_repo, schedule, status) do
    schedule
    |> Ankole.Ash.update(
      %{active: :resume, paused: :pause, deleted: :delete, completed: :complete}[status],
      %{}
    )
  end

  defp put_next_fire_at(_repo, schedule, %DateTime{} = next_fire_at) do
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
  def stop_human_work_in_tx(_repo, uid, version, _now) do
    {:ok, schedules} =
      CronSchedule
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status == :active
      )
      |> Ankole.Ash.update_where(:stop_human_work, %{})

    {length(schedules), nil}
  end
end
