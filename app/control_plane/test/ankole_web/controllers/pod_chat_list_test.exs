defmodule AnkoleWeb.PodChatListTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.Conversations
  @moduletag host: :pod

  test "recent order reads the globally latest rooms while pinned order and both cursors stay correct",
       %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)

    older = for index <- 1..4, do: create_room!(uid, agent.uid, "Pinned old room #{index}")
    latest = create_room!(uid, agent.uid, "Latest unpinned room")

    for id <- older,
        do: assert({:ok, _} = Conversations.update_conversation(actor, id, %{pinned: true}))

    pinned = api_response(api_get(conn, "/api/v2/pod/conversations", %{limit: 3}), 200)
    assert Enum.all?(pinned["conversations"], & &1["viewer"]["pinned"])
    refute Enum.any?(pinned["conversations"], &(&1["id"] == latest))

    recent =
      api_response(api_get(conn, "/api/v2/pod/conversations", %{order: "recent", limit: 3}), 200)

    assert Enum.map(recent["conversations"], & &1["id"]) == [
             latest | Enum.take(Enum.reverse(older), 2)
           ]

    next =
      api_response(
        api_get(conn, "/api/v2/pod/conversations", %{
          order: "recent",
          limit: 3,
          cursor: recent["nextCursor"]
        }),
        200
      )

    assert Enum.map(next["conversations"], & &1["id"]) == older |> Enum.take(2) |> Enum.reverse()
    assert is_nil(next["nextCursor"])

    next_pinned =
      api_response(
        api_get(conn, "/api/v2/pod/conversations", %{limit: 3, cursor: pinned["nextCursor"]}),
        200
      )

    assert [old, unpinned] = next_pinned["conversations"]
    assert old["viewer"]["pinned"]
    assert unpinned["id"] == latest

    # Opening an older room raises it in personal Recents without changing the IM activity order.
    visited = hd(older)
    assert {:ok, _} = Conversations.update_conversation(actor, visited, %{last_read_seq: 0})

    reopened =
      api_response(api_get(conn, "/api/v2/pod/conversations", %{order: "recent", limit: 1}), 200)

    assert [row] = reopened["conversations"]
    assert row["id"] == visited
    assert is_binary(row["viewer"]["lastVisitedAt"])

    after_visit =
      api_response(
        api_get(conn, "/api/v2/pod/conversations", %{
          order: "recent",
          limit: 1,
          cursor: reopened["nextCursor"]
        }),
        200
      )

    assert hd(after_visit["conversations"])["id"] == latest

    assistant =
      Ankole.SessionsCase.agent_fixture(%{type: :personal_assistant, owner_principal_uid: uid}).principal

    {:ok, task} =
      Ankole.ConversationsFixtures.create(uid, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: assistant.uid,
        text: "Private assistant work"
      })

    im = api_response(api_get(conn, "/api/v2/pod/conversations", %{imOnly: true}), 200)
    refute Enum.any?(im["conversations"], &(&1["id"] == task.conversation.id))
    assert length(im["conversations"]) == 5
  end

  defp create_room!(uid, agent, text) do
    assert {:ok, room} =
             Ankole.ConversationsFixtures.create(uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent,
               room_mode: :group,
               text: text
             })

    room.conversation.id
  end
end
