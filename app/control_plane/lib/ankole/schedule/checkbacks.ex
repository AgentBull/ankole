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

  @spec cancel_checkback(Ecto.UUID.t(), keyword()) :: {:ok, ScheduledEvent.t()} | {:error, term()}
  def cancel_checkback(scheduled_event_id, opts \\ []) when is_binary(scheduled_event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case Store.lock_scheduled_event(repo, scheduled_event_id) do
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

  @spec cancel_checkbacks_for_provider_entry_in_tx(module(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  def cancel_checkbacks_for_provider_entry_in_tx(repo, attrs, %DateTime{} = now)
      when is_map(attrs) do
    agent_uid = Attrs.map_text(attrs, "agent_uid")
    session_id = Attrs.map_text(attrs, "session_id")
    binding_name = Attrs.map_text(attrs, "binding_name")
    provider_entry_id = Attrs.map_text(attrs, "provider_entry_id")

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
end
