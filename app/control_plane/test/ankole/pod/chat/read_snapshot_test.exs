defmodule Ankole.Pod.Chat.ReadSnapshotTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations
  alias Ankole.Pod.Chat.Presentation

  test "room list reads stay bounded as the number of rooms grows" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    actor = actor_fixture(human)
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    for number <- 1..12 do
      assert {:ok, _} =
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: Ash.UUIDv7.generate(),
                 message_id: Ash.UUIDv7.generate(),
                 agent_uid: agent.uid,
                 text: "Room #{number}"
               })
    end

    {one, one_count} =
      queries(fn ->
        Conversations.list_rooms(actor, limit: 1) |> Presentation.conversations()
      end)

    {many, many_count} =
      queries(fn ->
        Conversations.list_rooms(actor, limit: 12) |> Presentation.conversations()
      end)

    assert length(one) == 1
    assert length(many) == 12
    assert one_count > 0
    assert many_count <= one_count + 2, "one room: #{one_count}, twelve rooms: #{many_count}"
    assert many_count < 30
    assert Enum.all?(many, &(&1.rowStatus == "unread"))
  end

  test "detail projection keeps the queue and references from its original snapshot" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    actor = actor_fixture(human)
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: agent.uid,
               text: "Queued request"
             })

    id = detail.conversation.id
    [input] = detail.pending_inputs

    assert {:ok, current} =
             Conversations.update_queue(actor, id, %{
               agent_uid: agent.uid,
               action: "retract",
               message_id: input.message_id,
               expected_version: detail.queue_versions[agent.uid]
             })

    assert current.pending_inputs == []

    {projection, count} = queries(fn -> Presentation.detail(detail) end)
    assert count == 0

    assert [%{queueVersion: version, inputs: [%{messageID: message_id}]}] =
             projection.pendingQueues

    assert version == detail.queue_versions[agent.uid]
    assert message_id == input.message_id
  end

  defp queries(fun) do
    observer = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:ankole, :repo, :query],
        fn _, _, _, _ ->
          if self() == observer, do: send(observer, ref)
        end,
        nil
      )

    try do
      value = fun.()
      {value, drain(ref, 0)}
    after
      :telemetry.detach(ref)
    end
  end

  defp drain(ref, count) do
    receive do
      ^ref -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
