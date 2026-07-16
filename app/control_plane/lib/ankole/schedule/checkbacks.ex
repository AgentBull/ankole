defmodule Ankole.Schedule.Checkbacks do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec create_check_back_later(map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def create_check_back_later(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, attrs} <- Normalizer.checkback_attrs(attrs, now, opts),
           {:ok, result} <- Store.insert_event_and_wake_in_tx(repo, attrs, opts) do
        {:ok, result}
      end
    end)
  end

  @spec update_checkback(Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             status: :updated | :already_updated,
             previous_scheduled_event: ScheduledEvent.t(),
             scheduled_event: ScheduledEvent.t()
           }}
          | {:error, term()}
  def update_checkback(scheduled_event_id, attrs, opts \\ [])
      when is_binary(scheduled_event_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case Store.lock_scheduled_event(repo, scheduled_event_id) do
        %ScheduledEvent{kind: "check_back_later", status: "scheduled"} = event ->
          replace_checkback_in_tx(repo, event, attrs, now, opts)

        %ScheduledEvent{kind: "check_back_later", status: "cancelled"} = event ->
          update_replacement(repo, event, attrs, now, opts, MapSet.new([event.id]))

        %ScheduledEvent{kind: "check_back_later", status: status} ->
          {:error, {:checkback_not_pending, status}}

        %ScheduledEvent{} ->
          {:error, :not_checkback}

        nil ->
          {:error, :scheduled_event_not_found}
      end
    end)
  end

  @spec cancel_checkback(Ecto.UUID.t(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback(scheduled_event_id, opts \\ []) when is_binary(scheduled_event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case Store.lock_scheduled_event(repo, scheduled_event_id) do
        %ScheduledEvent{kind: "check_back_later", status: "scheduled"} = event ->
          cancel_locked_checkback(repo, event, now, "user_cancelled")

        %ScheduledEvent{kind: "check_back_later", status: "cancelled"} = event ->
          cancel_replacement(repo, event, now, MapSet.new([event.id]))

        %ScheduledEvent{kind: "check_back_later", status: status} ->
          {:error, {:checkback_not_pending, status}}

        %ScheduledEvent{} ->
          {:error, :not_checkback}

        nil ->
          {:error, :scheduled_event_not_found}
      end
    end)
  end

  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  def cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, %DateTime{} = now)
      when is_map(attrs) do
    agent_uid = Attrs.map_text(attrs, "agent_uid")
    session_id = Attrs.map_text(attrs, "session_id")
    binding_name = Attrs.map_text(attrs, "binding_name")
    source_entry_id = Attrs.map_text(attrs, "source_entry_id")

    if Enum.all?([agent_uid, session_id, binding_name, source_entry_id], &is_binary/1) do
      {count, _rows} =
        ScheduledEvent
        |> where([event], event.kind == "check_back_later")
        |> where([event], event.status == "scheduled")
        |> where([event], event.agent_uid == ^String.downcase(agent_uid))
        |> where([event], event.session_id == ^session_id)
        |> where([event], event.binding_name == ^binding_name)
        |> where([event], event.source_entry_id == ^source_entry_id)
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

  defp replace_checkback_in_tx(repo, event, attrs, now, opts) do
    with {:ok, replacement_attrs} <-
           Normalizer.checkback_replacement_attrs(event, attrs, now, opts),
         {:ok, %{status: insert_status, scheduled_event: replacement}} <-
           Store.insert_event_and_wake_in_tx(repo, replacement_attrs, opts),
         :ok <- ensure_replacement_targets(replacement, event),
         {:ok, cancelled} <-
           cancel_locked_checkback(repo, event, now, "checkback_replaced", replacement.id) do
      {:ok,
       %{
         status: replacement_status(insert_status),
         previous_scheduled_event: cancelled,
         scheduled_event: replacement
       }}
    end
  end

  defp update_replacement(repo, %ScheduledEvent{} = event, attrs, now, opts, seen) do
    replacement_id = get_in(event.last_fire_error || %{}, ["replacement_scheduled_event_id"])

    with :ok <- reject_replacement_cycle(replacement_id, seen),
         %ScheduledEvent{kind: "check_back_later"} = replacement <-
           replacement_id && Store.lock_scheduled_event(repo, replacement_id),
         :ok <- ensure_replacement_targets(replacement, event) do
      cond do
        replacement.idempotency_key == Attrs.map_text(attrs, "idempotency_key") ->
          {:ok,
           %{
             status: :already_updated,
             previous_scheduled_event: event,
             scheduled_event: replacement
           }}

        replacement.status == "scheduled" ->
          replace_checkback_in_tx(repo, replacement, attrs, now, opts)

        replacement.status == "cancelled" ->
          update_replacement(
            repo,
            replacement,
            attrs,
            now,
            opts,
            MapSet.put(seen, replacement.id)
          )

        true ->
          {:error, {:checkback_not_pending, replacement.status}}
      end
    else
      {:error, _reason} = error -> error
      _event -> {:error, {:checkback_not_pending, event.status}}
    end
  end

  defp cancel_replacement(repo, %ScheduledEvent{} = event, now, seen) do
    replacement_id = get_in(event.last_fire_error || %{}, ["replacement_scheduled_event_id"])

    case replacement_id do
      nil ->
        {:ok, event}

      replacement_id ->
        with :ok <- reject_replacement_cycle(replacement_id, seen),
             %ScheduledEvent{kind: "check_back_later"} = replacement <-
               Store.lock_scheduled_event(repo, replacement_id),
             :ok <- ensure_replacement_targets(replacement, event) do
          case replacement.status do
            "scheduled" ->
              cancel_locked_checkback(repo, replacement, now, "user_cancelled")

            "cancelled" ->
              cancel_replacement(repo, replacement, now, MapSet.put(seen, replacement.id))

            status ->
              {:error, {:checkback_not_pending, status}}
          end
        else
          {:error, _reason} = error -> error
          _event -> {:error, :checkback_replacement_not_found}
        end
    end
  end

  defp reject_replacement_cycle(nil, _seen), do: {:error, :checkback_replacement_not_found}

  defp reject_replacement_cycle(replacement_id, seen) do
    case MapSet.member?(seen, replacement_id) do
      true -> {:error, :checkback_replacement_cycle}
      false -> :ok
    end
  end

  defp ensure_replacement_targets(replacement, previous) do
    same_scope =
      replacement.agent_uid == previous.agent_uid and
        replacement.session_id == previous.session_id and
        replacement.kind == previous.kind

    case {get_in(replacement.source_provenance || %{}, ["replaces_scheduled_event_id"]),
          same_scope} do
      {previous_id, true} when previous_id == previous.id -> :ok
      _other -> {:error, :checkback_replacement_idempotency_conflict}
    end
  end

  defp cancel_locked_checkback(repo, event, now, reason, replacement_id \\ nil) do
    last_fire_error = %{"reason" => reason}

    last_fire_error =
      if replacement_id,
        do: Map.put(last_fire_error, "replacement_scheduled_event_id", replacement_id),
        else: last_fire_error

    event
    |> ScheduledEvent.changeset(%{
      status: "cancelled",
      cancelled_at: now,
      last_fire_error: last_fire_error
    })
    |> repo.update()
  end

  defp replacement_status(:scheduled), do: :updated
  defp replacement_status(:already_scheduled), do: :already_updated
end
