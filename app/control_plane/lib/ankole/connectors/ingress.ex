defmodule Ankole.Connectors.Ingress do
  @moduledoc "Verifies a tenant-bound provider event before its durable Signal fanout."
  alias Ankole.Connectors.{Credentials, Registry, Store, Triggers}

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
