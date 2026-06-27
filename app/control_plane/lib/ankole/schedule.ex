defmodule Ankole.Schedule do
  @moduledoc """
  Control-plane schedule subsystem.

  Schedule owns durable time semantics. Oban jobs are wake edges; the domain
  tables and ActorInput idempotency are the correctness boundary.
  """

  import Ecto.Query, warn: false

  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.Jobs.FireScheduledEvent
  alias Ankole.Repo
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SystemConfig

  @min_delay_ms 1_000
  @max_horizon_ms 366 * 24 * 60 * 60 * 1_000
  @max_reason_length 2_000
  @max_check_length 4_000
  @max_context_summary_length 8_000

  @type create_result ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}

  @doc """
  Creates one delayed self-wakeup event.
  """
  @spec create_check_back_later(map(), keyword()) :: create_result()
  def create_check_back_later(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, attrs} <- normalize_checkback_attrs(attrs, now, opts),
           {:ok, result} <- insert_event_and_wake_in_tx(repo, attrs, opts) do
        {:ok, result}
      end
    end)
  end

  @doc """
  Creates one recurring cron schedule and arms its first concrete fire.
  """
  @spec create_cron_schedule(map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  def create_cron_schedule(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, attrs} <- normalize_cron_schedule_attrs(attrs, now, opts),
           {:ok, result} <- insert_cron_schedule_in_tx(repo, attrs, now, opts) do
        {:ok, result}
      end
    end)
  end

  @doc """
  Updates a cron schedule and re-arms the next active fire.
  """
  @spec update_cron_schedule(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule(cron_schedule_id, attrs, opts \\ [])
      when is_binary(cron_schedule_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- lock_cron_schedule(repo, cron_schedule_id),
           :ok <- reject_deleted(schedule),
           {:ok, attrs} <- normalize_cron_schedule_update_attrs(schedule, attrs, now, opts),
           {:ok, schedule} <- schedule |> CronSchedule.changeset(attrs) |> repo.update(),
           {:ok, _events} <- cancel_future_cron_events(repo, schedule, now),
           {:ok, schedule} <- maybe_arm_active_cron_in_tx(repo, schedule, now, opts) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Pauses a cron schedule and cancels future fires that have not materialized.
  """
  @spec pause_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def pause_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- lock_cron_schedule(repo, cron_schedule_id),
           :ok <- reject_deleted(schedule),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "paused", next_fire_at: nil})
             |> repo.update(),
           {:ok, _events} <- cancel_future_cron_events(repo, schedule, now) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Resumes a paused cron schedule from the resume time.
  """
  @spec resume_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def resume_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- lock_cron_schedule(repo, cron_schedule_id),
           :ok <- reject_deleted(schedule),
           {:ok, next_fire_at} <- next_fire_after(schedule.schedule, schedule.timezone, now),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "active", next_fire_at: next_fire_at})
             |> repo.update(),
           {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Marks a cron schedule deleted and cancels future fires.
  """
  @spec remove_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- lock_cron_schedule(repo, cron_schedule_id),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "deleted", next_fire_at: nil})
             |> repo.update(),
           {:ok, _events} <- cancel_future_cron_events(repo, schedule, now) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Creates an immediate manual cron fire without changing recurrence state.
  """
  @spec run_cron_schedule(Ecto.UUID.t(), keyword()) :: create_result()
  def run_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- lock_cron_schedule(repo, cron_schedule_id),
           :ok <- reject_deleted(schedule),
           slot_at <- Keyword.get(opts, :slot_at, now),
           {:ok, result} <-
             arm_cron_fire_in_tx(
               repo,
               schedule,
               slot_at,
               now,
               opts
               |> Keyword.put(:due_at, now)
               |> Keyword.put(:trigger, "manual")
             ) do
        {:ok, result}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Cancels one pending checkback event.
  """
  @spec cancel_checkback(Ecto.UUID.t(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback(scheduled_event_id, opts \\ []) when is_binary(scheduled_event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_scheduled_event(repo, scheduled_event_id) do
        %ScheduledEvent{kind: "check_back_later", status: "scheduled"} = event ->
          event
          |> ScheduledEvent.changeset(%{status: "cancelled", cancelled_at: now})
          |> repo.update()

        %ScheduledEvent{kind: "check_back_later"} = event ->
          {:ok, event}

        %ScheduledEvent{} ->
          {:error, :not_checkback}

        nil ->
          {:error, :scheduled_event_not_found}
      end
    end)
  end

  @doc false
  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  def cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, %DateTime{} = now)
      when is_map(attrs) do
    agent_uid = map_text(attrs, "agent_uid")
    session_id = map_text(attrs, "session_id")
    binding_name = map_text(attrs, "binding_name")
    provider_entry_id = map_text(attrs, "provider_entry_id")

    if Enum.all?([agent_uid, session_id, binding_name, provider_entry_id], &is_binary/1) do
      {count, _rows} =
        ScheduledEvent
        |> where([event], event.kind == "check_back_later")
        |> where([event], event.status == "scheduled")
        |> where([event], event.agent_uid == ^String.downcase(agent_uid))
        |> where([event], event.session_id == ^session_id)
        |> where([event], event.binding_name == ^binding_name)
        |> where([event], event.provider_entry_id == ^provider_entry_id)
        |> repo.update_all(
          set: [
            status: "cancelled",
            cancelled_at: now,
            last_fire_error: %{"reason" => "source_entry_tombstoned"},
            updated_at: now
          ]
        )

      {:ok, count}
    else
      {:ok, 0}
    end
  end

  @doc false
  @spec cancel_due_cron_events_for_reset_in_tx(module(), map(), DateTime.t(), DateTime.t()) ::
          {:ok, %{cancelled_events: non_neg_integer(), rearmed_schedules: non_neg_integer()}}
          | {:error, term()}
  def cancel_due_cron_events_for_reset_in_tx(
        repo,
        actor_key,
        %DateTime{} = reset_at,
        %DateTime{} = now
      )
      when is_map(actor_key) do
    agent_uid = map_text(actor_key, "agent_uid")
    session_id = map_text(actor_key, "session_id")

    if is_binary(agent_uid) and is_binary(session_id) do
      events =
        ScheduledEvent
        |> where([event], event.kind == "cron_fire")
        |> where([event], event.status == "scheduled")
        |> where([event], event.agent_uid == ^String.downcase(agent_uid))
        |> where([event], event.session_id == ^session_id)
        |> where([event], event.due_at <= ^reset_at)
        |> lock("FOR UPDATE")
        |> repo.all()

      schedule_ids =
        events
        |> Enum.map(& &1.cron_schedule_id)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      with {:ok, _cancelled} <- cancel_scheduled_events(repo, events, now, "session_reset_due"),
           {:ok, rearmed_count} <-
             rearm_active_cron_schedules_after_reset(repo, schedule_ids, now) do
        {:ok, %{cancelled_events: length(events), rearmed_schedules: rearmed_count}}
      end
    else
      {:ok, %{cancelled_events: 0, rearmed_schedules: 0}}
    end
  end

  @doc """
  Fires a due scheduled event by appending an ActorInput.
  """
  @spec fire_due_event(Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event(scheduled_event_id, opts \\ []) when is_binary(scheduled_event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, event} <- claim_due_event_in_tx(repo, scheduled_event_id, now),
           {:ok, result} <- fire_claimed_event_in_tx(repo, event, now, opts) do
        {:ok, result}
      else
        :noop -> {:ok, %{status: :noop, scheduled_event: nil}}
        {:error, _reason} = error -> error
      end
    end)
    |> persist_fire_error(scheduled_event_id)
  end

  @doc """
  Lists cron schedules for an agent and optional session.
  """
  @spec list_cron_schedules(String.t(), String.t() | nil) :: [CronSchedule.t()]
  def list_cron_schedules(agent_uid, session_id \\ nil) when is_binary(agent_uid) do
    CronSchedule
    |> where([schedule], schedule.agent_uid == ^String.downcase(agent_uid))
    |> maybe_where_session(session_id)
    |> order_by([schedule], asc: schedule.agent_uid, asc: schedule.session_id, asc: schedule.name)
    |> Repo.all()
  end

  @doc """
  Fetches one cron schedule.
  """
  @spec get_cron_schedule(Ecto.UUID.t()) :: {:ok, CronSchedule.t()} | {:error, :not_found}
  def get_cron_schedule(cron_schedule_id) when is_binary(cron_schedule_id) do
    case Repo.get(CronSchedule, cron_schedule_id) do
      %CronSchedule{} = schedule -> {:ok, schedule}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Fetches one concrete scheduled event.
  """
  @spec get_scheduled_event(Ecto.UUID.t()) :: {:ok, ScheduledEvent.t()} | {:error, :not_found}
  def get_scheduled_event(scheduled_event_id) when is_binary(scheduled_event_id) do
    case Repo.get(ScheduledEvent, scheduled_event_id) do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Lists recent concrete fires for a cron schedule.
  """
  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_cron_runs(cron_schedule_id, limit \\ 25)
      when is_binary(cron_schedule_id) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> where([event], event.cron_schedule_id == ^cron_schedule_id)
    |> order_by([event], desc: event.due_at, desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists checkback events for an agent and optional session.
  """
  @spec list_checkbacks(String.t(), String.t() | nil) :: [ScheduledEvent.t()]
  def list_checkbacks(agent_uid, session_id \\ nil) when is_binary(agent_uid) do
    ScheduledEvent
    |> where([event], event.kind == "check_back_later")
    |> where([event], event.agent_uid == ^String.downcase(agent_uid))
    |> maybe_where_session(session_id)
    |> order_by([event], desc: event.due_at, desc: event.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns a JSON-safe schedule projection for API and RPC responses.
  """
  @spec cron_projection(CronSchedule.t()) :: map()
  def cron_projection(%CronSchedule{} = schedule) do
    %{
      "id" => schedule.id,
      "status" => schedule.status,
      "agent_uid" => schedule.agent_uid,
      "session_id" => schedule.session_id,
      "binding_name" => schedule.binding_name,
      "name" => schedule.name,
      "schedule" => schedule.schedule || %{},
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "delivery" => schedule.delivery,
      "next_fire_at" => datetime(schedule.next_fire_at),
      "last_fire_at" => datetime(schedule.last_fire_at),
      "idempotency_key" => schedule.idempotency_key,
      "created_by" => schedule.created_by || %{},
      "failure_policy" => schedule.failure_policy || %{},
      "inserted_at" => datetime(schedule.inserted_at),
      "updated_at" => datetime(schedule.updated_at)
    }
  end

  @doc """
  Returns a JSON-safe scheduled event projection for API and RPC responses.
  """
  @spec event_projection(ScheduledEvent.t()) :: map()
  def event_projection(%ScheduledEvent{} = event) do
    %{
      "id" => event.id,
      "kind" => event.kind,
      "status" => event.status,
      "agent_uid" => event.agent_uid,
      "session_id" => event.session_id,
      "binding_name" => event.binding_name,
      "due_at" => datetime(event.due_at),
      "timezone" => event.timezone,
      "requested_at" => datetime(event.requested_at),
      "idempotency_key" => event.idempotency_key,
      "cron_schedule_id" => event.cron_schedule_id,
      "cron_fire_slot_at" => datetime(event.cron_fire_slot_at),
      "tool_call_id" => event.tool_call_id,
      "source_llm_turn_id" => event.source_llm_turn_id,
      "source_actor_input_id" => event.source_actor_input_id,
      "signal_channel_id" => event.signal_channel_id,
      "provider_thread_id" => event.provider_thread_id,
      "provider_entry_id" => event.provider_entry_id,
      "source_provenance" => event.source_provenance || %{},
      "wake_payload" => event.wake_payload || %{},
      "oban_job_id" => event.oban_job_id,
      "actor_input_id" => event.actor_input_id,
      "fire_attempts" => event.fire_attempts,
      "fire_claimed_at" => datetime(event.fire_claimed_at),
      "fired_at" => datetime(event.fired_at),
      "cancelled_at" => datetime(event.cancelled_at),
      "last_fire_error" => event.last_fire_error || %{},
      "inserted_at" => datetime(event.inserted_at),
      "updated_at" => datetime(event.updated_at)
    }
  end

  @doc false
  @spec next_fire_after(map(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def next_fire_after(schedule, timezone, %DateTime{} = after_at)
      when is_map(schedule) and is_binary(timezone) do
    case map_text(schedule, "kind") do
      "every" -> next_every_fire_after(schedule, after_at)
      "cron" -> next_cron_fire_after(schedule, timezone, after_at)
      _kind -> {:error, :invalid_schedule_kind}
    end
  end

  defp insert_cron_schedule_in_tx(repo, attrs, now, opts) do
    changeset = CronSchedule.changeset(%CronSchedule{}, attrs)

    with {:ok, attempted} <-
           repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :session_id, :idempotency_key],
             returning: true
           ),
         {:ok, persisted} <- fetch_cron_by_idempotency(repo, attrs) do
      case attempted.id == persisted.id do
        true ->
          with {:ok, persisted} <- maybe_arm_active_cron_in_tx(repo, persisted, now, opts) do
            {:ok, %{status: :created, cron_schedule: persisted}}
          end

        false ->
          {:ok, %{status: :already_exists, cron_schedule: persisted}}
      end
    end
  end

  defp maybe_arm_active_cron_in_tx(repo, %CronSchedule{status: "active"} = schedule, now, opts) do
    with {:ok, next_fire_at} <- next_fire_after(schedule.schedule, schedule.timezone, now),
         {:ok, schedule} <-
           schedule
           |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
           |> repo.update(),
         {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
      {:ok, schedule}
    end
  end

  defp maybe_arm_active_cron_in_tx(_repo, %CronSchedule{} = schedule, _now, _opts),
    do: {:ok, schedule}

  defp arm_cron_fire_in_tx(repo, %CronSchedule{} = schedule, slot_at, now, opts) do
    trigger = Keyword.get(opts, :trigger, "scheduled")
    due_at = Keyword.get(opts, :due_at, slot_at)
    delivery = schedule.delivery || %{}

    attrs = %{
      kind: "cron_fire",
      status: "scheduled",
      agent_uid: schedule.agent_uid,
      session_id: schedule.session_id,
      binding_name: schedule.binding_name,
      signal_channel_id: map_text(delivery, "signal_channel_id"),
      provider_thread_id: map_text(delivery, "provider_thread_id"),
      due_at: due_at,
      timezone: schedule.timezone,
      requested_at: now,
      idempotency_key: cron_idempotency_key(schedule.id, slot_at),
      cron_schedule_id: schedule.id,
      cron_fire_slot_at: slot_at,
      source_provenance: %{
        "cron_schedule_id" => schedule.id,
        "trigger" => trigger
      },
      wake_payload: %{
        "trigger" => trigger,
        "cron_schedule_id" => schedule.id,
        "cron_schedule_name" => schedule.name,
        "cron_fire_slot_at" => DateTime.to_iso8601(slot_at),
        "due_at" => DateTime.to_iso8601(due_at),
        "timezone" => schedule.timezone,
        "payload" => schedule.payload || %{},
        "delivery" => delivery
      },
      last_fire_error: %{}
    }

    insert_event_and_wake_in_tx(repo, attrs, opts)
  end

  defp insert_event_and_wake_in_tx(repo, attrs, opts) do
    changeset = ScheduledEvent.changeset(%ScheduledEvent{}, attrs)

    with {:ok, attempted} <-
           repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:kind, :agent_uid, :session_id, :idempotency_key],
             returning: true
           ),
         {:ok, persisted} <- fetch_event_by_idempotency(repo, attrs) do
      case attempted.id == persisted.id and is_nil(persisted.oban_job_id) do
        true ->
          with {:ok, job} <- insert_wake_job(persisted, opts),
               {:ok, event} <-
                 persisted
                 |> ScheduledEvent.changeset(%{oban_job_id: job.id})
                 |> repo.update() do
            {:ok, %{status: :scheduled, scheduled_event: event}}
          end

        false ->
          {:ok, %{status: :already_scheduled, scheduled_event: persisted}}
      end
    end
  end

  defp insert_wake_job(%ScheduledEvent{} = event, opts) do
    insert_fun = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    changeset = scheduled_event_job_changeset(event.id, event.due_at)
    insert_fun.(changeset)
  end

  defp scheduled_event_job_changeset(event_id, due_at) do
    FireScheduledEvent.new(%{"scheduled_event_id" => event_id},
      scheduled_at: due_at,
      unique: [
        fields: [:worker, :args],
        keys: [:scheduled_event_id],
        states: :incomplete
      ]
    )
  end

  defp claim_due_event_in_tx(repo, scheduled_event_id, now) do
    query =
      ScheduledEvent
      |> where([event], event.id == ^scheduled_event_id)
      |> where([event], event.status == "scheduled")
      |> where([event], event.due_at <= ^now)

    {count, _rows} =
      repo.update_all(query,
        inc: [fire_attempts: 1],
        set: [status: "firing", fire_claimed_at: now, updated_at: now]
      )

    case count do
      1 -> {:ok, repo.get!(ScheduledEvent, scheduled_event_id)}
      _other -> :noop
    end
  end

  defp fire_claimed_event_in_tx(
         repo,
         %ScheduledEvent{kind: "check_back_later"} = event,
         now,
         _opts
       ) do
    with {:ok, actor_input} <- append_scheduled_actor_input(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_input, now) do
      {:ok, %{status: :fired, scheduled_event: event, actor_input: actor_input}}
    end
  end

  defp fire_claimed_event_in_tx(repo, %ScheduledEvent{kind: "cron_fire"} = event, now, opts) do
    with %CronSchedule{} = schedule <- lock_cron_schedule(repo, event.cron_schedule_id),
         :ok <- cron_fire_schedule_active(schedule, event),
         {:ok, actor_input} <- append_scheduled_actor_input(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_input, now),
         {:ok, _schedule} <- advance_cron_after_fire(repo, schedule, event, now, opts) do
      {:ok, %{status: :fired, scheduled_event: event, actor_input: actor_input}}
    else
      nil -> mark_event_cancelled(repo, event, now, :cron_schedule_not_found)
      {:cancel, reason} -> mark_event_cancelled(repo, event, now, reason)
      {:error, _reason} = error -> error
    end
  end

  defp append_scheduled_actor_input(repo, %ScheduledEvent{} = event, now) do
    Actors.append_actor_input_in_tx(repo, %{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      session_id: event.session_id,
      ingress_event_id: ingress_event_id(event),
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      provider_entry_id: event.provider_entry_id,
      type: actor_input_type(event),
      available_at: now,
      sender_key: nil,
      payload: actor_input_payload(event, now)
    })
  end

  defp mark_event_fired(repo, %ScheduledEvent{} = event, %ActorInput{} = actor_input, now) do
    event
    |> ScheduledEvent.changeset(%{
      status: "fired",
      actor_input_id: actor_input.id,
      fired_at: now,
      last_fire_error: %{}
    })
    |> repo.update()
  end

  defp mark_event_cancelled(repo, %ScheduledEvent{} = event, now, reason) do
    with {:ok, event} <-
           event
           |> ScheduledEvent.changeset(%{
             status: "cancelled",
             cancelled_at: now,
             last_fire_error: %{"reason" => inspect(reason)}
           })
           |> repo.update() do
      {:ok, %{status: :cancelled, scheduled_event: event}}
    end
  end

  defp advance_cron_after_fire(
         repo,
         %CronSchedule{} = schedule,
         %ScheduledEvent{} = event,
         now,
         opts
       ) do
    case get_in(event.wake_payload || %{}, ["trigger"]) do
      "manual" ->
        {:ok, schedule}

      _trigger ->
        with {:ok, next_fire_at} <- next_fire_after(schedule.schedule, schedule.timezone, now),
             {:ok, schedule} <-
               schedule
               |> CronSchedule.changeset(%{
                 last_fire_at: event.cron_fire_slot_at,
                 next_fire_at: next_fire_at
               })
               |> repo.update(),
             {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
          {:ok, schedule}
        end
    end
  end

  defp cron_fire_schedule_active(%CronSchedule{status: "active"}, _event), do: :ok

  defp cron_fire_schedule_active(%CronSchedule{}, _event),
    do: {:cancel, :cron_schedule_not_active}

  defp actor_input_type(%ScheduledEvent{kind: "check_back_later"}), do: "check_back_later.wakeup"
  defp actor_input_type(%ScheduledEvent{kind: "cron_fire"}), do: "cron.fire"

  defp ingress_event_id(%ScheduledEvent{kind: "check_back_later", id: id}),
    do: "check_back_later:#{id}:wakeup"

  defp ingress_event_id(%ScheduledEvent{
         kind: "cron_fire",
         cron_schedule_id: cron_schedule_id,
         cron_fire_slot_at: %DateTime{} = slot_at
       }),
       do: cron_idempotency_key(cron_schedule_id, slot_at)

  defp actor_input_payload(%ScheduledEvent{} = event, now) do
    %{
      "specversion" => "1.0",
      "id" => ingress_event_id(event),
      "source" => "control-plane://schedule/#{event.kind}",
      "subject" => "schedule:#{event.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => actor_input_type(event),
      "data" => %{
        "scheduled_event_id" => event.id,
        "schedule_kind" => event.kind,
        "due_at" => DateTime.to_iso8601(event.due_at),
        "fired_at" => DateTime.to_iso8601(now),
        "timezone" => event.timezone,
        "cron_schedule_id" => event.cron_schedule_id,
        "cron_fire_slot_at" => datetime(event.cron_fire_slot_at),
        "wake_payload" => event.wake_payload || %{},
        "reply_route" =>
          reject_nil_values(%{
            "binding_name" => event.binding_name,
            "signal_channel_id" => event.signal_channel_id,
            "provider_thread_id" => event.provider_thread_id,
            "provider_entry_id" => event.provider_entry_id
          })
      }
    }
  end

  defp normalize_checkback_attrs(attrs, now, opts) do
    attrs = normalize_external_attrs(attrs)

    with {:ok, timezone} <- schedule_timezone(map_value(attrs, "schedule"), attrs, opts),
         {:ok, due_at} <- parse_checkback_due(map_value(attrs, "schedule"), timezone, now, opts),
         :ok <- validate_bounds(due_at, now, opts),
         {:ok, reason} <- bounded_text(attrs, "reason", @max_reason_length),
         {:ok, check} <- bounded_text(attrs, "check", @max_check_length),
         {:ok, context_summary} <-
           optional_bounded_text(attrs, "context_summary", @max_context_summary_length),
         {:ok, tool_call_id} <- required_text(attrs, "tool_call_id"),
         {:ok, idempotency_key} <- required_text(attrs, "idempotency_key"),
         {:ok, agent_uid} <- required_text(attrs, "agent_uid"),
         {:ok, session_id} <- required_text(attrs, "session_id"),
         {:ok, binding_name} <- required_text(attrs, "binding_name") do
      reply_route = map_value(attrs, "reply_route") || %{}

      {:ok,
       %{
         kind: "check_back_later",
         status: "scheduled",
         agent_uid: agent_uid,
         session_id: session_id,
         binding_name: binding_name,
         due_at: due_at,
         timezone: timezone,
         requested_at: now,
         idempotency_key: idempotency_key,
         tool_call_id: tool_call_id,
         source_llm_turn_id: map_text(attrs, "source_llm_turn_id"),
         source_actor_input_id: map_text(attrs, "source_actor_input_id"),
         signal_channel_id: map_text(reply_route, "signal_channel_id"),
         provider_thread_id: map_text(reply_route, "provider_thread_id"),
         provider_entry_id: map_text(reply_route, "provider_entry_id"),
         source_provenance: map_value(attrs, "source_provenance") || %{},
         wake_payload: %{
           "reason" => reason,
           "check" => check,
           "context_summary" => context_summary,
           "due_at" => DateTime.to_iso8601(due_at),
           "timezone" => timezone,
           "schedule" => map_value(attrs, "schedule") || %{}
         },
         last_fire_error: %{}
       }}
    end
  end

  defp normalize_cron_schedule_attrs(attrs, now, opts) do
    attrs = normalize_external_attrs(attrs)

    with {:ok, agent_uid} <- required_text(attrs, "agent_uid"),
         {:ok, session_id} <- required_text(attrs, "session_id"),
         {:ok, binding_name} <- required_text(attrs, "binding_name"),
         {:ok, idempotency_key} <- required_text(attrs, "idempotency_key"),
         {:ok, schedule, timezone} <-
           normalize_schedule_json(map_value(attrs, "schedule"), attrs, opts),
         {:ok, delivery} <- normalize_cron_delivery(map_value(attrs, "delivery")),
         {:ok, status} <- normalize_cron_status(map_text(attrs, "status") || "active"),
         {:ok, next_fire_at} <- next_fire_after(schedule, timezone, now) do
      {:ok,
       %{
         status: status,
         agent_uid: agent_uid,
         session_id: session_id,
         binding_name: binding_name,
         name: map_text(attrs, "name"),
         schedule: schedule,
         timezone: timezone,
         payload: map_value(attrs, "payload") || %{},
         delivery: delivery,
         next_fire_at: next_fire_at_for_status(status, next_fire_at),
         idempotency_key: idempotency_key,
         created_by: map_value(attrs, "created_by") || %{"kind" => "operator_api"},
         failure_policy: map_value(attrs, "failure_policy") || %{}
       }}
    end
  end

  defp normalize_cron_schedule_update_attrs(%CronSchedule{} = existing, attrs, now, opts) do
    attrs = normalize_external_attrs(attrs)
    schedule_input = Map.get(attrs, "schedule", existing.schedule)
    base = %{"timezone" => Map.get(attrs, "timezone", existing.timezone)}
    delivery_input = Map.get(attrs, "delivery", existing.delivery)
    status_input = Map.get(attrs, "status", existing.status)

    with {:ok, schedule, timezone} <- normalize_schedule_json(schedule_input, base, opts),
         {:ok, delivery} <- normalize_cron_delivery(delivery_input),
         {:ok, status} <- normalize_cron_status(status_input),
         {:ok, next_fire_at} <- next_fire_after(schedule, timezone, now) do
      {:ok,
       %{}
       |> maybe_put(:status, Map.get(attrs, "status"))
       |> maybe_put(:name, Map.get(attrs, "name"))
       |> maybe_put(:schedule, schedule)
       |> maybe_put(:timezone, timezone)
       |> maybe_put(:payload, Map.get(attrs, "payload"))
       |> maybe_put(:delivery, delivery)
       |> maybe_put(:failure_policy, Map.get(attrs, "failure_policy"))
       |> Map.put(:next_fire_at, next_fire_at_for_status(status, next_fire_at))}
    end
  end

  defp next_fire_at_for_status("active", %DateTime{} = next_fire_at), do: next_fire_at
  defp next_fire_at_for_status(_status, _next_fire_at), do: nil

  defp normalize_cron_status(status) when status in ["active", "paused"], do: {:ok, status}
  defp normalize_cron_status(status) when status in ["deleted", "failed"], do: {:ok, status}
  defp normalize_cron_status(_status), do: {:error, :invalid_cron_status}

  defp normalize_cron_delivery(delivery) when is_map(delivery) do
    case required_text(delivery, "signal_channel_id") do
      {:ok, _signal_channel_id} -> {:ok, delivery}
      {:error, _reason} -> {:error, :cron_delivery_route_required}
    end
  end

  defp normalize_cron_delivery(_delivery), do: {:error, :cron_delivery_route_required}

  defp normalize_schedule_json(schedule, attrs, opts) when is_map(schedule) do
    case map_text(schedule, "kind") do
      "every" ->
        with {:ok, timezone} <- schedule_timezone(schedule, attrs, opts),
             {:ok, every_ms} <- positive_integer(schedule, "every_ms"),
             {:ok, anchor_at} <- absolute_datetime(map_text(schedule, "anchor_at")) do
          {:ok,
           %{
             "kind" => "every",
             "every_ms" => every_ms,
             "anchor_at" => DateTime.to_iso8601(anchor_at)
           }, timezone}
        end

      "cron" ->
        with {:ok, timezone} <- schedule_timezone(schedule, attrs, opts),
             {:ok, expression} <- required_text(schedule, "expression"),
             {:ok, normalized_expression} <- validate_cron_expression(expression),
             {:ok, stagger_ms} <- non_negative_integer(schedule, "stagger_ms", 0) do
          {:ok,
           %{
             "kind" => "cron",
             "expression" => normalized_expression,
             "timezone" => timezone,
             "stagger_ms" => stagger_ms,
             "day_match" => "and"
           }, timezone}
        end

      _kind ->
        {:error, :invalid_schedule_kind}
    end
  end

  defp normalize_schedule_json(_schedule, _attrs, _opts), do: {:error, :invalid_schedule}

  defp parse_checkback_due(schedule, timezone, now, _opts) when is_map(schedule) do
    after_value = map_value(schedule, "after")
    at_value = Map.get(schedule, "at")

    case {after_value, at_value} do
      {%{} = after_map, nil} -> parse_after(after_map, now)
      {nil, at} when is_binary(at) -> parse_at(at, timezone)
      _other -> {:error, :checkback_requires_exactly_one_time}
    end
  end

  defp parse_checkback_due(_schedule, _timezone, _now, _opts), do: {:error, :invalid_schedule}

  defp parse_after(after_map, now) do
    with {:ok, value} <- positive_integer(after_map, "value"),
         {:ok, unit_ms} <- duration_unit_ms(map_text(after_map, "unit")) do
      {:ok, DateTime.add(now, value * unit_ms, :millisecond)}
    end
  end

  defp parse_at(value, timezone) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.shift_zone(datetime, "Etc/UTC")

      {:error, _reason} ->
        parse_local_at(value, timezone)
    end
  end

  defp parse_local_at(value, timezone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      datetime_in_timezone(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), timezone)
      |> to_utc()
    else
      _error -> {:error, :invalid_at}
    end
  end

  defp validate_bounds(%DateTime{} = due_at, %DateTime{} = now, opts) do
    min_delay_ms = Keyword.get(opts, :min_delay_ms, @min_delay_ms)
    max_horizon_ms = Keyword.get(opts, :max_horizon_ms, @max_horizon_ms)

    cond do
      DateTime.compare(due_at, DateTime.add(now, min_delay_ms, :millisecond)) == :lt ->
        {:error, :schedule_too_soon}

      DateTime.compare(due_at, DateTime.add(now, max_horizon_ms, :millisecond)) == :gt ->
        {:error, :schedule_too_far}

      true ->
        :ok
    end
  end

  defp next_every_fire_after(schedule, %DateTime{} = after_at) do
    with {:ok, every_ms} <- positive_integer(schedule, "every_ms"),
         {:ok, anchor_at} <- absolute_datetime(map_text(schedule, "anchor_at")) do
      case DateTime.compare(anchor_at, after_at) do
        :gt ->
          {:ok, anchor_at}

        _comparison ->
          delta_ms = DateTime.diff(after_at, anchor_at, :millisecond)
          steps = div(delta_ms, every_ms) + 1
          {:ok, DateTime.add(anchor_at, steps * every_ms, :millisecond)}
      end
    end
  end

  defp next_cron_fire_after(schedule, timezone, %DateTime{} = after_at) do
    with {:ok, local_after} <- DateTime.shift_zone(after_at, timezone),
         {:ok, expression} <- required_text(schedule, "expression"),
         {:ok, stagger_ms} <- non_negative_integer(schedule, "stagger_ms", 0),
         {:ok, local_next} <- next_cron_local(expression, local_after),
         {:ok, utc_next} <- DateTime.shift_zone(local_next, "Etc/UTC") do
      {:ok, DateTime.add(utc_next, stagger_ms, :millisecond)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp next_cron_local(expression, %DateTime{} = local_after) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    case fields do
      [_minute, _hour, _day, _month, _weekday] ->
        with {:ok, expr} <- Oban.Plugins.Cron.parse(expression) do
          {:ok, Oban.Cron.Expression.next_at(expr, local_after)}
        end

      [seconds, minute, hour, day, month, weekday] ->
        five_field = Enum.join([minute, hour, day, month, weekday], " ")

        with {:ok, seconds} <- parse_cron_seconds(seconds),
             {:ok, expr} <- Oban.Plugins.Cron.parse(five_field) do
          {:ok, next_six_field_cron_local(expr, seconds, local_after)}
        end

      _fields ->
        {:error, :invalid_cron_expression}
    end
  end

  defp next_six_field_cron_local(expr, seconds, %DateTime{} = local_after) do
    minute_start = %{DateTime.truncate(local_after, :second) | second: 0}

    same_minute_second =
      if Oban.Cron.Expression.now?(expr, minute_start) do
        Enum.find(seconds, &(&1 > local_after.second))
      end

    case same_minute_second do
      second when is_integer(second) ->
        %{minute_start | second: second}

      _value ->
        next_minute = Oban.Cron.Expression.next_at(expr, local_after)
        %{next_minute | second: List.first(seconds)}
    end
  end

  defp validate_cron_expression(expression) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    case fields do
      [_minute, _hour, _day, _month, _weekday] ->
        with {:ok, _expr} <- Oban.Plugins.Cron.parse(expression), do: {:ok, expression}

      [seconds, minute, hour, day, month, weekday] ->
        five_field = Enum.join([minute, hour, day, month, weekday], " ")

        with {:ok, _seconds} <- parse_cron_seconds(seconds),
             {:ok, _expr} <- Oban.Plugins.Cron.parse(five_field) do
          {:ok, expression}
        end

      _fields ->
        {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_seconds(field) when is_binary(field) do
    field
    |> String.split(",", trim: true)
    |> Enum.map(&parse_cron_second_part/1)
    |> collect_results()
    |> case do
      {:ok, ranges} ->
        seconds =
          ranges
          |> Enum.flat_map(& &1)
          |> Enum.uniq()
          |> Enum.sort()

        case seconds != [] and Enum.all?(seconds, &(&1 in 0..59)) do
          true -> {:ok, seconds}
          false -> {:error, :invalid_cron_seconds}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_cron_second_part("*"), do: {:ok, Enum.to_list(0..59)}

  defp parse_cron_second_part("*/" <> step) do
    with {:ok, step} <- parse_positive_integer(step) do
      {:ok, Enum.take_every(Enum.to_list(0..59), step)}
    end
  end

  defp parse_cron_second_part(part) do
    cond do
      String.contains?(part, "/") ->
        with [range, step] <- String.split(part, "/", parts: 2),
             {:ok, values} <- parse_cron_second_part(range),
             {:ok, step} <- parse_positive_integer(step) do
          {:ok, Enum.take_every(values, step)}
        else
          _value -> {:error, :invalid_cron_seconds}
        end

      String.contains?(part, "-") ->
        with [left, right] <- String.split(part, "-", parts: 2),
             {:ok, left} <- parse_non_negative_integer(left),
             {:ok, right} <- parse_non_negative_integer(right),
             true <- left <= right do
          {:ok, Enum.to_list(left..right)}
        else
          _value -> {:error, :invalid_cron_seconds}
        end

      true ->
        with {:ok, second} <- parse_non_negative_integer(part) do
          {:ok, [second]}
        end
    end
  end

  defp cancel_future_cron_events(repo, %CronSchedule{} = schedule, now) do
    events =
      ScheduledEvent
      |> where([event], event.kind == "cron_fire")
      |> where([event], event.cron_schedule_id == ^schedule.id)
      |> where([event], event.status == "scheduled")
      |> lock("FOR UPDATE")
      |> repo.all()

    cancel_scheduled_events(repo, events, now, "cron_schedule_changed")
  end

  defp cancel_scheduled_events(_repo, [], _now, _reason), do: {:ok, []}

  defp cancel_scheduled_events(repo, events, now, reason) do
    events
    |> Enum.map(fn event ->
      event
      |> ScheduledEvent.changeset(%{
        status: "cancelled",
        cancelled_at: now,
        last_fire_error: %{"reason" => reason}
      })
      |> repo.update()
    end)
    |> collect_results()
  end

  defp rearm_active_cron_schedules_after_reset(_repo, [], _now), do: {:ok, 0}

  defp rearm_active_cron_schedules_after_reset(repo, schedule_ids, now) do
    schedule_ids
    |> Enum.map(&rearm_active_cron_schedule_after_reset(repo, &1, now))
    |> collect_results()
    |> case do
      {:ok, results} ->
        {:ok, Enum.count(results, &(&1 == :rearmed))}

      {:error, _reason} = error ->
        error
    end
  end

  defp rearm_active_cron_schedule_after_reset(repo, cron_schedule_id, now) do
    case lock_cron_schedule(repo, cron_schedule_id) do
      %CronSchedule{status: "active"} = schedule ->
        with {:ok, next_fire_at} <- next_fire_after(schedule.schedule, schedule.timezone, now),
             {:ok, schedule} <-
               schedule
               |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
               |> repo.update(),
             {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, []) do
          {:ok, :rearmed}
        end

      %CronSchedule{} ->
        {:ok, :skipped}

      nil ->
        {:ok, :missing}
    end
  end

  defp fetch_cron_by_idempotency(repo, attrs) do
    case repo.get_by(CronSchedule,
           agent_uid: attrs.agent_uid,
           session_id: attrs.session_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %CronSchedule{} = schedule -> {:ok, schedule}
      nil -> {:error, :cron_schedule_not_found}
    end
  end

  defp fetch_event_by_idempotency(repo, attrs) do
    case repo.get_by(ScheduledEvent,
           kind: attrs.kind,
           agent_uid: attrs.agent_uid,
           session_id: attrs.session_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> {:error, :scheduled_event_not_found}
    end
  end

  defp lock_cron_schedule(repo, cron_schedule_id) do
    CronSchedule
    |> where([schedule], schedule.id == ^cron_schedule_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_scheduled_event(repo, scheduled_event_id) do
    ScheduledEvent
    |> where([event], event.id == ^scheduled_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp reject_deleted(%CronSchedule{status: "deleted"}), do: {:error, :cron_schedule_deleted}
  defp reject_deleted(%CronSchedule{}), do: :ok

  defp persist_fire_error({:error, reason} = error, scheduled_event_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(event in ScheduledEvent,
        where: event.id == ^scheduled_event_id and event.status == "firing"
      ),
      set: [
        status: "scheduled",
        last_fire_error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )

    error
  end

  defp persist_fire_error(result, _scheduled_event_id), do: result

  defp schedule_timezone(schedule, attrs, opts) do
    timezone =
      map_text(schedule || %{}, "timezone") ||
        map_text(attrs || %{}, "timezone") ||
        Keyword.get(opts, :timezone)

    case timezone do
      value when is_binary(value) -> validate_timezone(value)
      _value -> SystemConfig.timezone()
    end
  end

  defp validate_timezone("UTC"), do: {:ok, "Etc/UTC"}

  defp validate_timezone(timezone) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _now} -> {:ok, timezone}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp datetime_in_timezone(%Date{} = date, %Time{} = time, timezone) do
    case DateTime.new(date, Time.truncate(time, :second), timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first_datetime, _second_datetime} -> {:ok, first_datetime}
      {:gap, _before_gap, after_gap} -> {:ok, after_gap}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp to_utc({:ok, %DateTime{} = datetime}), do: DateTime.shift_zone(datetime, "Etc/UTC")
  defp to_utc({:error, _reason} = error), do: error

  defp absolute_datetime(value) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, utc}
    else
      _error -> {:error, :invalid_datetime}
    end
  end

  defp absolute_datetime(_value), do: {:error, :invalid_datetime}

  defp duration_unit_ms(unit) do
    case unit do
      "millisecond" -> {:ok, 1}
      "milliseconds" -> {:ok, 1}
      "second" -> {:ok, 1_000}
      "seconds" -> {:ok, 1_000}
      "minute" -> {:ok, 60_000}
      "minutes" -> {:ok, 60_000}
      "hour" -> {:ok, 3_600_000}
      "hours" -> {:ok, 3_600_000}
      "day" -> {:ok, 86_400_000}
      "days" -> {:ok, 86_400_000}
      "week" -> {:ok, 604_800_000}
      "weeks" -> {:ok, 604_800_000}
      _unit -> {:error, :invalid_duration_unit}
    end
  end

  defp positive_integer(map, key) do
    with {:ok, value} <- integer_value(map, key),
         true <- value > 0 do
      {:ok, value}
    else
      _value -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp non_negative_integer(map, key, default) do
    case integer_value(map, key) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_non_negative_integer, key}}
      {:error, _reason} -> {:ok, default}
    end
  end

  defp integer_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_integer(value)
      _value -> {:error, {:missing_integer, key}}
    end
  end

  defp parse_positive_integer(value) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer > 0 do
      {:ok, integer}
    else
      _value -> {:error, :invalid_integer}
    end
  end

  defp parse_non_negative_integer(value) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer >= 0 do
      {:ok, integer}
    else
      _value -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _value -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}
  defp parse_integer(_value), do: {:error, :invalid_integer}

  defp bounded_text(map, key, max_length) do
    with {:ok, value} <- required_text(map, key),
         true <- String.length(value) <= max_length do
      {:ok, value}
    else
      false -> {:error, {:text_too_long, key}}
      {:error, _reason} = error -> error
    end
  end

  defp optional_bounded_text(map, key, max_length) do
    case map_text(map, key) do
      nil ->
        {:ok, nil}

      value when byte_size(value) == 0 ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.length(value) <= max_length do
          true -> {:ok, value}
          false -> {:error, {:text_too_long, key}}
        end
    end
  end

  defp required_text(map, key) when is_map(map) do
    case map_text(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_text, key}}
    end
  end

  defp map_text(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp map_text(_map, _key), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp map_value(_map, _key), do: nil

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: where(query, [row], row.session_id == ^session_id)

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cron_idempotency_key(cron_schedule_id, %DateTime{} = slot_at) do
    "cron:#{cron_schedule_id}:#{DateTime.to_iso8601(slot_at)}"
  end

  defp datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp datetime(nil), do: nil

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
