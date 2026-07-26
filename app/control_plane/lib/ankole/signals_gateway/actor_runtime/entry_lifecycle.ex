defmodule Ankole.SignalsGateway.ActorRuntime.EntryLifecycle do
  @moduledoc false

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.ReplyDeletion
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.ReplyInteractions
  alias Ankole.Repo
  alias Ankole.Schedule

  def process(%ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with :ok <- Actors.lock_actor_session_in_tx(repo, input.agent_uid, input.session_id),
           %ActorEvent{} = input <- Actors.lock_actor_event_in_tx(repo, input.id),
           {:ok, cancelled_checkbacks} <-
             Schedule.cancel_checkbacks_for_provider_entry_in_tx(
               repo,
               %{
                 "agent_uid" => input.agent_uid,
                 "session_id" => input.session_id,
                 "binding_name" => input.binding_name,
                 "source_entry_id" => input.source_entry_id
               },
               now
             ),
           {:ok, superseded_interactions} <-
             ReplyInteractions.supersede_removed_source_in_tx(repo, input, now) do
        ignore_lifecycle_event(
          repo,
          input,
          cancelled_checkbacks,
          superseded_interactions,
          now
        )
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> stop_removed_previews()
  end

  defp ignore_lifecycle_event(
         repo,
         %ActorEvent{} = input,
         cancelled_checkbacks,
         superseded_interactions,
         now
       ) do
    source_events = source_actor_events(repo, input)

    with {:ok, aigateway_deletions} <-
           hard_delete_visible_aigateway_tail(repo, source_events, now),
         deleted_answers = deleted_answer_events(source_events, aigateway_deletions),
         reply_deletions = reply_deletion_intents(repo, deleted_answers),
         {:ok, completed_event} <- complete_lifecycle_event(repo, input, now, reply_deletions) do
      {:ok,
       %{
         status: :entry_lifecycle_ignored,
         lifecycle_event: input,
         cancelled_checkbacks: cancelled_checkbacks,
         superseded_reply_interactions: length(superseded_interactions),
         aigateway_deletions: aigateway_deletions,
         reply_deletions: length(reply_deletions),
         removed_actor_event_ids: Enum.map(deleted_answers, fn {event, _ids} -> event.id end),
         actor_event: completed_event
       }}
    end
  end

  defp source_actor_events(repo, %ActorEvent{source_entry_id: source_entry_id} = input)
       when is_binary(source_entry_id) and source_entry_id != "" do
    Actors.actor_events_for_entry_in_tx(
      repo,
      input.agent_uid,
      input.binding_name,
      input.signal_channel_id,
      source_entry_id
    )
  end

  defp source_actor_events(_repo, %ActorEvent{}), do: []

  defp hard_delete_visible_aigateway_tail(repo, source_events, now) do
    source_events
    |> Enum.map(
      &AIGatewayLink.delete_visible_turn_suffix_in_tx(
        repo,
        &1.agent_uid,
        &1.session_id,
        &1.id,
        now
      )
    )
    |> collect_results()
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

  defp reply_deletion_intents(repo, deleted_answers) do
    deleted_answers
    |> Enum.flat_map(fn {event, ai_message_ids} ->
      ReplyDeletion.outbox_intents(repo, event.id, ai_message_ids)
    end)
    |> Enum.uniq_by(& &1.outbound_key)
  end

  defp complete_lifecycle_event(repo, %ActorEvent{} = input, now, outbox_intents) do
    Actors.complete_entry_lifecycle_event_in_tx(repo, input,
      completed_at: now,
      outbox_intents: outbox_intents
    )
  end

  # A preview that still holds an open card would keep editing an entry the
  # outbox is about to delete.
  defp stop_removed_previews({:ok, %{removed_actor_event_ids: actor_event_ids}} = result) do
    Enum.each(actor_event_ids, &AIReplyPreview.stop/1)
    result
  end

  defp stop_removed_previews(result), do: result

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
