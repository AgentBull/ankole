defmodule Ankole.Brain.ConversationTriggers do
  @moduledoc """
  Learning triggers from conversation lifecycle events.

  Ending Session model history enqueues learning for its native or IM
  conversation. The idle-time sweep also processes conversations that
  have new statements but no Session ending.
  """

  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.ProcessConversationSlice
  alias Ankole.Conversations.Conversation

  @doc "Enqueues learning in the transaction that ends Session model history."
  def conversation_ended_in_tx(key) do
    with {:conversation, id} <- Ankole.Sessions.Key.parse(key),
         true <- Config.enabled?(),
         {:ok, %Conversation{} = conversation} <- Ankole.Conversations.get_conversation(id),
         true <- conversation.kind == :native or conversation.external_kind in [:im_dm, :im_group] do
      {:ok, _} = ProcessConversationSlice.enqueue(id)
      :ok
    else
      _ -> :ok
    end
  end
end
