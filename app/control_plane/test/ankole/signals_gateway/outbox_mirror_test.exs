defmodule Ankole.SignalsGatewayOutboxMirrorTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-06-23 08:00:00.000000Z]

  describe "outbox mirror after provider success" do
    test "successful post is mirrored only after adapter success and failure does not mirror" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _failed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-failed",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "failed"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-failed",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:error, :rate_limited} end},
                 now: @base_time
               )

      assert failed.status == :failed
      assert %DateTime{} = failed.next_attempt_at

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "post-failed"
             )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-ok",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-ok",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox -> {:ok, %{provider_entry_id: "bot-msg-1"}} end
                 },
                 now: @base_time
               )

      assert succeeded.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "bot-msg-1"
             ).text ==
               "visible"
    end

    test "outbox send-start is durable before provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-observe-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-observe-sending",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox ->
                     outbox =
                       Repo.get_by!(OutboxEntry,
                         agent_uid: agent.uid,
                         binding_name: "bot",
                         outbound_key: "post-observe-sending"
                       )

                     assert outbox.status == :sending
                     assert %DateTime{} = outbox.platform_send_started_at

                     {:ok, %{provider_entry_id: "durable-send-msg"}}
                   end
                 },
                 now: @base_time
               )

      assert succeeded.status == :succeeded
    end

    test "post-like success without provider entry id materializes a stable local mirror id" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-without-provider-id",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-without-provider-id",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:ok, %{}} end},
                 now: @base_time
               )

      assert succeeded.status == :succeeded
      assert succeeded.provider_entry_id == "local-outbox:post-without-provider-id"

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "local-outbox:post-without-provider-id"
             ).text == "visible"
    end

    test "confirmed provider send stays succeeded when local mirror write fails" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-mirror-fails-after-send",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      test_pid = self()

      log =
        capture_log(fn ->
          assert {:ok, succeeded} =
                   SignalsGateway.dispatch_outbox(
                     agent.uid,
                     "bot",
                     "post-mirror-fails-after-send",
                     %{
                       capabilities: [:post_entry],
                       send: fn _outbox ->
                         {:ok,
                          %{
                            provider_entry_id: "mirror-fails-after-send",
                            raw_payload: %{"pid" => test_pid}
                          }}
                       end
                     },
                     now: @base_time
                   )

          send(test_pid, {:succeeded_outbox, succeeded})
        end)

      assert_receive {:succeeded_outbox, succeeded}
      assert succeeded.status == :succeeded
      assert succeeded.provider_entry_id == "mirror-fails-after-send"

      assert Repo.get_by!(OutboxEntry,
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "post-mirror-fails-after-send"
             ).status == :succeeded

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "mirror-fails-after-send"
             )

      assert log =~ "signals_gateway outbox mirror failed after provider send"
    end

    test "outbox reply edit delete reaction divider and card mirror only after success" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, reply} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reply-ok",
                   operation: :reply,
                   signal_channel_id: "lark:chat:group-a",
                   source_provider_entry_id: "msg-1",
                   fallback_visible_text: "reply visible"
                 },
                 [:reply_entry],
                 %{provider_entry_id: "reply-msg"}
               )

      assert reply.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).text == "reply visible"

      assert {:ok, edited} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "edit-ok",
                   operation: :edit,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   fallback_visible_text: "edited visible"
                 },
                 [:edit_entry],
                 %{}
               )

      assert edited.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).text == "edited visible"

      assert {:ok, reaction_add} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-add-ok",
                   operation: :reaction_add,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:add_reaction],
                 %{}
               )

      assert reaction_add.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).reactions == %{"thumbsup" => ["agent"]}

      assert {:ok, reaction_remove} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-remove-ok",
                   operation: :reaction_remove,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:remove_reaction],
                 %{}
               )

      assert reaction_remove.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).reactions == %{}

      assert {:ok, divider} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "divider-ok",
                   operation: :divider,
                   signal_channel_id: "lark:chat:group-a",
                   fallback_visible_text: "---"
                 },
                 [:post_entry, :divider],
                 %{provider_entry_id: "divider-msg"}
               )

      assert divider.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "divider-msg"
             ).text == "---"

      assert {:ok, card} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "card-ok",
                   operation: :card,
                   signal_channel_id: "lark:chat:group-a",
                   fallback_visible_text: "card fallback"
                 },
                 [:post_entry, :card],
                 %{provider_entry_id: "card-msg"}
               )

      assert card.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "card-msg"
             ).text == "card fallback"

      assert {:ok, deleted} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "delete-ok",
                   operation: :delete,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg"
                 },
                 [:delete_entry],
                 %{}
               )

      assert deleted.status == :succeeded

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             )
    end
  end
end
