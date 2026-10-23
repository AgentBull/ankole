defmodule Ankole.Schedule do
  @moduledoc """
  Control-plane schedule subsystem.

  Schedule owns durable time semantics. Oban jobs are wake edges. The domain
  tables and the selected consumer record are the correctness boundary.

  Each write operation is a generic action that owns its transaction and gives
  `{:ok, value}` or `{:error, reason}`. Code that runs in its own transaction
  composes the `_in_tx` functions of `Ankole.Schedule.Checkbacks` and
  `Ankole.Schedule.Cron`.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Schedule.Checkbacks
  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Fire
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Projections
  alias Ankole.Schedule.Queries
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @type create_result ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/cron-schedules", CronSchedule do
        index(:console_list, name: "list_cron_schedules", derive_sort?: false)
      end

      base_route "/agents/:agent_uid/cron-schedules", CronSchedule do
        route(:post, "/", :console_create, name: "create_cron_schedule")
        get(:read, name: "get_cron_schedule")
        route(:patch, "/:id", :console_update, name: "update_cron_schedule")
        route(:post, "/:id/pause", :console_pause, name: "pause_cron_schedule")
        route(:post, "/:id/resume", :console_resume, name: "resume_cron_schedule")
        route(:delete, "/:id", :console_remove, name: "remove_cron_schedule")
        route(:post, "/:id/runs", :console_run, name: "run_cron_schedule")
      end

      base_route "/agents/:agent_uid/cron-schedules/:cron_schedule_id/runs", ScheduledEvent do
        index(:console_cron_runs, name: "list_cron_schedule_runs", derive_sort?: false)
      end

      base_route "/checkbacks", ScheduledEvent do
        index(:console_checkbacks, name: "list_checkbacks", derive_sort?: false)
      end

      base_route "/agents/:agent_uid/checkbacks", ScheduledEvent do
        route(:delete, "/:id", :console_cancel_checkback, name: "cancel_checkback")
      end
    end
  end

  resources do
    resource ScheduledEvent do
      define(:list_scheduled_events, action: :read)
      define(:reauthorize_scheduled_event, action: :reauthorize)
    end

    resource CronSchedule do
      # `get_cron_schedule/1` is the facade read that gives `{:error, :not_found}`.
      define(:get_cron_schedule_record, action: :read, get_by: [:id], not_found_error?: false)
      define(:reauthorize_cron_schedule, action: :reauthorize)
    end
  end

  @doc """
  Creates one delayed trigger for an Agent session or automation job.
  """
  @spec create_check_back_later(map(), keyword()) :: create_result()
  def create_check_back_later(attrs, opts \\ []) do
    Ankole.Ash.run_action(ScheduledEvent, :create_check_back_later, %{attrs: attrs, opts: opts})
  end

  @doc """
  Updates one pending checkback in place.
  """
  @spec update_checkback(pos_integer(), map(), keyword()) ::
          {:ok, %{status: :updated, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def update_checkback(scheduled_event_id, attrs, opts \\ []) do
    Ankole.Ash.run_action(
      ScheduledEvent,
      :update_checkback,
      %{scheduled_event_id: scheduled_event_id, attrs: attrs, opts: opts}
    )
  end

  @doc """
  Creates one recurring cron schedule and schedules its next wakeup.
  """
  @spec create_cron_schedule(map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  def create_cron_schedule(attrs, opts \\ []) do
    Ankole.Ash.run_action(CronSchedule, :create_cron_schedule, %{attrs: attrs, opts: opts})
  end

  @doc """
  Updates a cron schedule and moves its next wakeup.
  """
  @spec update_cron_schedule(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule(cron_schedule_id, attrs, opts \\ []) do
    Ankole.Ash.run_action(
      CronSchedule,
      :update_cron_schedule,
      %{cron_schedule_id: cron_schedule_id, attrs: attrs, opts: opts}
    )
  end

  @doc """
  Pauses a cron schedule and clears its next fire time.
  """
  @spec pause_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def pause_cron_schedule(cron_schedule_id, opts \\ []) do
    Ankole.Ash.run_action(
      CronSchedule,
      :pause_cron_schedule,
      %{cron_schedule_id: cron_schedule_id, opts: opts}
    )
  end

  @doc """
  Resumes a paused cron schedule from the resume time.
  """
  @spec resume_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def resume_cron_schedule(cron_schedule_id, opts \\ []) do
    Ankole.Ash.run_action(
      CronSchedule,
      :resume_cron_schedule,
      %{cron_schedule_id: cron_schedule_id, opts: opts}
    )
  end

  @doc """
  Marks a cron schedule deleted and cancels future fires.
  """
  @spec remove_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule(cron_schedule_id, opts \\ []) do
    Ankole.Ash.run_action(
      CronSchedule,
      :remove_cron_schedule,
      %{cron_schedule_id: cron_schedule_id, opts: opts}
    )
  end

  @doc """
  Creates an immediate manual cron fire without changing recurrence state.
  """
  @spec run_cron_schedule(Ecto.UUID.t(), keyword()) :: create_result()
  def run_cron_schedule(cron_schedule_id, opts \\ []) do
    Ankole.Ash.run_action(
      CronSchedule,
      :run_cron_schedule,
      %{cron_schedule_id: cron_schedule_id, opts: opts}
    )
  end

  @doc """
  Cancels one pending checkback event.
  """
  @spec cancel_checkback(pos_integer(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback(scheduled_event_id, opts \\ []) do
    Ankole.Ash.run_action(
      ScheduledEvent,
      :cancel_checkback,
      %{scheduled_event_id: scheduled_event_id, opts: opts}
    )
  end

  @doc """
  Cancels scheduled check-backs for one provider entry inside a transaction.
  """
  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  defdelegate cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, now), to: Checkbacks

  @doc """
  Fires a due scheduled event by appending an Signal or automation job run.
  """
  @spec fire_due_event(pos_integer(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event(scheduled_event_id, opts \\ []) do
    ScheduledEvent
    |> Ankole.Ash.run_action(:fire_due_event, %{
      scheduled_event_id: scheduled_event_id,
      opts: opts
    })
    |> Fire.persist_fire_error(scheduled_event_id, opts)
  end

  @doc "Fires the due slot of one recurring cron schedule."
  def fire_cron(cron_schedule_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    CronSchedule
    |> Ankole.Ash.run_action(:fire_cron, %{cron_schedule_id: cron_schedule_id, now: now})
    |> Fire.persist_cron_error(cron_schedule_id, now, opts)
  end

  @doc """
  Lists cron schedules for an optional agent and optional owner conversation.
  """
  @spec list_cron_schedules(String.t() | nil, String.t() | nil) :: [CronSchedule.t()]
  defdelegate list_cron_schedules(agent_uid \\ nil, owner_session_id \\ nil), to: Queries

  @doc """
  Builds the stable execution session id one cron schedule's fires run in.
  """
  @spec cron_execution_session_id(Ecto.UUID.t()) :: String.t()
  defdelegate cron_execution_session_id(cron_schedule_id),
    to: Cron,
    as: :execution_session_id

  @doc "Returns the cron schedule whose fires run in this session, or nil."
  @spec cron_execution_schedule_id(String.t()) :: Ecto.UUID.t() | nil
  defdelegate cron_execution_schedule_id(session_id), to: Cron, as: :execution_schedule_id

  @doc """
  Fetches one cron schedule.
  """
  @spec get_cron_schedule(Ecto.UUID.t()) :: {:ok, CronSchedule.t()} | {:error, :not_found}
  defdelegate get_cron_schedule(cron_schedule_id), to: Queries

  @doc """
  Fetches one cron schedule by its model-visible name and owning conversation.
  """
  @spec get_cron_schedule_by_name(String.t(), String.t(), String.t()) ::
          {:ok, CronSchedule.t()} | {:error, :not_found}
  defdelegate get_cron_schedule_by_name(agent_uid, owner_session_id, name), to: Queries

  @doc """
  Fetches one checkback.
  """
  @spec get_checkback(pos_integer()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  defdelegate get_checkback(scheduled_event_id),
    to: Checkbacks

  @doc """
  Lists recent concrete fires for a cron schedule.
  """
  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  defdelegate list_cron_runs(cron_schedule_id, limit \\ 25), to: Queries

  @doc """
  Lists a bounded set of pending checkbacks for model-visible management.
  """
  @spec list_pending_checkbacks(String.t(), String.t(), pos_integer()) :: [ScheduledEvent.t()]
  defdelegate list_pending_checkbacks(agent_uid, session_id, limit \\ 10), to: Queries

  @doc """
  Returns the narrow model-visible recurring schedule projection.
  """
  @spec cron_model_projection(CronSchedule.t()) :: map()
  defdelegate cron_model_projection(schedule), to: Projections

  @doc """
  Returns the model-visible scheduled event projection for schedule RPC responses.
  """
  @spec event_model_projection(ScheduledEvent.t()) :: map()
  defdelegate event_model_projection(event), to: Projections

  @doc """
  Computes the next fire time after a reference time for a schedule payload.
  """
  @spec next_fire_after(map(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defdelegate next_fire_after(schedule, timezone, after_at), to: Planner
end
