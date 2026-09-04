defmodule Ankole.SignalsGateway.ActorRuntime.ReplyDeletion do
  @moduledoc """
  Provider deletion intents for the replies one Actor event put in a channel.

  Two callers erase an answer that already reached the chat: `/retry` replaces
  its own previous answer, and a recalled source entry erases the turn it
  started. Both must remove every entry that turn created, because the Agent no
  longer holds that answer in its conversation.

  A turn that never reaches terminal delivery has an open preview surface and no
  outbox row that names it, so the checkpoint is a necessary third source.
  """

  import Ecto.Query

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  @spec outbox_intents(module(), Ecto.UUID.t(), [binary()]) :: [map()]
  def outbox_intents(repo, actor_event_id, ai_message_ids \\ [])
      when is_binary(actor_event_id) and is_list(ai_message_ids) do
    (mirrored_reply_targets(repo, ai_message_ids) ++
       outbox_reply_targets(repo, actor_event_id) ++
       preview_surface_targets(repo, actor_event_id))
    |> Enum.uniq_by(&{&1.signal_channel_id, &1.source_entry_id})
    |> Enum.sort_by(&{&1.signal_channel_id, &1.source_entry_id})
    |> Enum.map(&deletion_intent(&1, actor_event_id))
  end

  defp mirrored_reply_targets(_repo, []), do: []

  defp mirrored_reply_targets(repo, ai_message_ids) do
    Entry
    |> where([entry], entry.ai_message_id in ^ai_message_ids)
    |> order_by([entry], asc: entry.signal_channel_id, asc: entry.source_entry_id)
    |> repo.all()
    |> Enum.map(fn entry ->
      %{
        signal_channel_id: entry.signal_channel_id,
        provider_thread_id: entry.provider_thread_id,
        source_entry_id: entry.source_entry_id,
        ai_message_id: entry.ai_message_id
      }
    end)
  end

  defp outbox_reply_targets(repo, actor_event_id) do
    OutboxEntry
    |> where([outbox], outbox.source_actor_event_id == ^actor_event_id)
    |> where([outbox], outbox.delivery_class == :durable_ai_reply)
    |> order_by([outbox], asc: outbox.inserted_at, asc: outbox.outbound_key)
    |> repo.all()
    |> Enum.map(&outbox_reply_target/1)
    |> Enum.reject(&is_nil/1)
  end

  defp outbox_reply_target(
         %OutboxEntry{
           operation: :edit,
           signal_channel_id: signal_channel_id,
           target_source_entry_id: source_entry_id
         } = outbox
       )
       when is_binary(signal_channel_id) and is_binary(source_entry_id) do
    %{
      signal_channel_id: signal_channel_id,
      provider_thread_id: outbox.provider_thread_id,
      source_entry_id: source_entry_id,
      ai_message_id: outbox.ai_message_id
    }
  end

  defp outbox_reply_target(
         %OutboxEntry{
           operation: operation,
           signal_channel_id: signal_channel_id,
           created_source_entry_id: source_entry_id
         } = outbox
       )
       when operation in [:post, :reply, :card, :divider] and is_binary(signal_channel_id) and
              is_binary(source_entry_id) do
    %{
      signal_channel_id: signal_channel_id,
      provider_thread_id: outbox.provider_thread_id,
      source_entry_id: source_entry_id,
      ai_message_id: outbox.ai_message_id
    }
  end

  defp outbox_reply_target(_outbox), do: nil

  defp preview_surface_targets(repo, actor_event_id) do
    case repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{signal_channel_id: signal_channel_id} = event
      when is_binary(signal_channel_id) ->
        event
        |> preview_surface_source_entry_ids()
        |> Enum.map(fn source_entry_id ->
          %{
            signal_channel_id: signal_channel_id,
            provider_thread_id: event.provider_thread_id,
            source_entry_id: source_entry_id,
            ai_message_id: nil
          }
        end)

      _absent ->
        []
    end
  end

  # The adapter that owns the checkpoint names the provider entries it holds.
  defp preview_surface_source_entry_ids(%ActorEvent{} = event) do
    adapter = ReplyPreviewAdapter.for_event(event)
    checkpoint = event.reply_preview_checkpoint || %{}

    [
      event.reply_preview_source_entry_id
      | ReplyPreviewAdapter.surface_entry_ids(adapter, checkpoint)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp deletion_intent(target, actor_event_id) do
    outbound_key =
      case target.ai_message_id do
        ai_message_id when is_binary(ai_message_id) ->
          "ai-reply-retraction:#{ai_message_id}:#{target.source_entry_id}"

        nil ->
          "ai-reply-retraction:actor-event:#{actor_event_id}:#{target.source_entry_id}"
      end

    %{
      outbound_key: outbound_key,
      operation: :delete,
      signal_channel_id: target.signal_channel_id,
      provider_thread_id: target.provider_thread_id,
      reply_to_source_entry_id: nil,
      target_source_entry_id: target.source_entry_id,
      ai_message_id: target.ai_message_id,
      idempotency_key: outbound_key
    }
  end
end
