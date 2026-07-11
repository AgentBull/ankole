defmodule Ankole.SignalsGatewayOutboxCommitTest do
  use Ankole.DataCase, async: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.ActorRuntimeCase, only: [complete_actor_event: 4]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "outbox commit and adapter normalization" do
    test "operation selection reports missing routes instead of inventing reply or post" do
      %{principal: agent} = agent_fixture()
      agent_uid = agent.uid
      binding_fixture(agent_uid, "bot", :ignore)

      %{actor_event: input} =
        emit_addressed_actor_event(agent_uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, :reply} = SignalsGateway.outbox_operation_for_actor_event(input)

      assert {:error, {:signal_channel_not_found, "missing-channel"}} =
               SignalsGateway.outbox_operation_for_actor_event(%{
                 input
                 | signal_channel_id: "missing-channel"
               })

      assert {:error, {:signal_binding_not_found, ^agent_uid, "missing-bot"}} =
               SignalsGateway.outbox_operation_for_actor_event(%{
                 input
                 | binding_name: "missing-bot"
               })

      binding_fixture(agent_uid, "bad-adapter", :ignore, adapter: "missing-adapter")

      assert {:error, {:signal_adapter_not_found, "missing-adapter"}} =
               SignalsGateway.outbox_operation_for_actor_event(%{
                 input
                 | binding_name: "bad-adapter"
               })
    end

    test "operation selection rejects channels that do not allow provider replies" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _result} =
               Ingress.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_event_type: "webhook.received"}),
                 now: @base_time
               )

      input = %ActorEvent{
        agent_uid: agent.uid,
        binding_name: "webhook",
        signal_channel_id: "webhook:incident-1",
        source_entry_id: "hook-1"
      }

      assert {:error, :outbox_reply_not_supported} =
               SignalsGateway.outbox_operation_for_actor_event(input)
    end

    test "actor consume can commit outbox intents in the same transaction" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: input} =
        emit_addressed_actor_event(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _consumed} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 input.source_event_id,
                 actor_commit_opts(
                   completed_at: DateTime.add(@base_time, 1, :second),
                   outbox_intents: [
                     %{
                       outbound_key: "actor-post-1",
                       operation: :post,
                       fallback_visible_text: "from actor"
                     }
                   ]
                 )
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "actor-post-1"
        )

      assert outbox.status == :created
      assert outbox.signal_channel_id == "lark:chat:group-a"
      assert outbox.reply_to_source_entry_id == "msg-1"
    end

    test "actor consume rejects invalid outbox intents without a partial commit" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: input} =
        emit_addressed_actor_event(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:error, :invalid_outbox_intent} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 input.source_event_id,
                 actor_commit_opts(
                   completed_at: DateTime.add(@base_time, 1, :second),
                   outbox_intents: [
                     %{
                       outbound_key: "valid-before-invalid",
                       operation: :post,
                       fallback_visible_text: "must rollback"
                     },
                     :not_an_intent
                   ]
                 )
               )

      assert Repo.get_by!(ActorEvent,
               agent_uid: agent.uid,
               binding_name: "bot",
               source_event_id: input.source_event_id
             )

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "unsupported provider-visible reply marks outbox without faking mirror state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _channel} =
               Ingress.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_event_type: "webhook.received"}),
                 now: @base_time
               )

      assert {:ok, outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "webhook",
                 outbound_key: "reply-1",
                 operation: :reply,
                 signal_channel_id: "webhook:incident-1",
                 reply_to_source_entry_id: "hook-1",
                 fallback_visible_text: "not possible"
               })

      assert outbox.status == :created

      assert {:ok, unsupported} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "webhook",
                 "reply-1",
                 %{
                   capabilities: [:reply_entry],
                   send: fn _outbox -> flunk("unsupported webhook outbox must not be sent") end
                 },
                 now: @base_time
               )

      assert unsupported.status == :unsupported

      refute Repo.get_by(Entry,
               signal_channel_id: "webhook:incident-1",
               source_entry_id: "reply-1"
             )
    end

    test "unknown adapter capabilities fail before the outbox row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "unknown-capability",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:error, {:unknown_outbox_capability, "made_up"}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "unknown-capability",
                 %{
                   capabilities: ["post_entry", "made_up"],
                   send: fn _outbox -> {:ok, %{created_source_entry_id: "must-not-send"}} end
                 },
                 now: @base_time
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "unknown-capability"
        )

      assert outbox.status == :created
      assert outbox.platform_send_started_at == nil
    end

    test "test adapters without executable callbacks fail before the outbox row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "missing-test-callback",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:error, :invalid_outbox_adapter} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "missing-test-callback",
                 %{capabilities: [:post_entry]},
                 now: @base_time
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "missing-test-callback"
        )

      assert outbox.status == :created
      assert outbox.platform_send_started_at == nil
    end

    test "registered adapter resolution fails before the outbox row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "missing", :ignore, adapter: "missing-adapter")

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "missing",
                 outbound_key: "missing-registered-adapter",
                 operation: :post,
                 fallback_visible_text: "must remain pending"
               })

      assert {:error, {:signal_adapter_not_found, "missing-adapter"}} =
               SignalsGateway.dispatch_outbox_by_key(
                 agent.uid,
                 "missing",
                 "missing-registered-adapter"
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "missing",
          outbound_key: "missing-registered-adapter"
        )

      assert outbox.status == :created
      assert outbox.platform_send_started_at == nil
    end

    test "invalid adapter result is normalized, redacted, and recorded as send failure" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "invalid-adapter-result",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "invalid-adapter-result",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox ->
                     {:unexpected,
                      %{
                        token: "top-secret",
                        nested: %{password: "hidden"},
                        body: String.duplicate("x", 1_200)
                      }}
                   end
                 },
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.last_error["reason"]["__type__"] == "tuple"
      assert failed.last_error["reason"]["items"] |> hd() == "invalid_adapter_result"

      adapter_result = failed.last_error["reason"]["items"] |> Enum.at(1)

      assert adapter_result["__type__"] == "tuple"

      payload = adapter_result["items"] |> Enum.at(1)

      assert payload["token"] == "[REDACTED]"
      assert payload["nested"]["password"] == "[REDACTED]"
      assert String.ends_with?(payload["body"], "...[truncated]")

      refute Repo.get_by(Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "invalid-adapter-result"
             )
    end
  end
end
