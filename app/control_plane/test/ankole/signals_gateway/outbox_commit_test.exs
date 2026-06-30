defmodule Ankole.SignalsGatewayOutboxCommitTest do
  use Ankole.DataCase, async: false

  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry
  alias Ankole.SignalsGatewayFixtures.ModuleOutboxAdapter

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-06-23 08:00:00.000000Z]

  describe "outbox commit and adapter normalization" do
    test "operation selection reports missing routes instead of inventing reply or post" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, :reply} = SignalsGateway.outbox_operation_for_actor_input(input)

      assert {:error, {:signal_channel_not_found, "missing-channel"}} =
               SignalsGateway.outbox_operation_for_actor_input(%{
                 input
                 | signal_channel_id: "missing-channel"
               })

      assert {:error, {:signal_binding_not_found, agent.uid, "missing-bot"}} =
               SignalsGateway.outbox_operation_for_actor_input(%{
                 input
                 | binding_name: "missing-bot"
               })

      binding_fixture(agent.uid, "bad-adapter", :ignore, adapter: "missing-adapter")

      assert {:error, {:outbox_adapter_not_found, "missing-adapter"}} =
               SignalsGateway.outbox_operation_for_actor_input(%{
                 input
                 | binding_name: "bad-adapter"
               })
    end

    test "operation selection rejects channels that do not allow provider replies" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _result} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_input_type: "webhook.received"}),
                 now: @base_time
               )

      input = %ActorInput{
        agent_uid: agent.uid,
        binding_name: "webhook",
        signal_channel_id: "webhook:incident-1",
        provider_entry_id: "hook-1"
      }

      assert {:error, :outbox_reply_not_supported} =
               SignalsGateway.outbox_operation_for_actor_input(input)
    end

    test "actor consume can commit outbox intents in the same transaction" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _consumed} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 input.ingress_event_id,
                 actor_commit_opts(
                   consumed_at: DateTime.add(@base_time, 1, :second),
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
      assert outbox.source_provider_entry_id == "msg-1"
    end

    test "actor consume rejects invalid outbox intents without a partial commit" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:error, :invalid_outbox_intent} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 input.ingress_event_id,
                 actor_commit_opts(
                   consumed_at: DateTime.add(@base_time, 1, :second),
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

      assert Repo.get_by!(ActorInput,
               agent_uid: agent.uid,
               binding_name: "bot",
               ingress_event_id: input.ingress_event_id
             )

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "unsupported provider-visible reply marks outbox without faking mirror state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _channel} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_input_type: "webhook.received"}),
                 now: @base_time
               )

      assert {:ok, outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "webhook",
                 outbound_key: "reply-1",
                 operation: :reply,
                 signal_channel_id: "webhook:incident-1",
                 source_provider_entry_id: "hook-1",
                 fallback_visible_text: "not possible"
               })

      assert outbox.status == :created

      assert {:ok, unsupported} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "webhook",
                 "reply-1",
                 %{capabilities: [:reply_entry]},
                 now: @base_time
               )

      assert unsupported.status == :unsupported

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "webhook:incident-1",
               provider_entry_id: "reply-1"
             )
    end

    test "unknown adapter capabilities fail before the outbox row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
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
                   send: fn _outbox -> {:ok, %{provider_entry_id: "must-not-send"}} end
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

    test "module outbox adapters use the same normalized adapter contract" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "module-adapter",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "from module"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "module-adapter",
                 ModuleOutboxAdapter,
                 now: @base_time
               )

      assert succeeded.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "module-adapter-msg"
             ).text == "from module"
    end

    test "invalid adapter result is normalized, redacted, and recorded as send failure" do
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

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "invalid-adapter-result"
             )
    end
  end
end
