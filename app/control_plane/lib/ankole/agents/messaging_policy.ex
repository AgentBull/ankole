defmodule Ankole.Agents.MessagingPolicy do
  @moduledoc "Owns which Agent roles may initiate peer work."

  def allow_peer_send?(sender_uid, target_uid, event) do
    with %{type: :personal_assistant, owner_principal_uid: owner} <-
           Ankole.Principals.get_agent_record!(sender_uid),
         %{type: :ai_colleague} <- Ankole.Principals.get_agent_record!(target_uid),
         {:ok, %{status: :active}} <- Ankole.Principals.get_principal(target_uid),
         true <- event.human_uid == owner and Ankole.Principals.WorkAccess.valid_now?(event),
         {:ok, human} <- Ankole.Principals.get_principal(owner),
         :ok <- Ankole.Conversations.authorize_agent(Ankole.AuthZ.Actor.new(human), target_uid) do
      true
    else
      _ -> false
    end
  end
end
