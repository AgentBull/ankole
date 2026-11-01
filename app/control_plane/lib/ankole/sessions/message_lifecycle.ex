defmodule Ankole.Sessions.MessageLifecycle do
  @moduledoc false

  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.Deletion
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Schedule

  def process(%Signal{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Ankole.Repo.transact_top_level(fn -> process_in_tx(input, now) end)
    |> Ankole.Errors.reason()
    |> stop_removed_previews()
  end

  @doc false
  def process_in_tx(%Signal{} = input, now) do
    with %Signal{} = input <- Ankole.Signals.get_signal!(input.id),
         {:ok, cancelled_checkbacks} <-
           Schedule.cancel_checkbacks_for_provider_entry_in_tx(
             %{
               "agent_uid" => input.agent_uid,
               "session_id" => input.session_id,
               "binding_id" => input.reply_binding_id,
               "binding_name" => input.reply_binding_name,
               "provider_message_id" => input.provider_message_id
             },
             now
           ),
         :ok <- Queue.lock_session_in_tx(input.agent_uid, input.session_id),
         {:ok, superseded_interactions} <-
           Interactions.supersede_removed_source_in_tx(input, now),
         %Signal{} = input <- Ankole.Signals.lock_signal_in_tx(input.id) do
      ignore_lifecycle_event(
        input,
        cancelled_checkbacks,
        superseded_interactions,
        now
      )
    else
      nil -> {:ok, %{status: :idle}}
      {:error, _reason} = error -> error
    end
  end

  defp ignore_lifecycle_event(
         %Signal{} = input,
         cancelled_checkbacks,
         superseded_interactions,
         now
       ) do
    source_events = source_signals(input)

    with {:ok, aigateway_deletions} <-
           hard_delete_visible_aigateway_tail(source_events, now),
         deleted_answers = deleted_answer_events(source_events, aigateway_deletions),
         reply_deletions = reply_deletion_intents(deleted_answers),
         {:ok, completed_event} <- complete_lifecycle_event(input, now, reply_deletions) do
      {:ok,
       %{
         status: :entry_lifecycle_ignored,
         lifecycle_event: input,
         cancelled_checkbacks: cancelled_checkbacks,
         superseded_reply_interactions: length(superseded_interactions),
         aigateway_deletions: aigateway_deletions,
         reply_deletions: length(reply_deletions),
         removed_signal_ids: Enum.map(deleted_answers, fn {event, _ids} -> event.id end),
         signal: completed_event
       }}
    end
  end

  defp source_signals(%Signal{provider_message_id: provider_message_id} = input)
       when is_binary(provider_message_id) and provider_message_id != "" do
    Ankole.Signals.signals_for_entry_in_tx(
      input.agent_uid,
      input.reply_binding_id,
      input.conversation_id,
      provider_message_id
    )
  end

  defp source_signals(%Signal{}), do: []

  defp hard_delete_visible_aigateway_tail(source_events, now) do
    source_events
    |> Enum.map(
      &ModelHistory.delete_visible_turn_suffix_in_tx(
        &1.agent_uid,
        &1.session_id,
        &1.id,
        now
      )
    )
    |> Ankole.Attrs.collect_results()
  end

  # The channel keeps whatever the conversation keeps. An answer the removal
  # left in history stays in the channel; an answer it deleted leaves with it.
  defp deleted_answer_events(source_events, aigateway_deletions) do
    source_events
    |> Enum.zip(aigateway_deletions)
    |> Enum.flat_map(fn
      {event, %{status: :deleted, deleted_message_ids: ai_message_ids}} ->
        [{event, ai_message_ids}]

      {_event, _kept} ->
        []
    end)
  end

  defp reply_deletion_intents(deleted_answers) do
    deleted_answers
    |> Enum.flat_map(fn {event, ai_message_ids} ->
      Deletion.intents(event.id, ai_message_ids)
    end)
    |> Enum.uniq_by(& &1.outbound_key)
  end

  defp complete_lifecycle_event(%Signal{} = input, now, intents) do
    results =
      Enum.map(intents, fn attrs ->
        Map.merge(
          %{
            agent_uid: input.agent_uid,
            binding_id: input.reply_binding_id,
            binding_name: input.reply_binding_name,
            conversation_id: input.conversation_id,
            provider_thread_id: input.provider_thread_id,
            reply_to_provider_message_id: input.provider_message_id,
            source_signal_id: input.id
          },
          attrs
        )
        |> then(&Ankole.Conversations.Delivery.commit_in_tx(&1))
      end)

    with {:ok, _} <- Ankole.Attrs.collect_results(results),
         do: Queue.complete_entry_lifecycle_event_in_tx(input, completed_at: now)
  end

  # A preview that still holds an open card would keep editing an entry the
  # intent is about to delete.
  defp stop_removed_previews({:ok, %{removed_signal_ids: signal_ids}} = result) do
    Enum.each(signal_ids, &Preview.stop/1)
    result
  end

  defp stop_removed_previews(result), do: result
end
