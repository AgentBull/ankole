defmodule Ankole.ConversationsHistoryTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations
  alias Ankole.Conversations.{Conversation, Message}
  alias Ankole.Signals.Signal

  test "history pages recover every visible statement without duplicates or withdrawn inputs" do
    human = human_fixture().principal
    stranger = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    id = Ankole.Kernel.gen_uuid_v7()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(human.uid, %{
        conversation_id: id,
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: agent.uid,
        text: "First statement"
      })

    now = DateTime.utc_now(:microsecond)

    rows =
      for sequence <- 2..1006 do
        %{
          tenant_id: Repo.tenant_id!(),
          id: Ankole.Kernel.gen_uuid_v7(),
          conversation_id: id,
          seq: sequence,
          author_type: :human,
          author_uid: human.uid,
          kind: :message,
          origin: :native,
          text: "Statement #{sequence}",
          attachments: [],
          links: [],
          mentions: [],
          created_at: now
        }
      end

    {1005, _} = Repo.insert_all(Message, rows)
    Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [sequence_high_water: 1006])

    # Keep the original accepted identity while simulating its committed removal.
    input = Repo.one!(from s in Signal, where: s.conversation_id == ^id)

    {:ok, _input} =
      Repo.transact(fn _ ->
        Ankole.Ash.update(input, :complete, %{
          data: Map.put(input.data, "removed", true),
          completed_at: now
        })
      end)

    {:ok, newest} = Conversations.get(human.uid, id)
    assert Enum.map(newest.messages, & &1.seq) == Enum.to_list(507..1006)
    assert newest.older_messages_before_seq == 507
    refute input.message_id in newest.removed_message_ids
    assert {:ok, reconciled} = Conversations.get(human.uid, id, loaded_first_seq: 1)
    assert input.message_id in reconciled.removed_message_ids

    {:ok, middle} = Conversations.get(human.uid, id, before_seq: newest.older_messages_before_seq)
    assert Enum.map(middle.messages, & &1.seq) == Enum.to_list(7..506)
    assert middle.older_messages_before_seq == 7

    {:ok, oldest} = Conversations.get(human.uid, id, before_seq: middle.older_messages_before_seq)
    assert Enum.map(oldest.messages, & &1.seq) == Enum.to_list(2..6)
    assert is_nil(oldest.older_messages_before_seq)

    assert MapSet.size(MapSet.new(oldest.messages ++ middle.messages ++ newest.messages, & &1.id)) ==
             1005

    assert {:error, :conversation_not_found} =
             Conversations.get(stranger.uid, id, before_seq: 507)

    assert {:error, :invalid_request} = Conversations.get(human.uid, id, before_seq: 0)
  end
end
