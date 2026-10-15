defmodule Ankole.Conversations.Delivery.CommitTest do
  use Ankole.DataCase, async: false

  alias Ankole.Signals.Signal
  alias Ankole.Repo

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Intent
  import Ankole.Conversations.Assertions

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "intent commit and dispatch" do
    test "operation selection reports missing routes instead of inventing reply or post" do
      %{principal: agent} = agent_fixture()
      agent_uid = agent.uid
      binding_fixture(agent_uid, "bot", :ignore)

      %{signal: input} =
        emit_addressed_signal(agent_uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, :reply} = Ankole.Conversations.Delivery.operation_for_signal(input)

      assert {:error, {:signal_channel_not_found, "018fffff-ffff-7fff-8fff-ffffffffffff"}} =
               Ankole.Conversations.Delivery.operation_for_signal(%{
                 input
                 | conversation_id: "018fffff-ffff-7fff-8fff-ffffffffffff"
               })

      assert {:error, {:signal_binding_not_found, ^agent_uid, "missing-bot"}} =
               Ankole.Conversations.Delivery.operation_for_signal(%{
                 input
                 | reply_binding_name: "missing-bot"
               })
    end

    test "operation selection does not depend on the adapter being registered" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: input} =
        emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      binding_fixture(agent.uid, "bad-adapter", :ignore, adapter: "missing-adapter")

      # An absent plugin must not fail the transaction that commits a durable
      # intent: that made one unreachable route able to block worker takeover
      # and turn cleanup. Dispatch resolves the adapter later.
      assert {:ok, :reply} =
               Ankole.Conversations.Delivery.operation_for_signal(%{
                 input
                 | reply_binding_name: "bad-adapter"
               })
    end

    test "operation selection rejects channels that do not allow provider replies" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _result} =
               Observe.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{signal_type: "webhook.received"}),
                 now: @base_time
               )

      input = %Signal{
        agent_uid: agent.uid,
        reply_binding_name: "webhook",
        conversation_id: conversation_id!("webhook:incident-1"),
        provider_message_id: "hook-1"
      }

      assert {:error, :intent_reply_not_supported} =
               Ankole.Conversations.Delivery.operation_for_signal(input)
    end

    test "the caller commits delivery and completion in the same transaction" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, completed} =
               complete_with_intents(input, [
                 %{
                   outbound_key: "actor-post-1",
                   operation: :post,
                   fallback_visible_text: "from actor"
                 }
               ])

      assert completed.completed_at

      intent =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "actor-post-1"
        )

      assert intent.status == :pending
      assert intent.conversation_id == conversation_id!("lark:chat:group-a")
      assert intent.reply_to_provider_message_id == "msg-1"
    end

    test "an invalid delivery rolls back both preceding intents and completion" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:error, %Ecto.Changeset{valid?: false}} =
               complete_with_intents(input, [
                 %{
                   outbound_key: "valid-before-invalid",
                   operation: :post,
                   fallback_visible_text: "must rollback"
                 },
                 %{outbound_key: "invalid", operation: :invalid}
               ])

      assert Repo.reload!(input).completed_at == nil
      assert Repo.aggregate(Intent, :count) == 0
    end

    test "unsupported provider-visible reply marks intent without faking mirror state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _channel} =
               Observe.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{signal_type: "webhook.received"}),
                 now: @base_time
               )

      assert {:ok, intent} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: agent.uid,
                 binding_name: "webhook",
                 outbound_key: "reply-1",
                 operation: :reply,
                 conversation_id: conversation_id!("webhook:incident-1"),
                 reply_to_provider_message_id: "hook-1",
                 fallback_visible_text: "not possible"
               })

      assert intent.status == :pending

      assert {:ok, unsupported} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "webhook",
                 "reply-1",
                 delivery_adapter([:reply_entry], fn _intent ->
                   flunk("unsupported webhook intent must not be sent")
                 end),
                 now: @base_time
               )

      assert unsupported.status == :failed

      refute message_snapshot(
               conversation_id: conversation_id!("webhook:incident-1"),
               provider_message_id: "reply-1"
             )
    end

    test "a conversation-level reply posts even when the input has a reply anchor" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: input} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))
      conversation = Repo.get_by!(Ankole.Conversations.Conversation, id: input.conversation_id)
      conversation |> Ecto.Changeset.change(reply_mode: :channel) |> Repo.update!()
      assert {:ok, :post} = Ankole.Conversations.Delivery.operation_for_signal(input)

      assert {:ok, _} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 conversation_id: input.conversation_id,
                 outbound_key: "top-level-reply",
                 operation: :post,
                 fallback_visible_text: "Visible answer"
               })

      assert {:ok, %{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "top-level-reply",
                 delivery_adapter([:post_entry], fn _ ->
                   {:ok, %{created_provider_message_id: "top-level-answer"}}
                 end),
                 now: @base_time
               )

      assert message_snapshot(
               conversation_id: input.conversation_id,
               provider_message_id: "top-level-answer"
             ).text == "Visible answer"
    end

    test "threaded reply degrades to a post for an adapter that cannot thread" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "degraded-reply",
                 operation: :reply,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 reply_to_provider_message_id: "msg-1",
                 fallback_visible_text: "still gets out"
               })

      parent = self()

      assert {:ok, sent} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "degraded-reply",
                 delivery_adapter([:post_entry], fn dispatched ->
                   send(parent, {:degraded, dispatched.operation})
                   {:ok, %{created_provider_message_id: "provider-degraded-reply"}}
                 end),
                 now: @base_time
               )

      # The row records the operation that was actually attempted, and keeps the
      # anchor of what the message answers.
      assert sent.status == :sent
      assert sent.operation == :post
      assert sent.reply_to_provider_message_id == "msg-1"
      assert_receive {:degraded, :post}
    end

    test "registered adapter resolution fails before the intent row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "missing", :ignore, adapter: "missing-adapter")

      assert {:ok, _intent} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: agent.uid,
                 binding_name: "missing",
                 outbound_key: "missing-registered-adapter",
                 operation: :post,
                 fallback_visible_text: "must remain pending"
               })

      assert {:error, {:signal_adapter_not_found, "missing-adapter"}} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 agent.uid,
                 "missing",
                 "missing-registered-adapter"
               )

      intent =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "missing",
          outbound_key: "missing-registered-adapter"
        )

      assert intent.status == :pending
      assert intent.platform_send_started_at == nil
    end

    test "invalid adapter result is normalized, redacted, and recorded as send failure" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.Conversations.Delivery.commit(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "invalid-adapter-result",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "visible"
               })

      assert {:ok, failed} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "invalid-adapter-result",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:unexpected,
                    %{
                      token: "top-secret",
                      nested: %{password: "hidden"},
                      body: String.duplicate("x", 1_200)
                    }}
                 end),
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

      refute message_snapshot(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "invalid-adapter-result"
             )
    end
  end

  defp complete_with_intents(input, intents) do
    Repo.transact(fn repo ->
      Ankole.Sessions.Queue.lock_session_in_tx(repo, input.agent_uid, input.session_id)
      input = Ankole.Signals.lock_signal_in_tx(repo, input.id)

      results =
        Enum.map(intents, fn attrs ->
          Map.merge(
            %{
              agent_uid: input.agent_uid,
              binding_name: input.reply_binding_name,
              conversation_id: input.conversation_id,
              reply_to_provider_message_id: input.provider_message_id,
              source_signal_id: input.id
            },
            attrs
          )
          |> then(&Ankole.Conversations.Delivery.commit_in_tx(repo, &1))
        end)

      with {:ok, _} <- Ankole.Attrs.collect_results(results),
           do:
             Ankole.Sessions.Queue.complete_signal_in_tx(repo, input,
               completed_at: DateTime.add(@base_time, 1, :second)
             )
    end)
  end
end
