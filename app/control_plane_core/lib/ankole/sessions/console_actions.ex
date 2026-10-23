defmodule Ankole.Sessions.ConsoleActions do
  @moduledoc "Reads durable Agent Sessions and edits conversation standing orders."
  use Ash.Resource.Actions.Implementation
  alias Ankole.Sessions.{AmbientCuration, SessionQueries}
  alias Ankole.Errors
  @impl true
  def run(input, _opts, context), do: input |> execute(context) |> Errors.wrap(&describe/1)

  defp execute(%{action: %{name: :console_sessions}, arguments: %{agent_uid: uid}}, _),
    do: {:ok, %{sessions: SessionQueries.list_agent_sessions(uid)}}

  defp execute(%{action: %{name: :console_standing_orders}, arguments: %{conversation_id: id}}, _) do
    with {:ok, orders} <- AmbientCuration.conversation_standing_orders(id),
         do: {:ok, %{standing_orders: Ankole.JSON.plain(orders)}}
  end

  defp execute(%{action: %{name: :console_put_standing_orders}, arguments: attrs}, context) do
    actor = to_string(Ankole.ActorRef.from_principal(context.actor))

    with {:ok, orders} <-
           AmbientCuration.put_conversation_standing_orders(
             attrs.conversation_id,
             Map.get(attrs, :orders),
             actor
           ),
         do: {:ok, %{standing_orders: Ankole.JSON.plain(orders)}}
  end

  defp describe(:channel_not_found),
    do: Errors.Invalid.NotFound.exception(resource: Ankole.Conversations.Schemas.Conversation)

  defp describe(:standing_orders_too_long),
    do:
      {"Standing orders must contain at most 4000 characters",
       [%{path: "orders", message: "is too long"}]}

  defp describe(_), do: nil
end
