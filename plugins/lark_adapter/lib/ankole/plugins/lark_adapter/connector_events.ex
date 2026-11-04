defmodule Ankole.Plugins.LarkAdapter.ConnectorEvents do
  @moduledoc "Lark business events use the same durable Signal dispatch as native sources."

  @events [
    "approval.instance.status_changed_v4",
    "approval.task.status_changed_v4",
    "approval_instance",
    "approval_task",
    "task.task.updated_v1",
    "task.task.comment.updated_v1",
    "calendar.calendar.event.changed_v4"
  ]
  def event_types, do: @events

  def signal(config, event) do
    with {:ok, data} <- event_data(config, event.type, event.content || %{}) do
      {:ok,
       %{
         "specversion" => "1.0",
         "id" => event.id,
         "source" => "connector://#{config.id}/lark",
         "type" => event.type,
         "time" => DateTime.to_iso8601(event.created_at || DateTime.utc_now()),
         "data" => data
       }}
    end
  end

  defp event_data(config, "card.action.trigger", data) do
    operator_id = get_in(data, ["operator", "user_id"])

    with {:ok, uid} <-
           Ankole.Plugins.LarkAdapter.Connector.principal_for_user(config, operator_id),
         do: {:ok, Map.put(data, "operator_principal_uid", uid)}
  end

  defp event_data(_, _, data), do: {:ok, data}

  def references(auth_config_id, type, data) do
    {trigger_type, key} =
      cond do
        String.starts_with?(type, "approval") -> {"lark_approval", data["approval_code"]}
        String.starts_with?(type, "calendar.") -> {"lark_calendar", data["calendar_id"]}
        true -> {nil, nil}
      end

    with {:ok, triggers} <- matching_triggers(auth_config_id, trigger_type, key) do
      {:ok,
       [
         "connector://#{auth_config_id}/lark"
         | Enum.map(triggers, &"connector-trigger://#{&1.id}")
       ]}
    end
  end

  defp matching_triggers(_config, nil, _key), do: {:ok, []}
  defp matching_triggers(_config, _type, nil), do: {:ok, []}

  defp matching_triggers(config, type, key),
    do: Ankole.Connectors.list_event_triggers(config, type, key)

  def handle_event(type, event, consumers) do
    ids =
      consumers
      |> Enum.map(fn consumer ->
        consumer[:auth_config_id] || get_in(consumer, [:config, "authConfigId"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, all} ->
      with {:ok, config} <- Ankole.Connectors.Store.get_auth_config(id),
           {:ok, signal} <- signal(config, event),
           {:ok, references} <- references(id, type, signal["data"]),
           {:ok, results} <- dispatch(references, signal) do
        {:cont, {:ok, all ++ results}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp dispatch(references, signal) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, acc} ->
      case Ankole.Signals.Dispatch.emit(reference, signal) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
