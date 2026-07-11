defmodule Ankole.AIGateway.Events do
  @moduledoc """
  Generic live response events scoped to an AIGateway conversation.

  Event routing never interprets caller metadata. Consumers subscribe only
  after proving ownership of the conversation.
  """

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses

  @pubsub Ankole.PubSub

  @type event_type ::
          :response_started
          | :output_text_delta
          | :tool_call_started
          | :tool_call_completed
          | :response_completed
          | :response_incomplete
          | :response_failed

  @type event :: %{
          required(:subject_uid) => String.t(),
          required(:conversation_id) => Ecto.UUID.t(),
          required(:response_id) => String.t(),
          required(:previous_response_id) => String.t() | nil,
          required(:metadata) => map(),
          required(:payload) => map()
        }

  @spec subscribe(String.t(), binary()) :: :ok | {:error, :invalid_conversation}
  def subscribe(subject_uid, conversation_id) do
    with {:ok, conversation} <-
           StatefulResponses.get_conversation_for_subject(subject_uid, conversation_id) do
      Phoenix.PubSub.subscribe(@pubsub, topic(conversation.subject_uid, conversation.id))
    end
  end

  @spec unsubscribe(String.t(), binary()) :: :ok | {:error, :invalid_conversation}
  def unsubscribe(subject_uid, conversation_id) do
    with {:ok, conversation} <-
           StatefulResponses.get_conversation_for_subject(subject_uid, conversation_id) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(conversation.subject_uid, conversation.id))
    end
  end

  @doc false
  @spec publish(Message.t(), event_type(), map()) :: :ok | {:error, term()}
  def publish(%Message{} = message, event_type, payload) when is_map(payload) do
    event = %{
      subject_uid: message.subject_uid,
      conversation_id: message.conversation_id,
      response_id: response_id(message.id),
      previous_response_id: optional_response_id(message.previous_message_id),
      metadata: StatefulResponses.response_metadata(message),
      payload: payload
    }

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(message.subject_uid, message.conversation_id),
      {:ai_gateway_event, event_type, event}
    )
  end

  defp topic(subject_uid, conversation_id),
    do: "ai_gateway:subject:#{subject_uid}:conversation:#{conversation_id}"

  defp response_id(id), do: "resp_#{id}"
  defp optional_response_id(nil), do: nil
  defp optional_response_id(id), do: response_id(id)
end
