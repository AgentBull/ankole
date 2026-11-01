defmodule Ankole.Sessions.SessionReset do
  @moduledoc false

  alias Ankole.AIGateway
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal

  def process_due(session_key, %Signal{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Ankole.Repo.transact_top_level(fn ->
      process_due_in_tx(session_key, input, now)
    end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def process_due_in_tx(session_key, %Signal{} = input, now) do
    with :ok <- Queue.lock_session_in_tx(input.agent_uid, input.session_id),
         %Signal{} = input <- Ankole.Signals.lock_signal_in_tx(input.id),
         {:ok, closed_conversation} <- close_current_session_for_reset(session_key, now),
         {:ok, conversation} <-
           ensure_successor_conversation(session_key, closed_conversation),
         {:ok, superseded_interactions} <-
           Interactions.supersede_for_session_reset_in_tx(input, now),
         {:ok, completed_event} <-
           Queue.complete_session_lifecycle_event_in_tx(input, completed_at: now) do
      {:ok,
       %{
         status: :session_reset,
         reset_event: input,
         closed_conversation: closed_conversation,
         conversation: conversation,
         superseded_reply_interactions: length(superseded_interactions),
         signal: completed_event
       }}
    else
      nil ->
        {:ok, %{status: :idle}}

      {:error, _reason} = error ->
        error
    end
  end

  defp close_current_session_for_reset(session_key, now) do
    case AIGateway.active_conversation_for_update(
           session_key.agent_uid,
           session_key.session_id
         ) do
      %{} ->
        with {:ok, conversation} <-
               ModelHistory.end_active_conversation_in_tx(
                 session_key.agent_uid,
                 session_key.session_id,
                 now
               ) do
          {:ok, conversation}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp ensure_successor_conversation(_session_key, nil), do: {:ok, nil}

  defp ensure_successor_conversation(session_key, %{} = previous_conversation) do
    AIGateway.ensure_conversation_in_tx(
      session_key.agent_uid,
      session_key.session_id,
      ModelHistory.successor_origin_metadata(previous_conversation)
    )
  end
end
