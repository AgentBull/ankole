defmodule Ankole.Conversations.HistoryPerfTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations
  alias Ankole.Conversations.{Conversation, Context, Message}

  test "history and unread reads remain bounded across 25000 retained statements" do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    id = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    assert {:ok, detail} =
             Repo.transact(fn _ ->
               Ankole.ConversationsFixtures.create(
                 human.uid,
                 %{
                   conversation_id: id,
                   message_id: Ecto.UUID.generate(),
                   agent_uid: agent.uid,
                   text: "Start"
                 }
               )
             end)

    rows =
      Enum.map(2..25_000, fn seq ->
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: Repo.tenant_id!(),
          conversation_id: id,
          seq: seq,
          origin: :native,
          author_type: :human,
          author_uid: human.uid,
          author_display_name: human.display_name,
          kind: :message,
          text: "Retained statement #{seq}",
          created_at: now
        }
      end)

    for batch <- Enum.chunk_every(rows, 1000), do: Repo.insert_all(Message, batch)
    Repo.update_all(where(Conversation, id: ^id), set: [sequence_high_water: 25_000])

    {history_us, history} = :timer.tc(fn -> Context.history_page(id, cursor: "20000") end)
    assert length(history.messages) == 200
    assert history.next_cursor == "20200"

    {unread_us, {:ok, unread}} =
      :timer.tc(fn ->
        Conversations.context_snapshot(
          id,
          %{agent_uid: agent.uid, session_id: "conversation:#{id}"},
          24_900,
          [],
          limit: 80
        )
      end)

    assert length(unread.messages) == 80
    assert Enum.map(unread.messages, & &1.seq) == Enum.to_list(24_921..25_000)
    assert unread.max_seq == 25_000
    assert detail.conversation.id == id
    tenant_id = Repo.tenant_id!()

    query =
      from m in Message,
        where: m.tenant_id == ^tenant_id and m.conversation_id == ^id and m.seq > 24_900,
        order_by: [desc: m.seq],
        limit: 80

    plan = Ecto.Adapters.SQL.explain(Repo, :all, query)
    assert plan =~ "Index"

    IO.puts(
      "conversation_history_25000: history_ms=#{history_us / 1000} unread_ms=#{unread_us / 1000}; bounded=200/80"
    )
  end
end
