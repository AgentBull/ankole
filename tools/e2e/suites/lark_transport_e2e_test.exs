defmodule Ankole.E2E.LarkTransportE2ETest do
  @moduledoc """
  Network-level transport e2e between the real Lark adapter and the fake
  Feishu server: WS endpoint discovery, real long-connection frames, heartbeat,
  fragmentation, reconnect, tenant-token auth, and outbound HTTP behavior.

  No Docker worker and no LLM: this suite proves the provider transport edge
  in isolation, which every other suite then builds on.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.E2E.WaitHelpers
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.Principals
  alias Ankole.SignalsGateway.OutboxEntry

  @moduletag timeout: 60_000

  setup do
    fake_feishu = start_fake_feishu!()
    domain = setup_transport_domain!(fake_feishu)
    connections = start_lark_connections!(fake_feishu, connections: 1)
    Map.merge(domain, %{fake_feishu: fake_feishu, connections: connections})
  end

  test "WS discovery, event delivery, client ack, and heartbeat", %{
    fake_feishu: fake_feishu,
    agent: agent
  } do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_dm_1",
               message_id: "om_transport_dm_1",
               chat_id: "oc_transport_dm",
               chat_type: "p2p",
               text: "@_user_1 transport smoke line",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_transport_dm_1")
    assert input.type == "im.message.addressed"

    entry = wait_for_signal_entry!("lark:oc_transport_dm", "om_transport_dm_1")
    assert entry.text =~ "transport smoke line"

    # The client must ack the delivered event frame with a success code.
    assert wait_for_event_ack!(fake_feishu, "evt_transport_dm_1") == 200

    # PingInterval is 1s in the fake ClientConfig, so an application-level
    # ping/pong roundtrip must happen shortly after connect.
    assert {:ok, _pings} =
             WaitHelpers.wait_until(WaitHelpers.deadline(10_000), fn ->
               count = FakeFeishu.State.ping_count(fake_feishu.state)
               count >= 1 && count
             end)
  end

  test "fragmented event frames are reassembled before dispatch", %{
    fake_feishu: fake_feishu,
    agent: agent
  } do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_frag_1",
               message_id: "om_transport_frag_1",
               chat_id: "oc_transport_frag",
               chat_type: "p2p",
               text: "@_user_1 fragmented payload #{String.duplicate("x", 512)}",
               mentions: [lark_bot_mention()],
               fragments: 3
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_transport_frag_1")
    assert get_in(input.payload, ["data", "entry", "text"]) =~ "fragmented payload"
  end

  test "out-of-order fragments still reassemble", %{fake_feishu: fake_feishu, agent: agent} do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_frag_ooo_1",
               message_id: "om_transport_frag_ooo_1",
               chat_id: "oc_transport_frag",
               chat_type: "p2p",
               text: "@_user_1 out of order fragments #{String.duplicate("y", 256)}",
               mentions: [lark_bot_mention()],
               fragments: 2,
               fragment_order: :reversed
             )

    assert %ActorEvent{} =
             actor_event_by_source_entry_id!(agent.uid, "om_transport_frag_ooo_1")
  end

  test "truncated frames are rejected without killing the connection", %{
    fake_feishu: fake_feishu,
    agent: agent
  } do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_bad_frame_1",
               message_id: "om_transport_bad_frame_1",
               chat_id: "oc_transport_bad",
               chat_type: "p2p",
               text: "@_user_1 this frame is cut off on the wire",
               mentions: [lark_bot_mention()],
               truncate: true
             )

    # A malformed frame is dropped at decode; the very same connection must
    # still deliver the next healthy frame.
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_after_bad_1",
               message_id: "om_transport_after_bad_1",
               chat_id: "oc_transport_bad",
               chat_type: "p2p",
               text: "@_user_1 healthy frame after the malformed one",
               mentions: [lark_bot_mention()]
             )

    assert %ActorEvent{} =
             actor_event_by_source_entry_id!(agent.uid, "om_transport_after_bad_1")

    refute pending_actor_event(agent.uid, "om_transport_bad_frame_1")
    refute FakeFeishu.State.ack_code(fake_feishu.state, "evt_transport_bad_frame_1")
  end

  test "server-initiated close reconnects and events keep flowing", %{
    fake_feishu: fake_feishu,
    agent: agent
  } do
    assert FakeFeishu.State.connection_count(fake_feishu.state) == 1
    assert :ok = FakeFeishu.State.drop_ws_connections(fake_feishu.state)

    # The drop lands asynchronously: first observe the old connection gone, then
    # wait for the fresh one. ReconnectNonce/Interval are 1s in the fake
    # ClientConfig, so the client comes back through a fresh endpoint discovery.
    assert_receive {:fake_feishu, {:ws_disconnected, _conn_id}}, 10_000

    assert {:ok, _count} =
             WaitHelpers.wait_until(WaitHelpers.deadline(20_000), fn ->
               count = FakeFeishu.State.connection_count(fake_feishu.state)
               count >= 1 && count
             end)

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_transport_reconnect_1",
               message_id: "om_transport_reconnect_1",
               chat_id: "oc_transport_reconnect",
               chat_type: "p2p",
               text: "@_user_1 delivered after reconnect",
               mentions: [lark_bot_mention()]
             )

    assert %ActorEvent{} =
             actor_event_by_source_entry_id!(agent.uid, "om_transport_reconnect_1")
  end

  test "outbound post authenticates, is idempotent under injected 429, and refreshes stale tokens",
       %{fake_feishu: fake_feishu, agent: agent, binding: binding} do
    # First send: cold token cache, so the adapter must fetch a tenant token.
    outbox = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_POST_ONE")
    assert {:ok, %{created_source_entry_id: first_id}} = LarkOutbox.send(outbox)
    assert_received {:fake_feishu, {:token_issued, _token}}

    first = platform_message!(fake_feishu, first_id)
    assert first.text =~ "TRANSPORT_POST_ONE"
    assert first.chat_id == "oc_transport_out"
    assert first.uuid == outbox.idempotency_key

    # Injected rate limit: the SDK retries once and the uuid idempotency key
    # keeps the platform at exactly one message for this outbox.
    FakeFeishu.State.fail_next(fake_feishu.state, :post_message, :rate_limited)
    outbox = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_POST_RATE_LIMITED")
    assert {:ok, %{created_source_entry_id: second_id}} = LarkOutbox.send(outbox)
    assert platform_message!(fake_feishu, second_id).text =~ "TRANSPORT_POST_RATE_LIMITED"

    # Expired tenant token: the business call returns a token-invalid code, the
    # SDK drops its cached token, re-authenticates, and retries once.
    FakeFeishu.State.expire_tokens(fake_feishu.state)
    outbox = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_POST_REFRESH")
    assert {:ok, %{created_source_entry_id: third_id}} = LarkOutbox.send(outbox)
    assert_received {:fake_feishu, {:token_issued, _refreshed}}
    assert platform_message!(fake_feishu, third_id).text =~ "TRANSPORT_POST_REFRESH"

    visible = FakeFeishu.State.visible_messages(fake_feishu.state, "oc_transport_out")
    assert length(visible) == 3
  end

  test "reply to a gone target falls back to a visible post", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    outbox =
      agent.uid
      |> transport_outbox(binding.name, :reply, "TRANSPORT_REPLY_FALLBACK")
      |> Map.put(:reply_to_source_entry_id, "om_never_existed_1")

    assert {:ok, %{created_source_entry_id: created_id}} = LarkOutbox.send(outbox)

    message = platform_message!(fake_feishu, created_id)
    assert message.text =~ "TRANSPORT_REPLY_FALLBACK"
    # Fallback posts a fresh message instead of replying to the gone target.
    assert message.reply_to == nil
    assert message.chat_id == "oc_transport_out"
  end

  test "replies and file replies cross the production transport seam", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    parent = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_PARENT")
    assert {:ok, %{created_source_entry_id: parent_id}} = LarkOutbox.send(parent)

    reply =
      agent.uid
      |> transport_outbox(binding.name, :reply, "TRANSPORT_REPLY")
      |> Map.put(:reply_to_source_entry_id, parent_id)
      |> Map.put(:idempotency_key, "transport-reply-one")

    assert {:ok,
            %{
              created_source_entry_id: reply_id,
              provider_thread_id: ^parent_id,
              raw_payload: %{"data" => %{"message_id" => raw_reply_id}}
            }} = LarkOutbox.send(reply)

    assert raw_reply_id == reply_id

    assert %{
             chat_id: "oc_transport_out",
             msg_type: "text",
             reply_to: ^parent_id,
             text: "TRANSPORT_REPLY",
             uuid: "transport-reply-one"
           } = platform_message!(fake_feishu, reply_id)

    file_reply =
      agent.uid
      |> transport_outbox(binding.name, :reply, "TRANSPORT_FILE_REPLY")
      |> Map.put(:reply_to_source_entry_id, parent_id)
      |> Map.put(:payload, %{
        "attachments" => [
          %{"provider_file_key" => "file_uploaded_1", "name" => "report.txt"}
        ]
      })

    assert {:ok, %{created_source_entry_id: file_id}} = LarkOutbox.send(file_reply)
    file_message = platform_message!(fake_feishu, file_id)
    assert file_message.msg_type == "file"
    assert file_message.chat_id == "oc_transport_out"
    assert file_message.reply_to == parent_id
    assert file_message.uuid == file_reply.idempotency_key
    assert {:ok, %{"file_key" => "file_uploaded_1"}} = Ankole.JSON.decode(file_message.content)
  end

  test "divider messages preserve provider-visible content and routing", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    divider =
      agent.uid
      |> transport_outbox(binding.name, :divider, "New Session")
      |> Map.put(:payload, %{"i18n" => %{"zh_CN" => "新会话"}})

    assert {:ok, %{created_source_entry_id: divider_id}} = LarkOutbox.send(divider)
    divider_message = platform_message!(fake_feishu, divider_id)
    assert divider_message.msg_type == "system"
    assert divider_message.chat_id == "oc_transport_out"
    assert divider_message.uuid == divider.idempotency_key
    assert {:ok, divider_content} = Ankole.JSON.decode(divider_message.content)
    assert divider_content["type"] == "divider"
    assert get_in(divider_content, ["params", "divider_text", "text"]) == "New Session"
    assert get_in(divider_content, ["params", "divider_text", "i18n_text", "zh_CN"]) == "新会话"
  end

  test "notice cards preserve provider-visible rendering and routing", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    control_card =
      agent.uid
      |> transport_outbox(binding.name, :card, "Started a new conversation.")
      |> Map.put(:payload, %{
        "control_notice" => %{"text" => "Started a new conversation."}
      })

    assert {:ok, %{created_source_entry_id: control_id}} = LarkOutbox.send(control_card)
    control_message = platform_message!(fake_feishu, control_id)
    assert control_message.msg_type == "interactive"
    assert control_message.chat_id == "oc_transport_out"
    assert control_message.uuid == control_card.idempotency_key
    assert {:ok, control_content} = Ankole.JSON.decode(control_message.content)
    assert control_content["schema"] == "2.0"
    assert get_in(control_content, ["config", "update_multi"]) == true
    assert get_in(control_content, ["body", "elements", Access.at(0), "tag"]) == "div"

    progress_card =
      agent.uid
      |> transport_outbox(binding.name, :card, "以上历史对话记录已被压缩")
      |> Map.put(:payload, %{
        "progress_notice" => %{
          "text" => "以上历史对话记录已被压缩",
          "show_divider" => true
        }
      })

    assert {:ok, %{created_source_entry_id: progress_id}} = LarkOutbox.send(progress_card)
    progress_message = platform_message!(fake_feishu, progress_id)
    assert progress_message.msg_type == "interactive"
    assert progress_message.chat_id == "oc_transport_out"
    assert progress_message.uuid == progress_card.idempotency_key
    assert {:ok, progress_content} = Ankole.JSON.decode(progress_message.content)
    assert get_in(progress_content, ["body", "elements", Access.at(0), "tag"]) == "hr"

    assert get_in(progress_content, ["body", "elements", Access.at(1), "text", "content"]) ==
             "以上历史对话记录已被压缩"
  end

  test "edit and delete mutate provider-visible message state", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    original = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_MUTATION_TARGET")
    assert {:ok, %{created_source_entry_id: target_id}} = LarkOutbox.send(original)

    edit =
      agent.uid
      |> transport_outbox(binding.name, :edit, "TRANSPORT_EDITED")
      |> Map.put(:target_source_entry_id, target_id)

    assert {:ok, %{created_source_entry_id: ^target_id}} = LarkOutbox.send(edit)
    assert platform_message!(fake_feishu, target_id).text == "TRANSPORT_EDITED"

    delete =
      agent.uid
      |> transport_outbox(binding.name, :delete, "")
      |> Map.put(:target_source_entry_id, target_id)

    assert {:ok, %{raw_payload: %{"data" => %{}}}} = LarkOutbox.send(delete)
    assert FakeFeishu.State.message(fake_feishu.state, target_id).deleted

    refute Enum.any?(
             FakeFeishu.State.visible_messages(fake_feishu.state, "oc_transport_out"),
             &(&1.id == target_id)
           )
  end

  test "reaction add and remove mutate provider-visible message state", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    original = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_REACTION_TARGET")
    assert {:ok, %{created_source_entry_id: target_id}} = LarkOutbox.send(original)

    reaction_add =
      agent.uid
      |> transport_outbox(binding.name, :reaction_add, "")
      |> Map.put(:target_source_entry_id, target_id)
      |> Map.put(:payload, %{"reaction_key" => "thumbs_up"})

    assert {:ok, %{raw_payload: %{"data" => %{"reaction_id" => reaction_id}}}} =
             LarkOutbox.send(reaction_add)

    assert [%{id: ^reaction_id, key: "THUMBSUP"}] =
             platform_message!(fake_feishu, target_id).reactions

    reaction_remove =
      agent.uid
      |> transport_outbox(binding.name, :reaction_remove, "")
      |> Map.put(:target_source_entry_id, target_id)
      |> Map.put(:payload, %{"reaction_key" => reaction_id})

    assert {:ok, %{raw_payload: %{"data" => %{}}}} = LarkOutbox.send(reaction_remove)
    assert platform_message!(fake_feishu, target_id).reactions == []
  end

  test "long replies preserve deterministic multi-request behavior", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    parent = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_SPLIT_PARENT")
    assert {:ok, %{created_source_entry_id: parent_id}} = LarkOutbox.send(parent)
    long_text = String.duplicate("你", 4_001)

    reply =
      agent.uid
      |> transport_outbox(binding.name, :reply, long_text)
      |> Map.put(:reply_to_source_entry_id, parent_id)
      |> Map.put(:idempotency_key, "reply-long-1")

    assert {:ok,
            %{
              created_source_entry_id: first_reply_id,
              provider_thread_id: ^parent_id,
              raw_payload: %{"split" => true, "chunks" => [_, _]}
            }} = LarkOutbox.send(reply)

    [first_reply, second_reply] =
      fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_transport_out")
      |> Enum.filter(&(&1.uuid in ["reply-long-1", "reply-long-1:part:2"]))

    assert first_reply.id == first_reply_id
    assert first_reply.reply_to == parent_id
    assert first_reply.uuid == "reply-long-1"
    assert String.length(first_reply.text) == 4_000
    assert second_reply.reply_to == nil
    assert second_reply.uuid == "reply-long-1:part:2"
    assert String.length(second_reply.text) == 1
    assert first_reply.text <> second_reply.text == long_text
  end

  test "long edits preserve deterministic multi-request behavior", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    long_text = String.duplicate("你", 4_001)
    edit_target = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_EDIT_TARGET")
    assert {:ok, %{created_source_entry_id: edit_target_id}} = LarkOutbox.send(edit_target)

    edit =
      agent.uid
      |> transport_outbox(binding.name, :edit, long_text)
      |> Map.put(:target_source_entry_id, edit_target_id)
      |> Map.put(:idempotency_key, "edit-long-1")

    assert {:ok,
            %{
              created_source_entry_id: ^edit_target_id,
              raw_payload: %{"split" => true, "chunks" => [_, _]}
            }} = LarkOutbox.send(edit)

    edited = platform_message!(fake_feishu, edit_target_id)

    [edit_follow_up] =
      fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_transport_out")
      |> Enum.filter(&(&1.uuid == "edit-long-1:part:2"))

    assert String.length(edited.text) == 4_000
    assert edit_follow_up.reply_to == nil
    assert edit_follow_up.uuid == "edit-long-1:part:2"
    assert String.length(edit_follow_up.text) == 1
    assert edited.text <> edit_follow_up.text == long_text
  end

  test "multi-table cards become deterministic provider-visible messages", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    parent = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_CARD_PARENT")
    assert {:ok, %{created_source_entry_id: parent_id}} = LarkOutbox.send(parent)

    card = %{
      "schema" => "2.0",
      "body" => %{
        "elements" => [
          %{"tag" => "markdown", "content" => "Before"},
          %{"tag" => "table", "rows" => [%{"cells" => []}]},
          %{"tag" => "markdown", "content" => "Between"},
          %{"tag" => "table", "rows" => [%{"cells" => []}]}
        ]
      }
    }

    outbox =
      agent.uid
      |> transport_outbox(binding.name, :card, "card fallback")
      |> Map.put(:reply_to_source_entry_id, parent_id)
      |> Map.put(:payload, %{"card" => card})
      |> Map.put(:idempotency_key, "card-table-1")

    assert {:ok,
            %{
              created_source_entry_id: first_card_id,
              provider_thread_id: ^parent_id,
              raw_payload: %{"split" => true, "chunks" => [_, _]}
            }} = LarkOutbox.send(outbox)

    [first_message, second_message] =
      fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_transport_out")
      |> Enum.filter(&(&1.uuid in ["card-table-1", "card-table-1:part:2"]))

    assert first_message.id == first_card_id
    assert first_message.reply_to == parent_id
    assert first_message.uuid == "card-table-1"
    assert second_message.reply_to == nil
    assert second_message.uuid == "card-table-1:part:2"
    assert {:ok, first_card} = Ankole.JSON.decode(first_message.content)
    assert {:ok, second_card} = Ankole.JSON.decode(second_message.content)
    assert first_card["body"]["elements"] |> Enum.count(&(&1["tag"] == "table")) == 1
    assert second_card["body"]["elements"] |> Enum.count(&(&1["tag"] == "table")) == 1
    assert get_in(first_card, ["body", "elements", Access.at(0), "content"]) == "Before"
    assert get_in(second_card, ["body", "elements", Access.at(0), "tag"]) == "table"
  end

  test "reconcile reports whether a sent message still exists", %{
    fake_feishu: fake_feishu,
    agent: agent,
    binding: binding
  } do
    outbox = transport_outbox(agent.uid, binding.name, :post, "TRANSPORT_RECONCILE")
    assert {:ok, %{created_source_entry_id: created_id}} = LarkOutbox.send(outbox)
    assert platform_message!(fake_feishu, created_id)

    assert {:ok, %{created_source_entry_id: ^created_id, recovery_state: %{"exists" => true}}} =
             LarkOutbox.reconcile(%{outbox | created_source_entry_id: created_id})

    assert :unknown =
             LarkOutbox.reconcile(%{outbox | created_source_entry_id: "om_gone_9999"})
  end

  # -- suite-local helpers ------------------------------------------------------

  # Transport tests need an agent and one enabled binding, but no LLM provider,
  # model profiles, or skills.
  defp setup_transport_domain!(fake_feishu) do
    uid =
      "agent-lark-transport-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
               uid: uid,
               display_name: "Lark Transport Agent",
               role: "Transport test agent"
             })

    binding =
      upsert_lark_binding!(agent.uid, "lark-transport-primary", :ignore, fake_feishu,
        app_id: primary_app_id(),
        group_message_mode: "addressed_only"
      )

    %{agent: agent, binding: binding}
  end

  defp transport_outbox(agent_uid, binding_name, operation, text) do
    %OutboxEntry{
      agent_uid: agent_uid,
      binding_name: binding_name,
      outbound_key: "transport-#{System.unique_integer([:positive])}",
      operation: operation,
      status: :created,
      signal_channel_id: "lark:oc_transport_out",
      payload: %{"text" => text},
      fallback_visible_text: text,
      idempotency_key: "transport-idem-#{System.unique_integer([:positive])}"
    }
  end
end
