defmodule Ankole.Schedule.Checkbacks do
  @moduledoc false

  require Ash.Query

  alias Ankole.AutomationJobs
  alias Ankole.Sessions.Jobs.FireScheduledEvent
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec create_check_back_later_in_tx(module(), map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def create_check_back_later_in_tx(repo, attrs, opts) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, attrs} <- Normalizer.checkback_attrs(attrs, now, opts) do
      attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

      with :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
           :ok <-
             AutomationJobs.validate_bindable_in_tx(
               repo,
               attrs.automation_job_id,
               attrs.agent_uid
             ) do
        Store.insert_idempotent_event_and_wake_in_tx(repo, attrs, opts)
      end
    end
  end

  @spec update_checkback_in_tx(module(), pos_integer(), map(), keyword()) ::
          {:ok, %{status: :updated, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def update_checkback_in_tx(repo, scheduled_event_id, attrs, opts)
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, snapshot} <- fetch_checkback(scheduled_event_id),
         :ok <- Ankole.Principals.WorkAccess.check_in_tx(repo, snapshot),
         :ok <- require_pending(snapshot),
         {:ok, updated_attrs} <- Normalizer.checkback_update_attrs(snapshot, attrs, now, opts),
         :ok <-
           validate_updated_automation_job(
             repo,
             attrs,
             updated_attrs.automation_job_id,
             snapshot.agent_uid
           ),
         {:ok, event} <- lock_checkback(repo, scheduled_event_id),
         true <- event == snapshot,
         {:ok, event} <- Ankole.Ash.update(event, :reschedule, updated_attrs),
         :ok <-
           Ankole.Job.schedule_in_tx(
             repo,
             FireScheduledEvent,
             %{"scheduled_event_id" => event.id},
             event.due_at
           ) do
      {:ok, %{status: :updated, scheduled_event: event}}
    else
      false -> {:error, :scheduled_event_changed}
      {:error, _reason} = error -> error
    end
  end

  defp require_pending(%ScheduledEvent{status: :scheduled}), do: :ok

  defp require_pending(%ScheduledEvent{status: status}),
    do: {:error, {:checkback_not_pending, status}}

  @spec cancel_checkback_in_tx(module(), pos_integer(), keyword()) ::
          {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback_in_tx(repo, scheduled_event_id, opts)
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, event} <- lock_checkback(repo, scheduled_event_id) do
      case event do
        %ScheduledEvent{status: :scheduled} ->
          cancel_locked_checkback(event, now, "user_cancelled")

        %ScheduledEvent{status: :cancelled} ->
          {:ok, event}

        %ScheduledEvent{status: status} ->
          {:error, {:checkback_not_pending, status}}
      end
    end
  end

  @doc false
  # The Console addresses a checkback through its Agent. The checkback of
  # another Agent reads as not found.
  def console_cancel_in_tx(repo, %{agent_uid: agent_uid, id: id}) do
    case Store.get_scheduled_event(id) do
      %ScheduledEvent{agent_uid: ^agent_uid} ->
        repo
        |> cancel_checkback_in_tx(id, [])
        |> Ankole.Errors.not_found([:scheduled_event_not_found], ScheduledEvent)

      _other ->
        {:error, Ankole.Errors.Invalid.NotFound.exception(resource: ScheduledEvent, id: id)}
    end
  end

  @spec get_checkback(pos_integer()) ::
          {:ok, ScheduledEvent.t()} | {:error, term()}
  def get_checkback(scheduled_event_id)
      when is_integer(scheduled_event_id) and scheduled_event_id > 0,
      do: fetch_checkback(scheduled_event_id)

  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  def cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, %DateTime{} = now)
      when is_map(attrs) do
    agent_uid = Attrs.map_text(attrs, "agent_uid")
    session_id = Attrs.map_text(attrs, "session_id")
    binding_name = Attrs.map_text(attrs, "binding_name")
    provider_message_id = Attrs.map_text(attrs, "provider_message_id")

    if Enum.all?([agent_uid, session_id, binding_name, provider_message_id], &is_binary/1) do
      agent_uid = String.downcase(agent_uid)

      query =
        Ash.Query.filter(
          ScheduledEvent,
          kind == "check_back_later" and status == :scheduled and agent_uid == ^agent_uid and
            session_id == ^session_id and binding_name == ^binding_name and
            provider_message_id == ^provider_message_id
        )

      with {:ok, events} <-
             Store.cancel_matching_in_tx(repo, query, now, "source_entry_tombstoned"),
           do: {:ok, length(events)}
    else
      {:ok, 0}
    end
  end

  # Models can still hold ids cancelled by the replacement implementation.
  # Remove this clause when no pending checkback has
  # source_provenance.replaces_scheduled_event_id.
  defp fetch_checkback(id), do: id |> Store.get_scheduled_event() |> checkback()

  defp lock_checkback(repo, id), do: repo |> Store.lock_scheduled_event(id) |> checkback()

  defp checkback(event) do
    case event do
      nil ->
        {:error, :scheduled_event_not_found}

      %ScheduledEvent{kind: kind} when kind != "check_back_later" ->
        {:error, :not_checkback}

      %ScheduledEvent{status: :cancelled, last_fire_error: %{"reason" => "checkback_replaced"}} ->
        {:error, :checkback_replaced}

      %ScheduledEvent{} ->
        {:ok, event}
    end
  end

  defp cancel_locked_checkback(event, now, reason) do
    Ankole.Ash.update(event, :cancel, %{
      cancelled_at: now,
      last_fire_error: %{"reason" => reason}
    })
  end

  defp validate_updated_automation_job(repo, requested_attrs, job_id, agent_uid) do
    if Map.has_key?(requested_attrs, "automation_job_id") or
         Map.has_key?(requested_attrs, :automation_job_id),
       do: AutomationJobs.validate_bindable_in_tx(repo, job_id, agent_uid),
       else: :ok
  end

  @doc "Cancels the pending events of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(repo, uid, version, now) do
    query =
      Ash.Query.filter(
        ScheduledEvent,
        human_uid == ^uid and human_access_version < ^version and status == :scheduled
      )

    {:ok, events} = Store.cancel_matching_in_tx(repo, query, now, "human_access_revoked")
    {length(events), events}
  end
end
