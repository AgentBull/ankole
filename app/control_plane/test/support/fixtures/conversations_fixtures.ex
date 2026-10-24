defmodule Ankole.ConversationsFixtures do
  @moduledoc false
  alias Ankole.Conversations.{PostResult, Statement}
  alias Ankole.Conversations.Target, as: StatementTarget

  def post_statement_in_tx(event, text, opts \\ []) do
    target =
      case Keyword.fetch(opts, :conversation_id) do
        {:ok, id} ->
          StatementTarget.for_delivery_in_tx(event.agent_uid, %{conversation_id: id})

        :error ->
          StatementTarget.for_reply(event)
      end

    with :ok <- Ankole.Sessions.Queue.lock_session_in_tx(event.agent_uid, event.session_id),
         {:ok, target} <- target,
         {:ok, %PostResult{} = result} <-
           Ankole.Conversations.post_in_tx(target, %Statement{
             signal: event,
             text: text,
             notice: if(opts[:kind] == :notice, do: %{})
           }) do
      {:ok, result}
    end
  end

  def create(human, attrs) do
    Ankole.Repo.transact(fn ->
      with {:ok, %{id: id}} <- Ankole.Conversations.create_in_tx(human, attrs),
           do: Ankole.Conversations.detail_in_tx(human, id, [])
    end)
  end

  def post(human, id, attrs) do
    Ankole.Repo.transact(fn ->
      with {:ok, _} <- Ankole.Conversations.post_in_tx(human, id, attrs),
           do: Ankole.Conversations.detail_in_tx(human, id, [])
    end)
  end
end
