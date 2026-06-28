defmodule Ankole.Schedule do
  @moduledoc """
  Control-plane schedule subsystem.

  Schedule owns durable time semantics. Oban jobs are wake edges; the domain
  tables and ActorInput idempotency are the correctness boundary.
  """

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

  @doc """
  Creates one delayed self-wakeup event.
  """
  @spec create_check_back_later(map(), keyword()) :: create_result()
  defdelegate create_check_back_later(attrs, opts \\ []), to: Checkbacks

  @doc """
  Creates one recurring cron schedule and arms its first concrete fire.
  """
  @spec create_cron_schedule(map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  defdelegate create_cron_schedule(attrs, opts \\ []), to: Cron

  @doc """
  Updates a cron schedule and re-arms the next active fire.
  """
  @spec update_cron_schedule(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  defdelegate update_cron_schedule(cron_schedule_id, attrs, opts \\ []), to: Cron

  @doc """
  Pauses a cron schedule and cancels future fires that have not materialized.
  """
  @spec pause_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  defdelegate pause_cron_schedule(cron_schedule_id, opts \\ []), to: Cron

  @doc """
  Resumes a paused cron schedule from the resume time.
  """
  @spec resume_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  defdelegate resume_cron_schedule(cron_schedule_id, opts \\ []), to: Cron

  @doc """
  Marks a cron schedule deleted and cancels future fires.
  """
  @spec remove_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  defdelegate remove_cron_schedule(cron_schedule_id, opts \\ []), to: Cron

  @doc """
  Creates an immediate manual cron fire without changing recurrence state.
  """
  @spec run_cron_schedule(Ecto.UUID.t(), keyword()) :: create_result()
  defdelegate run_cron_schedule(cron_schedule_id, opts \\ []), to: Cron

  @doc """
  Cancels one pending checkback event.
  """
  @spec cancel_checkback(Ecto.UUID.t(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  defdelegate cancel_checkback(scheduled_event_id, opts \\ []), to: Checkbacks

  @doc """
  Cancels scheduled check-backs for one provider entry inside a transaction.
  """
  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  defdelegate cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, now), to: Checkbacks

  @doc """
  Cancels due cron events that are superseded by a session reset.
  """
  @spec cancel_due_cron_events_for_reset_in_tx(module(), map(), DateTime.t(), DateTime.t()) ::
          {:ok, %{cancelled_events: non_neg_integer(), rearmed_schedules: non_neg_integer()}}
          | {:error, term()}
  defdelegate cancel_due_cron_events_for_reset_in_tx(repo, actor_key, reset_at, now), to: Cron

  @doc """
  Fires a due scheduled event by appending an ActorInput.
  """
  @spec fire_due_event(Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  defdelegate fire_due_event(scheduled_event_id, opts \\ []), to: Fire

  @doc """
  Lists cron schedules for an agent and optional session.
  """
  @spec list_cron_schedules(String.t(), String.t() | nil) :: [CronSchedule.t()]
  defdelegate list_cron_schedules(agent_uid, session_id \\ nil), to: Queries

  @doc """
  Fetches one cron schedule.
  """
  @spec get_cron_schedule(Ecto.UUID.t()) :: {:ok, CronSchedule.t()} | {:error, :not_found}
  defdelegate get_cron_schedule(cron_schedule_id), to: Queries

  @doc """
  Fetches one concrete scheduled event.
  """
  @spec get_scheduled_event(Ecto.UUID.t()) :: {:ok, ScheduledEvent.t()} | {:error, :not_found}
  defdelegate get_scheduled_event(scheduled_event_id), to: Queries

  @doc """
  Lists recent concrete fires for a cron schedule.
  """
  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  defdelegate list_cron_runs(cron_schedule_id, limit \\ 25), to: Queries

  @doc """
  Lists checkback events for an agent and optional session.
  """
  @spec list_checkbacks(String.t(), String.t() | nil) :: [ScheduledEvent.t()]
  defdelegate list_checkbacks(agent_uid, session_id \\ nil), to: Queries

  @doc """
  Returns a JSON-safe schedule projection for API and RPC responses.
  """
  @spec cron_projection(CronSchedule.t()) :: map()
  defdelegate cron_projection(schedule), to: Projections

  @doc """
  Returns a JSON-safe scheduled event projection for API and RPC responses.
  """
  @spec event_projection(ScheduledEvent.t()) :: map()
  defdelegate event_projection(event), to: Projections

  @doc """
  Computes the next fire time after a reference time for a schedule payload.
  """
  @spec next_fire_after(map(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defdelegate next_fire_after(schedule, timezone, after_at), to: Planner
end
