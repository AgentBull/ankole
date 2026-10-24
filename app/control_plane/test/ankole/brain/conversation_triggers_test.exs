defmodule Ankole.Brain.ConversationTriggersTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Jobs.ProcessConversationSlice
  alias Ankole.Brain.ConversationTriggers

  test "an ended signal conversation enqueues slice processing for its channel" do
    channel = insert_channel!()
    conversation_key = Ankole.Sessions.Key.conversation(channel.id)

    assert :ok = ConversationTriggers.conversation_ended_in_tx(conversation_key)

    assert_enqueued(
      worker: ProcessConversationSlice,
      args: %{"conversation_id" => channel.id}
    )
  end

  test "non-channel conversation keys no-op" do
    assert :ok = ConversationTriggers.conversation_ended_in_tx("stateful-responses-api:x")
    assert :ok = ConversationTriggers.conversation_ended_in_tx("signal-channel:missing")

    refute_enqueued(worker: ProcessConversationSlice)
  end

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
      id: Ecto.UUID.generate(),
      external_kind: :im_group,
      provider_conversation_id: "lark:oc_trigger_#{System.unique_integer([:positive])}",
      title: "Learning Team",
      last_activity_at: now,
      reply_mode: :entry,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
  end
end
