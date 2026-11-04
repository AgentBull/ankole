defmodule Ankole.Connectors.Ingress do
  @moduledoc "Verifies a tenant-bound provider event before its durable Signal fanout."
  alias Ankole.Connectors.{Credentials, Registry, Store, Triggers}

  @doc "Accepts a delivery after the configured Cloud provider authenticates and binds its Pod scope."
  def receive_cloud_delivery(%{
        "kind" => "trigger_event",
        "pod_trigger_id" => id,
        "delivery_id" => delivery_id,
        "cloud_event" => event
      })
      when is_binary(delivery_id) and is_map(event) do
    with {:ok, %{trigger: trigger}} <- Triggers.get_ingress(id),
         true <- is_binary(event["type"]) and is_map(event["data"]) do
      Ankole.Signals.emit("connector-trigger://" <> trigger.id, Map.put(event, "id", delivery_id))
    else
      false -> {:error, :invalid_cloud_event}
      error -> error
    end
  end

  def receive_cloud_delivery(
        %{"kind" => "trigger_status", "pod_trigger_id" => id, "status" => status} = envelope
      )
      when status in ["active", "degraded"] do
    Triggers.receive_cloud_status(id, status, envelope["last_error"])
  end

  def receive_cloud_delivery(_), do: {:error, :invalid_cloud_delivery}

  def receive_event(:auth, id, body, headers) do
    with {:ok, config} <- Store.get_auth_config(id),
         {:ok, secret} <- Credentials.secret(config),
         do: dispatch(config, nil, secret, body, headers)
  end

  def receive_event(:trigger, id, body, headers) do
    with {:ok, %{auth_config: config, trigger: trigger, secret: secret}} <-
           Triggers.get_ingress(id),
         do: dispatch(config, trigger, secret, body, headers)
  end

  defp dispatch(config, trigger, secret, body, headers) do
    with {:ok, adapter} <- Registry.adapter(config.plugin_id),
         true <- function_exported?(adapter, :webhook, 4) do
      case adapter.webhook(config, secret, body, headers) do
        {:challenge, challenge} ->
          {:ok, %{"challenge" => challenge}}

        {:ok, %{"challenge" => _} = challenge} ->
          {:ok, challenge}

        {:ok, event} ->
          references =
            cond do
              trigger ->
                {:ok, ["connector-trigger://#{trigger.id}"]}

              function_exported?(adapter, :event_references, 2) ->
                adapter.event_references(config, event)

              true ->
                {:ok, ["connector://#{config.id}/#{config.plugin_id}"]}
            end

          with {:ok, references} <- references,
               {:ok, _} <- emit(references, event) do
            {:ok,
             if(function_exported?(adapter, :webhook_response, 1),
               do: adapter.webhook_response(event),
               else: %{}
             )}
          end

        error ->
          error
      end
    else
      false -> {:error, :webhook_not_supported}
      error -> error
    end
  end

  defp emit(references, event) do
    Enum.reduce_while(references, {:ok, %{}}, fn reference, _ ->
      case Ankole.Signals.emit(reference, event) do
        {:ok, _} -> {:cont, {:ok, %{}}}
        error -> {:halt, error}
      end
    end)
  end
end
