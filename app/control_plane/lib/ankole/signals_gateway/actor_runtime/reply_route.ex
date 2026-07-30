defmodule Ankole.SignalsGateway.ActorRuntime.ReplyRoute do
  @moduledoc """
  Resolves and validates the provider reply route owned by the current turn.

  Worker requests can repeat the route for an RPC method, but the durable
  ActorEvent remains the authority. A request cannot redirect later work to a
  different binding, channel, thread, or source entry.
  """

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  @type source :: %{
          actor_event_id: Ecto.UUID.t(),
          binding_name: String.t(),
          signal_channel_id: String.t() | nil,
          provider_thread_id: String.t() | nil,
          source_entry_id: String.t() | nil
        }

  @doc """
  Resolves the durable reply route for one turn.
  """
  @spec source(%{actor_event_id: Ecto.UUID.t()}) ::
          {:ok, source()} | {:error, :reply_route_not_in_turn}
  def source(%{actor_event_id: actor_event_id}) when is_binary(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        {:ok,
         %{
           actor_event_id: event.id,
           binding_name: event.binding_name,
           signal_channel_id: event.signal_channel_id,
           provider_thread_id: event.provider_thread_id,
           source_entry_id: event.source_entry_id
         }}

      nil ->
        {:error, :reply_route_not_in_turn}
    end
  end

  def source(_turn), do: {:error, :reply_route_not_in_turn}

  @doc """
  Confirms that a worker-supplied route equals the current ActorEvent route.
  """
  @spec validate(map(), map()) :: {:ok, source()} | {:error, term()}
  def validate(_turn, route) when not is_map(route), do: {:error, :invalid_reply_route}

  def validate(turn, route) do
    with {:ok, source} <- source(turn),
         true <- matches?(source, route) do
      {:ok, source}
    else
      false -> {:error, :reply_route_not_in_turn}
      {:error, _reason} = error -> error
    end
  end

  defp matches?(source, route) do
    RPCWire.text(route, "binding_name") == source.binding_name and
      RPCWire.text(route, "signal_channel_id") == source.signal_channel_id and
      RPCWire.text(route, "provider_thread_id") == source.provider_thread_id and
      RPCWire.text(route, "source_entry_id") == source.source_entry_id
  end
end
