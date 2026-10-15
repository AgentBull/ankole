defmodule Ankole.ConversationsFixtures do
  @moduledoc false
  alias Ankole.Conversations.{PostResult, Statement, Target}

  def post_statement_in_tx(repo, event, text, opts \\ []) do
    target =
      case Keyword.fetch(opts, :conversation_id) do
        {:ok, id} -> Target.for_delivery_in_tx(repo, event.agent_uid, %{conversation_id: id})
        :error -> Target.for_reply(repo, event)
      end

    with :ok <- Ankole.Sessions.Queue.lock_session_in_tx(repo, event.agent_uid, event.session_id),
         {:ok, target} <- target,
         {:ok, %PostResult{} = result} <-
           Ankole.Conversations.post_in_tx(repo, target, %Statement{
             signal: event,
             text: text,
             notice: if(opts[:kind] == :notice, do: %{})
           }) do
      {:ok, result}
    end
  end

  def create(human, attrs) do
    Ankole.Repo.transact(fn repo ->
      with {:ok, %{id: id}} <- Ankole.Conversations.create_in_tx(repo, human, attrs),
           do: Ankole.Conversations.get(human, id)
    end)
  end

  def post(human, id, attrs) do
    Ankole.Repo.transact(fn repo ->
      with {:ok, _} <- Ankole.Conversations.post_in_tx(repo, human, id, attrs),
           do: Ankole.Conversations.get(human, id)
    end)
  end
end
