defmodule Ankole.Conversations.Delivery.MirrorTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Intent
  import Ankole.Conversations.Assertions
  alias Ankole.Conversations.Attachments

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "intent mirror after provider success" do
    test "a final reply edit creates the absent mirror with all receive-entry facts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: input} =
        emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}), @base_time)

      message_id = Ecto.UUID.generate()
      text = "final visible"
      formatted = %{"format" => "markdown", "text" => "**final visible**"}
      raw = %{"provider" => "test", "edit" => true}

      assert {:ok, %{status: :sent}} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "missing-final-edit",
                   operation: :edit,
                   conversation_id: input.conversation_id,
                   target_provider_message_id: "missing-preview",
                   reply_to_provider_message_id: input.provider_message_id,
                   provider_thread_id: "provider-thread",
                   source_signal_id: input.id,
                   ai_message_id: message_id,
                   payload: %{"formatted_content" => formatted},
                   fallback_visible_text: text
                 },
                 [:edit_entry],
                 %{raw_payload: raw}
               )

      entry =
        message_snapshot!(
          conversation_id: input.conversation_id,
          provider_message_id: "missing-preview"
        )

      rich = Attachments.rich_content(text, formatted)
      author = %{"agent_uid" => agent.uid}

      assert entry.text == text
      assert entry.rich_content == rich
      assert entry.author == author
      assert entry.signal_id == input.id
      assert entry.attachments == []
      assert entry.links == []
      assert entry.mentions == []
      assert entry.reactions == %{}
      assert entry.raw_payload == raw
      assert entry.provider_time == nil
      assert entry.ai_message_id == message_id
      assert entry.reply_to_provider_message_id == input.provider_message_id
      assert entry.provider_thread_id == "provider-thread"

      assert {:ok, _} = Ecto.UUID.cast(entry.id)
      assert byte_size(entry.content_hash) == 64
    end

    test "every confirmed chunk becomes a distinct public statement" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, sent} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "chunks",
                   operation: :post,
                   conversation_id: input.conversation_id,
                   source_signal_id: input.id,
                   fallback_visible_text: "whole response"
                 },
                 [:post_entry],
                 %{
                   created_provider_message_id: "chunk-1",
                   messages: [
                     %{created_provider_message_id: "chunk-1", text: "first"},
                     %{created_provider_message_id: "chunk-2", text: ""},
                     %{
                       created_provider_message_id: "chunk-3",
                       text: nil,
                       payload: %{
                         "attachments" => [%{"name" => "report.pdf", "provider_file_id" => "f"}]
                       }
                     }
                   ]
                 }
               )

      assert sent.status == :sent

      first =
        message_snapshot!(conversation_id: input.conversation_id, provider_message_id: "chunk-1")

      empty =
        message_snapshot!(conversation_id: input.conversation_id, provider_message_id: "chunk-2")

      media =
        message_snapshot!(conversation_id: input.conversation_id, provider_message_id: "chunk-3")

      assert first.text == "first"
      assert empty.text == ""
      assert is_nil(media.text)
      assert [%{"name" => "report.pdf"}] = media.attachments
      assert length(Enum.uniq([first.id, empty.id, media.id])) == 3
      assert first.seq < empty.seq and empty.seq < media.seq
      assert sent.created_message_id == first.id
    end

    test "an ambiguous acknowledgement remains inspectable and never creates a statement" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      {:ok, intent} =
        Ankole.SignalsFixtures.commit_delivery(%{
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "ack",
          operation: :post,
          conversation_id: input.conversation_id,
          fallback_visible_text: "text"
        })

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 intent.outbound_key,
                 delivery_adapter([:post_entry], fn _ ->
                   {:unknown,
                    %{
                      "reason" => "missing_provider_message_id",
                      "raw_payload" => %{"errcode" => 0}
                    }}
                 end)
               )

      assert unknown.status == :unknown
      assert unknown.last_error["raw_payload"] == %{"errcode" => 0}
      assert unknown.next_attempt_at == nil
      assert unknown.created_message_id == nil

      assert {:error, :intent_not_dispatchable} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 intent.outbound_key,
                 delivery_adapter([:post_entry], fn _ ->
                   flunk("do not repeat ambiguous sends")
                 end)
               )
    end

    test "an expired delivery stops before making a provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      {:ok, intent} =
        Ankole.SignalsFixtures.commit_delivery(%{
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "expired",
          operation: :post,
          conversation_id: input.conversation_id,
          expires_at: @base_time,
          fallback_visible_text: "text"
        })

      assert {:ok, expired} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 intent.outbound_key,
                 delivery_adapter([:post_entry], fn _ ->
                   flunk("expired content must not be sent")
                 end),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert expired.status == :expired
      assert expired.created_message_id == nil
    end

    test "successful post is mirrored only after adapter success and failure does not mirror" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _failed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-failed",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "failed"
               })

      assert {:ok, failed} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-failed",
                 delivery_adapter([:post_entry], fn _intent -> {:error, :rate_limited} end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert %DateTime{} = failed.next_attempt_at

      refute message_snapshot(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "post-failed"
             )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-ok",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-ok",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:ok, %{created_provider_message_id: "bot-msg-1"}}
                 end),
                 now: @base_time
               )

      assert succeeded.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "bot-msg-1"
             ).text ==
               "visible"
    end

    test "intent send-start is durable before provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-observe-sending",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-observe-sending",
                 delivery_adapter([:post_entry], fn _intent ->
                   intent =
                     Repo.get_by!(Intent,
                       agent_uid: agent.uid,
                       binding_name: "bot",
                       outbound_key: "post-observe-sending"
                     )

                   assert intent.status == :pending
                   assert %DateTime{} = intent.platform_send_started_at

                   {:ok, %{created_provider_message_id: "durable-send-msg"}}
                 end),
                 now: @base_time
               )

      assert succeeded.status == :sent
    end

    test "successful send persists adapter-materialized payload" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      attachment =
        Ankole.FilesFixtures.sent_attachment_fixture(
          agent.uid,
          "chaos-report.txt",
          "chaos report",
          "text/plain"
        )

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-materialized-payload",
                 operation: :reply,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 reply_to_provider_message_id: "human-msg-1",
                 payload: %{
                   "attachments" => [
                     attachment
                   ]
                 },
                 fallback_visible_text: "visible"
               })

      materialized_text = "This file is too large. Open it in cloud space."

      materialized_payload = %{
        "attachments" => [
          Map.put(attachment, "provider_file_key", "file_uploaded_1")
        ]
      }

      assert {:ok, succeeded} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-materialized-payload",
                 delivery_adapter([:reply_entry], fn _intent ->
                   {:ok,
                    %{
                      created_provider_message_id: "bot-file-msg-1",
                      payload: materialized_payload,
                      fallback_visible_text: materialized_text
                    }}
                 end),
                 now: @base_time
               )

      assert succeeded.status == :sent

      assert succeeded.payload == %{
               "attachments" =>
                 Enum.map(
                   materialized_payload["attachments"],
                   &Map.drop(&1, ["object_id", "node_id"])
                 )
             }

      assert succeeded.fallback_visible_text == materialized_text

      mirrored =
        message_snapshot!(
          conversation_id: conversation_id!("lark:chat:group-a"),
          provider_message_id: "bot-file-msg-1"
        )

      assert mirrored.text == materialized_text
      assert [%{"attachment_id" => attachment_id} = mirrored_attachment] = mirrored.attachments

      assert attachment_id >= 10_000

      assert Map.delete(mirrored_attachment, "attachment_id") ==
               hd(materialized_payload["attachments"])
    end

    test "post-like success without provider entry id does not synthesize mirror identity" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-without-provider-id",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "visible"
               })

      assert {:error, :delivery_provider_message_id_missing} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-without-provider-id",
                 delivery_adapter([:post_entry], fn _intent -> {:ok, %{}} end),
                 now: @base_time
               )

      assert Repo.get_by!(Intent,
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "post-without-provider-id"
             ).status == :pending

      refute message_snapshot(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "local-intent:post-without-provider-id"
             )
    end

    test "local recording failure retains the send claim and never blindly repeats the provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-mirror-fails-after-send",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "visible"
               })

      test_pid = self()

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Ash.Error.Changes.InvalidAttribute{field: :raw_payload}]
              }} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-mirror-fails-after-send",
                 delivery_adapter([:post_entry], fn _ ->
                   {:ok,
                    %{
                      created_provider_message_id: "mirror-fails-after-send",
                      raw_payload: %{"pid" => test_pid}
                    }}
                 end),
                 now: @base_time
               )

      retained =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "post-mirror-fails-after-send"
        )

      assert retained.status == :pending
      assert %DateTime{} = retained.platform_send_started_at

      refute message_snapshot(
               conversation_id: retained.conversation_id,
               provider_message_id: "mirror-fails-after-send"
             )

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 retained.outbound_key,
                 delivery_adapter([:post_entry], fn _ ->
                   flunk("do not resend an unrecorded provider confirmation")
                 end),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown
      assert is_nil(unknown.next_attempt_at)
    end

    test "intent reply edit delete reaction divider and card mirror only after success" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, reply} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reply-ok",
                   operation: :reply,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   reply_to_provider_message_id: "msg-1",
                   fallback_visible_text: "reply visible"
                 },
                 [:reply_entry],
                 %{
                   created_provider_message_id: "reply-msg",
                   provider_thread_id: "lark:chat:group-a:msg-1"
                 }
               )

      assert reply.status == :sent
      assert reply.provider_thread_id == "lark:chat:group-a:msg-1"

      assert %{
               text: "reply visible",
               provider_thread_id: "lark:chat:group-a:msg-1"
             } =
               message_snapshot!(
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 provider_message_id: "reply-msg"
               )

      assert {:ok, edited} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "edit-ok",
                   operation: :edit,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   target_provider_message_id: "reply-msg",
                   fallback_visible_text: "edited visible"
                 },
                 [:edit_entry],
                 %{}
               )

      assert edited.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "reply-msg"
             ).text == "edited visible"

      assert {:ok, reaction_add} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-add-ok",
                   operation: :reaction_add,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   target_provider_message_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:add_reaction],
                 %{}
               )

      assert reaction_add.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "reply-msg"
             ).reactions == %{"thumbsup" => ["agent"]}

      assert {:ok, reaction_remove} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-remove-ok",
                   operation: :reaction_remove,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   target_provider_message_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:remove_reaction],
                 %{}
               )

      assert reaction_remove.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "reply-msg"
             ).reactions == %{}

      assert {:ok, divider} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "divider-ok",
                   operation: :divider,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   fallback_visible_text: "---"
                 },
                 [:post_entry, :divider],
                 %{created_provider_message_id: "divider-msg"}
               )

      assert divider.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "divider-msg"
             ).text == "---"

      assert {:ok, card} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "card-ok",
                   operation: :card,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   fallback_visible_text: "card fallback"
                 },
                 [:post_entry, :card],
                 %{created_provider_message_id: "card-msg"}
               )

      assert card.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "card-msg"
             ).text == "card fallback"

      assert {:ok, deleted} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "delete-ok",
                   operation: :delete,
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   target_provider_message_id: "reply-msg"
                 },
                 [:delete_entry],
                 %{}
               )

      assert deleted.status == :sent

      refute message_snapshot(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "reply-msg"
             )
    end
  end
end
