defmodule AnkoleWeb.PodChatArtifactsTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  import Ecto.Query
  alias Ankole.{Conversations, Files, Repo}
  alias Ankole.Conversations.{Conversation, Message}
  alias Ankole.Pod.Pages

  @moduletag host: :pod

  test "the room summary keeps earlier artifacts beyond the visible history window", %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    assert {:ok, reference} = Pages.create(actor, %{title: "Original source"})

    bytes = "The original room attachment."
    local = Files.temp_path()
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)

    upload = %Plug.Upload{path: local, filename: "original.txt", content_type: "text/plain"}

    uploaded =
      post(conn, "/api/v2/pod/attachments", %{file: upload, fileID: Ecto.UUID.generate()})

    receipt = json_response(uploaded, 200)["receipt"]
    id = Ecto.UUID.generate()
    first_id = Ecto.UUID.generate()

    created =
      api_post(conn, "/api/v2/pod/conversations", %{
        conversationID: id,
        messageID: first_id,
        agentUID: agent.uid,
        pageID: reference.id,
        text: "Review the original source and attachment.",
        links: [%{kind: "page", id: reference.id}],
        attachments: [receipt]
      })
      |> api_response(200)

    [attachment] = hd(created["messages"])["attachments"]

    assert {:ok, saved} =
             Pages.create(actor, %{title: "Saved conclusion", saved_from_message_id: first_id})

    bob = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Bob"}).principal
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})

    assert {:ok, private} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(bob.uid), %{
               title: "Bob's private conclusion",
               private_owner_uid: bob.uid,
               saved_from_message_id: first_id
             })

    room = Conversations.get_conversation!(id)
    now = DateTime.utc_now(:microsecond)

    rows =
      for seq <- (room.sequence_high_water + 1)..(room.sequence_high_water + 501) do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: Repo.tenant_id!(),
          conversation_id: id,
          seq: seq,
          origin: :native,
          author_type: :human,
          author_uid: uid,
          author_display_name: "Room owner",
          kind: :message,
          text: "Later discussion #{seq}",
          created_at: now
        }
      end

    Repo.insert_all(Message, rows)

    Repo.update_all(where(Conversation, id: ^id),
      set: [sequence_high_water: room.sequence_high_water + 501]
    )

    latest = api_get(conn, "/api/v2/pod/conversations/#{id}") |> api_response(200)
    assert length(latest["messages"]) == 500
    refute Enum.any?(latest["messages"], &(&1["id"] == first_id))
    assert is_integer(latest["olderMessagesBeforeSeq"])

    artifacts = latest["artifacts"]
    assert MapSet.new(artifacts["pageIDs"]) == MapSet.new([reference.id, saved.id])
    assert length(artifacts["pageIDs"]) == 2
    refute private.id in artifacts["pageIDs"]

    assert [%{"messageID" => ^first_id, "attachments" => [^attachment]}] =
             artifacts["attachments"]

    earlier =
      api_get(conn, "/api/v2/pod/conversations/#{id}", %{
        beforeSeq: latest["olderMessagesBeforeSeq"]
      })
      |> api_response(200)

    assert earlier["artifacts"] == artifacts

    download =
      get(conn, "/api/v2/pod/conversations/#{id}/attachments/#{first_id}", %{
        path: attachment["path"]
      })

    assert response(download, 200) == bytes

    assert {:ok, other} =
             Ankole.ConversationsFixtures.create(uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent.uid,
               text: "Unrelated room"
             })

    unrelated =
      api_get(conn, "/api/v2/pod/conversations/#{other.conversation.id}") |> api_response(200)

    assert unrelated["artifacts"] == %{"pageIDs" => [], "attachments" => []}
  end
end
