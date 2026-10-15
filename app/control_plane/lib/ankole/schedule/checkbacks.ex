defmodule Ankole.Schedule.Checkbacks do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs
  alias Ankole.Repo
  alias Ankole.Sessions.Jobs.FireScheduledEvent
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec create_check_back_later(map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def create_check_back_later(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, attrs} <- Normalizer.checkback_attrs(attrs, now, opts) do
      Repo.transact(fn repo ->
        attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

        with :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
             :ok <-
               AutomationJobs.validate_bindable_in_tx(
                 repo,
                 attrs.automation_job_id,
                 attrs.agent_uid,
                 now
               ) do
          Store.insert_idempotent_event_and_wake_in_tx(repo, attrs, opts)
        end
      end)
    end
  end

  @spec update_checkback(pos_integer(), map(), keyword()) ::
          {:ok, %{status: :updated, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def update_checkback(scheduled_event_id, attrs, opts \\ [])
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with :ok <-
             Ankole.Principals.WorkAccess.check_record_in_tx(
               repo,
               ScheduledEvent,
               scheduled_event_id
             ),
           {:ok, event} <- fetch_checkback_in_tx(repo, scheduled_event_id, true) do
        case event do
          %ScheduledEvent{status: "scheduled"} ->
            with {:ok, updated_attrs} <-
                   Normalizer.checkback_update_attrs(event, attrs, now, opts),
                 :ok <-
                   validate_updated_automation_job(
                     repo,
                     attrs,
                     updated_attrs.automation_job_id,
                     event.agent_uid,
                     now
                   ),
                 {:ok, event} <- event |> ScheduledEvent.changeset(updated_attrs) |> repo.update(),
                 :ok <-
                   Ankole.Job.schedule_in_tx(
                     repo,
                     FireScheduledEvent,
                     %{"scheduled_event_id" => event.id},
                     event.due_at
                   ) do
              {:ok, %{status: :updated, scheduled_event: event}}
            end

          %ScheduledEvent{status: status} ->
            {:error, {:checkback_not_pending, status}}
        end
      end
    end)
  end

  @spec cancel_checkback(pos_integer(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback(scheduled_event_id, opts \\ [])
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, event} <- fetch_checkback_in_tx(repo, scheduled_event_id, true) do
        case event do
          %ScheduledEvent{status: "scheduled"} ->
            cancel_locked_checkback(repo, event, now, "user_cancelled")

          %ScheduledEvent{status: "cancelled"} ->
            {:ok, event}

          %ScheduledEvent{status: status} ->
            {:error, {:checkback_not_pending, status}}
        end
      end
    end)
  end

  @spec get_checkback(pos_integer()) ::
          {:ok, ScheduledEvent.t()} | {:error, term()}
  def get_checkback(scheduled_event_id)
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    Repo.transact(fn repo ->
      fetch_checkback_in_tx(repo, scheduled_event_id, false)
    end)
  end

  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  def cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, %DateTime{} = now)
      when is_map(attrs) do
    agent_uid = Attrs.map_text(attrs, "agent_uid")
    session_id = Attrs.map_text(attrs, "session_id")
    binding_name = Attrs.map_text(attrs, "binding_name")
    provider_message_id = Attrs.map_text(attrs, "provider_message_id")

    if Enum.all?([agent_uid, session_id, binding_name, provider_message_id], &is_binary/1) do
      {count, _rows} =
        ScheduledEvent
        |> where([event], event.kind == "check_back_later")
        |> where([event], event.status == "scheduled")
        |> where([event], event.agent_uid == ^String.downcase(agent_uid))
        |> where([event], event.session_id == ^session_id)
        |> where([event], event.binding_name == ^binding_name)
        |> where([event], event.provider_message_id == ^provider_message_id)
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

  # Models can still hold ids cancelled by the replacement implementation.
  # Remove this clause when no pending checkback has
  # source_provenance.replaces_scheduled_event_id.
  defp fetch_checkback_in_tx(repo, id, lock?) do
    event = if lock?, do: Store.lock_scheduled_event(repo, id), else: repo.get(ScheduledEvent, id)

    case event do
      nil ->
        {:error, :scheduled_event_not_found}

      %ScheduledEvent{kind: kind} when kind != "check_back_later" ->
        {:error, :not_checkback}

      %ScheduledEvent{status: "cancelled", last_fire_error: %{"reason" => "checkback_replaced"}} ->
        {:error, :checkback_replaced}

      %ScheduledEvent{} ->
        {:ok, event}
    end
  end

  defp cancel_locked_checkback(repo, event, now, reason) do
    event
    |> ScheduledEvent.changeset(%{
      status: "cancelled",
      cancelled_at: now,
      last_fire_error: %{"reason" => reason}
    })
    |> repo.update()
  end

  defp validate_updated_automation_job(repo, requested_attrs, job_id, agent_uid, now) do
    if Map.has_key?(requested_attrs, "automation_job_id") or
         Map.has_key?(requested_attrs, :automation_job_id),
       do: AutomationJobs.validate_bindable_in_tx(repo, job_id, agent_uid, now),
       else: :ok
  end

  def stop_human_work_in_tx(repo, uid, version, now) do
    repo.update_all(
      from(e in ScheduledEvent,
        where:
          e.human_uid == ^uid and e.human_access_version < ^version and
            e.status == "scheduled"
      ),
      set: [
        status: "cancelled",
        cancelled_at: now,
        updated_at: now,
        last_fire_error: %{"reason" => "human_access_revoked"}
      ]
    )
  end
end
