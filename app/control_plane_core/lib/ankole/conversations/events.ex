defmodule Ankole.Conversations.Events do
  @moduledoc "Publishes committed public Conversation changes on tenant-scoped topics."

  alias Ankole.Repo

  def subscribe(id), do: Phoenix.PubSub.subscribe(Ankole.PubSub, topic(id))
  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Ankole.PubSub, topic(id))

  def publish_message(id), do: publish_committed([{id, :message}])
  def publish_status(id), do: publish_committed([{id, :status}])

  def subscribe_rooms,
    do: Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-conversations:#{Repo.tenant_id!()}")

  def publish_rooms_changed do
    Repo.assert_outside_transaction!()

    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      "pod-conversations:#{Repo.tenant_id!()}",
      {:pod_conversations_changed}
    )
  end

  @doc "The outer transaction owner calls this after its transaction succeeds."
  def publish_committed(publications) when is_list(publications) do
    Repo.assert_outside_transaction!()

    Enum.each(publications, fn {id, type} when type in [:message, :status] ->
      Phoenix.PubSub.broadcast(Ankole.PubSub, topic(id), {:conversation_event, id, type})
    end)

    if publications != [], do: publish_rooms_changed()

    :ok
  end

  defp topic(id), do: "conversation:#{Repo.tenant_id!()}:#{id}"
end
