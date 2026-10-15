defmodule Ankole.Conversations.ExternalTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations.{Conversation, External, ExternalMessageRef, Message, Participant}
  alias Ankole.Signals.Binding

  @now ~U[2026-10-14 10:00:00.000000Z]

  setup do
    %{principal: agent} = agent_fixture()

    {:ok, binding} =
      %Binding{}
      |> Binding.changeset(%{
        agent_uid: agent.uid,
        name: "external",
        adapter: "mock",
        config_ref: "app-config://external-test"
      })
      |> Repo.insert()

    {:ok, conversation} =
      Repo.transact(fn repo ->
        External.observe_conversation_in_tx(
          repo,
          binding,
          %{
            provider_conversation_id: "mock:room",
            external_kind: :im_group,
            title: "Shared room",
            reply_mode: :channel,
            metadata: %{"topic" => "Team"}
          },
          @now
        )
      end)

    %{agent: agent, binding: binding, conversation: conversation}
  end

  test "unknown authors and attachment-only observations remain public facts", %{conversation: c} do
    assert {:ok, %{message: message, external_ref: ref}} =
             observe(c.id, %{
               provider_message_id: "attachment",
               text: nil,
               attachments: [%{"name" => "spec.pdf", "provider_file_id" => "file-1"}],
               author: %{"id" => "unmapped", "display_name" => "External person"},
               raw_payload: %{"opaque" => true}
             })

    assert message.origin == :external
    assert message.author_type == :unknown
    assert is_nil(message.author_uid)
    assert is_nil(message.text)
    assert [%{"attachment_id" => id, "name" => "spec.pdf"}] = message.attachments
    assert id >= 10_000
    assert ref.author["id"] == "unmapped"
    assert ref.raw_payload == %{"opaque" => true}
    assert [%{message: ^message, external_ref: ^ref}] = External.list_messages(Repo, c.id)
  end

  test "provider redelivery and edits keep the Message UUID, seq, and attachment identity", %{
    conversation: c
  } do
    observation = %{
      provider_message_id: "same",
      text: "First",
      attachments: [%{"provider_file_id" => "file-1", "name" => "spec.pdf"}]
    }

    assert {:ok, first} = observe(c.id, observation)
    assert {:ok, again} = observe(c.id, %{observation | text: "Edited"})
    assert again.message.id == first.message.id
    assert again.message.seq == first.message.seq
    assert again.message.attachments == first.message.attachments
    assert again.message.text == "Edited"
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(ExternalMessageRef, :count) == 1
  end

  test "late observations cannot replace newer provider content", %{conversation: c} do
    assert {:ok, first} =
             observe(c.id, %{provider_message_id: "same", text: "Current", provider_time: @now})

    assert {:ok, %{status: :unchanged} = stale} =
             observe(c.id, %{
               provider_message_id: "same",
               text: "Old",
               provider_time: DateTime.add(@now, -10, :second)
             })

    assert stale.message == first.message
    assert stale.external_ref == first.external_ref
  end

  test "reaction redelivery folds one actor and plain observations preserve reactions", %{
    conversation: c
  } do
    assert {:ok, first} = observe(c.id, %{provider_message_id: "react", text: "Text"})

    reaction = %{
      action: :add,
      reaction_key: "thumbs-up",
      actor_key: "external-human",
      raw_reaction_key: "👍"
    }

    for _ <- 1..2 do
      assert {:ok, _} =
               Repo.transact(&External.fold_reaction_in_tx(&1, c.id, "react", reaction, @now))
    end

    assert {:ok, _} = observe(c.id, %{provider_message_id: "react", text: "Edited"})
    ref = External.get_message(Repo, c.id, "react").external_ref
    assert ref.reactions == %{"thumbs-up" => ["external-human"]}
    assert ref.message_id == first.message.id

    assert {:ok, _} =
             Repo.transact(
               &External.fold_reaction_in_tx(
                 &1,
                 c.id,
                 "react",
                 %{reaction | action: :remove},
                 @now
               )
             )

    assert External.get_message(Repo, c.id, "react").external_ref.reactions == %{}
    assert Repo.aggregate(Message, :count) == 1
  end

  test "confirmed delivery and its later provider push share one Message", %{
    conversation: c,
    agent: agent
  } do
    assert {:ok, final} =
             Repo.transact(fn repo ->
               External.record_delivery_in_tx(
                 repo,
                 c.id,
                 %{
                   provider_message_id: "sent",
                   text: "Reply",
                   author: %{"agent_uid" => agent.uid}
                 },
                 @now
               )
             end)

    assert {:ok, pushed} =
             observe(c.id, %{
               provider_message_id: "sent",
               text: "Reply",
               author: %{"id" => "provider-bot"}
             })

    assert pushed.message.id == final.message.id
    assert pushed.message.author_type == :agent
    assert pushed.message.author_uid == agent.uid
    assert Repo.aggregate(Message, :count) == 1
  end

  test "removing the tail never reuses a sequence already read by Session or Brain", %{
    conversation: c
  } do
    assert {:ok, first} = observe(c.id, %{provider_message_id: "first", text: "First"})
    assert {:ok, tail} = observe(c.id, %{provider_message_id: "tail", text: "Tail"})
    read_watermark = tail.message.seq
    assert {:ok, _} = Repo.transact(&External.remove_in_tx(&1, c.id, "tail"))
    assert {:ok, later} = observe(c.id, %{provider_message_id: "later", text: "Later"})
    assert later.message.seq > read_watermark
    assert later.message.seq > first.message.seq
    assert [%{message: %{id: id}}] = External.list_messages(Repo, c.id, after_seq: read_watermark)
    assert id == later.message.id
    assert Repo.get_by!(Conversation, id: c.id).sequence_high_water == later.message.seq
  end

  test "known reply relationships use Message UUIDs, and missing parents retain provider references",
       %{conversation: c} do
    assert {:ok, parent} = observe(c.id, %{provider_message_id: "parent", text: "Parent"})

    assert {:ok, reply} =
             observe(c.id, %{
               provider_message_id: "reply",
               text: "Reply",
               reply_to_provider_message_id: "parent"
             })

    assert reply.message.reply_to_message_id == parent.message.id

    assert {:ok, missing} =
             observe(c.id, %{
               provider_message_id: "missing",
               text: "Reply",
               reply_to_provider_message_id: "not-observed"
             })

    assert is_nil(missing.message.reply_to_message_id)
    assert missing.external_ref.reply_to_provider_message_id == "not-observed"
  end

  test "deleting an observation Binding preserves the shared platform history", %{
    conversation: c,
    binding: binding
  } do
    assert {:ok, observed} = observe(c.id, %{provider_message_id: "same", text: "History"})
    assert {:ok, _} = Repo.delete(binding)
    assert Repo.get_by!(Conversation, id: c.id).provider_conversation_id == "mock:room"
    assert External.get_message(Repo, c.id, "same").message.id == observed.message.id

    assert {:ok, _} = observe(c.id, %{provider_message_id: "later", text: "Another observer"})
  end

  test "two Agents observe one room and one Message instead of splitting history", %{
    conversation: c,
    agent: agent
  } do
    %{principal: another} = agent_fixture()

    assert {:ok, same} =
             Repo.transact(fn repo ->
               External.observe_conversation_in_tx(
                 repo,
                 %{agent_uid: another.uid},
                 %{
                   provider_conversation_id: "mock:room",
                   external_kind: :im_group,
                   reply_mode: :channel
                 },
                 @now
               )
             end)

    assert same.id == c.id
    assert Repo.aggregate(Conversation, :count) == 1

    participants =
      Repo.all(
        from p in Participant,
          where: p.conversation_id == ^c.id and p.role == :agent,
          select: p.principal_uid
      )

    assert Enum.sort(participants) == Enum.sort([agent.uid, another.uid])
    assert {:ok, first} = observe(c.id, %{provider_message_id: "shared", text: "One fact"})
    assert {:ok, second} = observe(same.id, %{provider_message_id: "shared", text: "One fact"})
    assert second.message.id == first.message.id
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(ExternalMessageRef, :count) == 1
  end

  test "deleting an Agent removes its participation while keeping external statements", %{
    conversation: c,
    agent: agent
  } do
    assert {:ok, observed} =
             observe(c.id, %{
               provider_message_id: "old-agent",
               text: "History",
               author: %{"agent_uid" => agent.uid}
             })

    assert {:ok, _} = Repo.delete(agent)
    assert Repo.get_by!(Conversation, id: c.id).provider_conversation_id == "mock:room"

    assert Repo.all(
             from p in Participant,
               where: p.conversation_id == ^c.id and p.principal_uid == ^agent.uid
           ) == []

    remaining = External.get_message(Repo, c.id, "old-agent")
    assert remaining.message.id == observed.message.id
    assert is_nil(remaining.message.author_uid)
    assert remaining.external_ref.author["agent_uid"] == agent.uid

    assert {:ok, pushed} =
             observe(c.id, %{
               provider_message_id: "old-agent",
               text: "History",
               author: %{"id" => "platform-bot"}
             })

    assert pushed.message.id == observed.message.id
    assert pushed.message.author_type == :agent
    assert is_nil(pushed.message.author_uid)
  end

  test "deleting a mapped author preserves the external statement and original author", %{
    conversation: c
  } do
    %{principal: human} = human_fixture()
    author = %{"principal_uid" => human.uid, "display_name" => "Former colleague"}

    assert {:ok, observed} =
             observe(c.id, %{provider_message_id: "same", text: "History", author: author})

    assert observed.message.author_type == :human
    assert {:ok, _} = Repo.delete(human)
    remaining = External.get_message(Repo, c.id, "same")
    assert remaining.message.id == observed.message.id
    assert is_nil(remaining.message.author_uid)
    assert remaining.external_ref.author == author
  end

  test "public records roll back with the caller's failed acceptance transaction", %{
    conversation: c
  } do
    assert {:error, :signal_rejected} =
             Repo.transact(fn repo ->
               assert {:ok, _} =
                        External.observe_in_tx(
                          repo,
                          c.id,
                          %{provider_message_id: "rollback", text: "Never accepted"},
                          @now
                        )

               {:error, :signal_rejected}
             end)

    assert is_nil(External.get_message(Repo, c.id, "rollback"))
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(ExternalMessageRef, :count) == 0
  end

  test "sparse conversation observations preserve known platform facts", %{
    conversation: c,
    binding: binding
  } do
    assert {:ok, updated} =
             Repo.transact(fn repo ->
               External.observe_conversation_in_tx(
                 repo,
                 binding,
                 %{
                   provider_conversation_id: "mock:room",
                   external_kind: :unknown,
                   reply_mode: :none,
                   metadata: %{}
                 },
                 DateTime.add(@now, 1, :second)
               )
             end)

    assert updated.id == c.id
    assert updated.external_kind == :im_group
    assert updated.reply_mode == :channel
    assert updated.metadata == %{"topic" => "Team"}
  end

  defp observe(id, attrs), do: Repo.transact(&External.observe_in_tx(&1, id, attrs, @now))
end
