defmodule Ankole.Conversations.Delivery.Deletion do
  @moduledoc """
  Provider deletion intents for the replies one Signal put in a conversation.

  Two callers erase an answer that already reached the chat: `/retry` replaces
  its own previous answer, and a recalled source entry erases the turn it
  started. Both must remove every entry that turn created, because the Agent no
  longer holds that answer in its conversation.

  A turn that never reaches terminal delivery has an open preview surface and no
  intent row that names it, so the checkpoint is a necessary third source.
  """

  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.ExternalMessageRef
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.PreviewAdapter

  @spec intents(module(), Ecto.UUID.t(), [binary()]) :: [map()]
  def intents(_repo, signal_id, ai_message_ids \\ [])
      when is_binary(signal_id) and is_list(ai_message_ids) do
    (mirrored_reply_targets(ai_message_ids) ++
       intent_reply_targets(signal_id) ++
       preview_surface_targets(signal_id))
    |> Enum.uniq_by(&{&1.conversation_id, &1.provider_message_id})
    |> Enum.sort_by(&{&1.conversation_id, &1.provider_message_id})
    |> Enum.map(&deletion_intent(&1, signal_id))
  end

  @doc "Commits provider removals before their source Signal is deleted."
  def commit_source_in_tx(repo, %Signal{} = input) do
    repo
    |> intents(input.id)
    |> Enum.map(fn intent ->
      intent
      |> Map.merge(%{
        agent_uid: input.agent_uid,
        binding_name: input.reply_binding_name,
        source_signal_id: input.id
      })
      |> then(&Ankole.Conversations.Delivery.commit_in_tx(repo, &1))
    end)
    |> Ankole.Attrs.collect_results()
  end

  defp mirrored_reply_targets([]), do: []

  defp mirrored_reply_targets(ai_message_ids) do
    ExternalMessageRef
    |> Ash.Query.filter(ai_message_id in ^ai_message_ids)
    |> Ash.Query.sort(conversation_id: :asc, provider_message_id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(fn entry ->
      %{
        conversation_id: entry.conversation_id,
        provider_thread_id: entry.provider_thread_id,
        provider_message_id: entry.provider_message_id,
        ai_message_id: entry.ai_message_id
      }
    end)
  end

  defp intent_reply_targets(signal_id) do
    Intent
    |> Ash.Query.filter(source_signal_id == ^signal_id and delivery_class == :durable_ai_reply)
    |> Ash.Query.sort(inserted_at: :asc, outbound_key: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(&intent_reply_target/1)
    |> Enum.reject(&is_nil/1)
  end

  defp intent_reply_target(
         %Intent{
           operation: :edit,
           conversation_id: conversation_id,
           target_provider_message_id: provider_message_id
         } = intent
       )
       when is_binary(conversation_id) and is_binary(provider_message_id) do
    %{
      conversation_id: conversation_id,
      provider_thread_id: intent.provider_thread_id,
      provider_message_id: provider_message_id,
      ai_message_id: intent.ai_message_id
    }
  end

  defp intent_reply_target(
         %Intent{
           operation: operation,
           conversation_id: conversation_id,
           created_provider_message_id: provider_message_id
         } = intent
       )
       when operation in [:post, :reply, :card, :divider] and is_binary(conversation_id) and
              is_binary(provider_message_id) do
    %{
      conversation_id: conversation_id,
      provider_thread_id: intent.provider_thread_id,
      provider_message_id: provider_message_id,
      ai_message_id: intent.ai_message_id
    }
  end

  defp intent_reply_target(_intent), do: nil

  defp preview_surface_targets(signal_id) do
    case PreviewState.load_signal(signal_id) do
      %Signal{conversation_id: conversation_id} = event
      when is_binary(conversation_id) ->
        event
        |> preview_surface_provider_message_ids()
        |> Enum.map(fn provider_message_id ->
          %{
            conversation_id: conversation_id,
            provider_thread_id: event.provider_thread_id,
            provider_message_id: provider_message_id,
            ai_message_id: nil
          }
        end)

      _absent ->
        []
    end
  end

  # The adapter that owns the checkpoint names the provider entries it holds.
  defp preview_surface_provider_message_ids(%Signal{} = event) do
    adapter = PreviewAdapter.for_event(event)
    checkpoint = PreviewState.get(event).checkpoint || %{}

    [
      PreviewState.get(event).provider_message_id
      | PreviewAdapter.surface_entry_ids(adapter, checkpoint)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp deletion_intent(target, signal_id) do
    outbound_key =
      case target.ai_message_id do
        ai_message_id when is_binary(ai_message_id) ->
          "ai-reply-retraction:#{ai_message_id}:#{target.provider_message_id}"

        nil ->
          "ai-reply-retraction:actor-event:#{signal_id}:#{target.provider_message_id}"
      end

    %{
      outbound_key: outbound_key,
      operation: :delete,
      conversation_id: target.conversation_id,
      provider_thread_id: target.provider_thread_id,
      reply_to_provider_message_id: nil,
      target_provider_message_id: target.provider_message_id,
      ai_message_id: target.ai_message_id,
      idempotency_key: outbound_key
    }
  end
end
