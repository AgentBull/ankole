defmodule Ankole.Pod.Chat.Presentation do
  @moduledoc "The browser projection of conversation history and the active input queue."
  def detail(detail) do
    %{
      conversation: conversation(detail),
      messages: Enum.map(detail.messages, &message_json/1),
      olderMessagesBeforeSeq: detail.older_messages_before_seq,
      removedMessageIDs: detail.removed_message_ids,
      messageRange: %{
        firstSeq: detail.message_range.first_seq,
        lastSeq: detail.message_range.last_seq
      },
      queueVersion: detail.queue_version,
      retryableMessageID: detail.retryable_message_id,
      queuePaused: detail.conversation.metadata["queue_paused"] == true,
      pendingInputs:
        Enum.map(detail.pending_inputs, fn input ->
          %{
            messageID: input.message_id,
            text: input.data["text"] || "",
            attachments: get_in(input.data, ["entry", "attachments"]) || [],
            modelProfile: input.data["model_profile"] || "primary",
            deliveryMode: input.data["delivery_mode"] || "steer"
          }
        end),
      status: %{
        state: to_string(detail.status.state),
        retryAt: timestamp(detail.status.retry_at),
        activity:
          elem(
            Ankole.Sessions.Activity.current(%{
              agent_uid: detail.agent.uid,
              session_id: detail.session_id
            }),
            0
          )
      }
    }
  end

  def conversation(%{conversation: conversation, agent: agent}) do
    %{
      id: conversation.id,
      title: conversation.title,
      pageID: conversation.page_id,
      agent: Map.put(agent(agent), :active, agent.status == :active),
      lastActivityAt: timestamp(conversation.last_activity_at)
    }
  end

  def agent(agent), do: %{uid: agent.uid, displayName: agent.display_name}

  defp message_json(message) do
    %{
      id: message.id,
      seq: message.seq,
      authorType: to_string(message.author_type),
      authorUID: message.author_uid,
      kind: to_string(message.kind),
      text: message.text || "",
      links: message.links,
      attachments: message.attachments,
      createdAt: timestamp(message.created_at),
      signalID: message.signal_id,
      replyToMessageID: message.reply_to_message_id
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
