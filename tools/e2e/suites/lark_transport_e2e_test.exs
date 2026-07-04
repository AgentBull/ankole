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

  alias Ankole.Actors.ActorEvent
  alias Ankole.E2E.FakeFeishu
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
