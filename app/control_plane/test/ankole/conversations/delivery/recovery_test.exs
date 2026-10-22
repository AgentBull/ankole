defmodule Ankole.Conversations.Delivery.RecoveryTest do
  use Ankole.DataCase, async: false

  alias Ankole.PluginFixtures.MockSignalProvider.Delivery, as: MockDelivery
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.InputTombstone
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.ReplyPresentation
  import Ankole.Conversations.Assertions

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import ExUnit.CaptureLog

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "intent recovery retry and cleanup" do
    test "recovery and explicit retry retain provider card anchors" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, _} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      anchors = %{
        "card_id" => "card-1",
        "message_id" => "message-1",
        "streaming_state" => "open",
        "active_card_index" => 0,
        "cards" => [%{"card_id" => "card-1"}]
      }

      assert {:ok, intent} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "keep-card-anchor",
                 operation: :post,
                 delivery_class: :durable_ai_reply,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "Retain this card.",
                 recovery_state: anchors
               })

      assert {:ok, unknown} =
               Repo.transact(fn repo ->
                 Ankole.Conversations.Delivery.Recovery.mark_intent_unknown(
                   repo,
                   intent,
                   %{"reason" => "uncertain"},
                   @base_time
                 )
               end)

      assert unknown.recovery_state == anchors
      assert unknown.recovery_status == :blocked
      assert unknown.possible_duplicate

      assert {:ok, requeued} =
               Delivery.requeue(agent.uid, "bot", intent.outbound_key, now: @base_time)

      assert requeued.recovery_state == anchors
      assert requeued.recovery_status == nil
      assert requeued.recovery_reason == nil
      assert requeued.possible_duplicate
      assert is_binary(requeued.possible_duplicate_notice)

      assert {:ok, failed} =
               Repo.transact(fn repo ->
                 Ankole.Conversations.Delivery.Recovery.mark_intent_failed(
                   repo,
                   requeued,
                   {:reply_delivery, :permanent, %{"code" => "provider_rejected"}},
                   @base_time
                 )
               end)

      assert failed.recovery_state == anchors
      assert failed.recovery_status == :permanent
      assert failed.recovery_reason == "permanent_failure"
      assert failed.possible_duplicate_notice == requeued.possible_duplicate_notice
    end

    test "in-flight intent recovers by reconciliation or marks unknown when unprovable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, unknown_seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-unknown",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "maybe sent"
               })

      {:ok, _sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(unknown_seed, :start_attempt, %{platform_send_started_at: @base_time})
        end)

      assert {:ok, still_sending} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 delivery_adapter([:post_entry], fn _intent ->
                   flunk("in-flight intent must not be sent again")
                 end),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert still_sending.status == :pending

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 delivery_adapter([:post_entry], fn _intent ->
                   flunk("unknown in-flight intent must not be sent again")
                 end),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown

      refute message_snapshot(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "maybe-provider-id"
             )

      assert {:ok, reconcile_seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-reconcile",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 delivery_class: :durable_ai_reply,
                 payload: %{
                   "text" => "confirmed",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "confirmed"
               })

      {:ok, _sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(reconcile_seed, :start_attempt, %{
            platform_send_started_at: @base_time
          })
        end)

      assert {:ok, recovered} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "started-reconcile",
                 delivery_adapter(
                   [:post_entry, :outbound_reconciliation],
                   fn _intent -> flunk("reconciled intent must not be sent again") end,
                   fn _intent ->
                     {:ok, %{created_provider_message_id: "confirmed-provider-id"}}
                   end
                 ),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert recovered.status == :sent

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "confirmed-provider-id"
             ).text == "confirmed"
    end

    test "a generic sending row is marked unknown even when the adapter declares outbound_reconciliation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "generic-unknown",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "maybe sent"
               })

      {:ok, _sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(seed, :start_attempt, %{platform_send_started_at: @base_time})
        end)

      adapter =
        delivery_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _intent -> flunk("recovery must not repeat a generic send") end,
          fn _intent -> flunk("a generic send has no reconciliation contract") end
        )

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "generic-unknown",
                 adapter,
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown
      assert unknown.last_error["reason"] == "provider send started without provider entry id"
    end

    test "invalid reconcile result marks in-flight intent unknown without crashing" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-invalid-reconcile",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 delivery_class: :durable_ai_reply,
                 payload: %{
                   "text" => "maybe sent",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "maybe sent"
               })

      {:ok, _sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(seed, :start_attempt, %{platform_send_started_at: @base_time})
        end)

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "started-invalid-reconcile",
                 delivery_adapter(
                   [:post_entry, :outbound_reconciliation],
                   fn _intent -> flunk("reconciled intent must not be sent again") end,
                   fn _intent -> :ok end
                 ),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown
      assert unknown.last_error["reason"] == "reconciliation adapter error"
      assert unknown.last_error["error"]["items"] |> hd() == "invalid_adapter_result"
    end

    test "a late send error cannot overwrite a terminal state committed by recovery" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "late-send-error",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 delivery_class: :durable_ai_reply,
                 payload: %{
                   "text" => "delivered by takeover",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "delivered by takeover"
               })

      takeover_adapter =
        delivery_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _intent -> flunk("takeover must reconcile, not send") end,
          fn _intent -> {:ok, %{created_provider_message_id: "takeover-provider-id"}} end
        )

      late_error_adapter =
        delivery_adapter([:post_entry], fn _intent ->
          assert {:ok, %Intent{status: :sent}} =
                   Ankole.Conversations.Delivery.dispatch(
                     agent.uid,
                     "bot",
                     "late-send-error",
                     takeover_adapter,
                     now: DateTime.add(@base_time, 61, :second)
                   )

          {:error, {:reply_delivery, :retryable, %{"code" => "late_timeout"}}}
        end)

      log =
        capture_log(fn ->
          assert {:ok, %Intent{status: :sent, attempt_count: 1}} =
                   Ankole.Conversations.Delivery.dispatch(
                     agent.uid,
                     "bot",
                     "late-send-error",
                     late_error_adapter,
                     now: @base_time
                   )
        end)

      assert log =~ "signals gateway intent ignored a stale attempt result"

      committed =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "late-send-error"
        )

      assert committed.status == :sent
      assert committed.next_attempt_at == nil
      assert committed.last_error == %{}

      refute Enum.any?(
               due_intent_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "late-send-error")
             )

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "takeover-provider-id"
             ).text == "delivered by takeover"
    end

    test "a late reconcile result cannot downgrade a succeeded durable reply" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "late-reconcile-unknown",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 payload: %{
                   "text" => "reconciled reply",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "reconciled reply"
               })

      {:ok, _sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(seed, :start_attempt, %{platform_send_started_at: @base_time})
        end)

      recovery_at = DateTime.add(@base_time, 61, :second)

      winner_adapter =
        delivery_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _intent -> flunk("winner must reconcile, not send") end,
          fn _intent -> {:ok, %{created_provider_message_id: "reconciled-provider-id"}} end
        )

      loser_adapter =
        delivery_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _intent -> flunk("loser must reconcile, not send") end,
          fn _intent ->
            assert {:ok, %Intent{status: :sent}} =
                     Ankole.Conversations.Delivery.dispatch(
                       agent.uid,
                       "bot",
                       "late-reconcile-unknown",
                       winner_adapter,
                       now: recovery_at
                     )

            :unknown
          end
        )

      log =
        capture_log(fn ->
          assert {:ok, %Intent{status: :sent}} =
                   Ankole.Conversations.Delivery.dispatch(
                     agent.uid,
                     "bot",
                     "late-reconcile-unknown",
                     loser_adapter,
                     now: recovery_at
                   )
        end)

      assert log =~ "signals gateway intent ignored a stale attempt result"

      committed =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "late-reconcile-unknown"
        )

      assert committed.status == :sent
      assert committed.next_attempt_at == nil
      refute committed.possible_duplicate

      refute Enum.any?(
               due_intent_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "late-reconcile-unknown")
             )

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "reconciled-provider-id"
             ).text == "reconciled reply"
    end

    test "Oban wakes a stale in-flight send for reconciliation" do
      use_mock_signal_provider_plugin()

      MockDelivery.put_reconcile_result(
        {:ok, %{created_provider_message_id: "stale-provider-id"}}
      )

      on_exit(fn -> MockDelivery.delete_reconcile_result() end)

      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, stale_seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "stale-sending",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 delivery_class: :durable_ai_reply,
                 payload: %{
                   "text" => "confirmed by reconcile",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "confirmed by reconcile"
               })

      due_now = DateTime.add(@base_time, 61, :second)

      {:ok, sending} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(stale_seed, :start_attempt, %{platform_send_started_at: @base_time})
        end)

      schedule_recovery(sending)

      assert {:ok, fresh_seed} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "fresh-sending",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 delivery_class: :durable_ai_reply,
                 payload: %{
                   "text" => "still in flight",
                   "reply_presentation" => ReplyPresentation.new(state: "completed")
                 },
                 fallback_visible_text: "still in flight"
               })

      {:ok, fresh} =
        Repo.transact(fn _repo ->
          Ankole.Ash.update(fresh_seed, :start_attempt, %{
            platform_send_started_at: DateTime.add(due_now, -30, :second)
          })
        end)

      schedule_recovery(fresh)

      assert [%{"outbound_key" => "stale-sending"}] = due_intent_events(due_now)

      assert {:ok, %Intent{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 agent.uid,
                 "bot",
                 "stale-sending",
                 now: due_now
               )

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "stale-provider-id"
             ).text == "confirmed by reconcile"
    end

    test "Oban wakeups honor the intent retry backoff" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-retry",
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "retry me"
               })

      assert {:ok, failed} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-retry",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:error,
                    {:reply_delivery, :retryable,
                     %{"code" => "rate_limited", "retry_after_seconds" => 30}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.next_attempt_at == DateTime.add(@base_time, 30, :second)

      assert {:error, :intent_not_due} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-retry",
                 delivery_adapter([:post_entry], fn _intent -> {:ok, %{}} end),
                 now: DateTime.add(@base_time, 1, :second)
               )

      due_now = DateTime.add(failed.next_attempt_at, 1, :microsecond)

      assert [%{"outbound_key" => "post-retry"}] = due_intent_events(due_now)

      assert {:ok, %Intent{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "post-retry",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == "retry me"
                   {:ok, %{created_provider_message_id: "retry-provider-id"}}
                 end),
                 now: due_now
               )
    end

    test "durable AI replies stop at the retry ceiling and explicit requeue keeps one row" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-retry",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 1,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "must eventually arrive"
               })

      assert {:ok, failed} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:error, {:reply_delivery, :retryable, %{"code" => 300_120}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.attempt_count == failed.max_attempts
      assert failed.next_attempt_at == nil
      assert failed.fallback_visible_text == "must eventually arrive"
      refute failed.possible_duplicate

      assert failed.recovery_status == :exhausted
      assert failed.recovery_reason == "max_attempts_reached"
      assert failed.recovery_state == %{}

      refute Enum.any?(
               due_intent_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "durable-retry")
             )

      assert {:error, :intent_manual_requeue_required} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 delivery_adapter([:post_entry], fn _intent -> flunk("exhausted row sent") end),
                 now: DateTime.add(@base_time, 1, :day)
               )

      requeue_at = DateTime.add(@base_time, 1, :day)

      assert {:ok, requeued} =
               Ankole.Conversations.Delivery.requeue(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 now: requeue_at
               )

      assert requeued.attempt_count == 1
      assert requeued.max_attempts == 2
      assert requeued.inserted_at == failed.inserted_at
      assert requeued.next_attempt_at == requeue_at
      assert requeued.recovery_state == %{}

      assert {:error, :intent_not_requeueable} =
               Ankole.Conversations.Delivery.requeue(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 now: requeue_at
               )

      assert Enum.any?(
               due_intent_events(requeue_at),
               &(&1["outbound_key"] == "durable-retry")
             )

      assert {:ok, %Intent{status: :sent, attempt_count: 2}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == "must eventually arrive"
                   {:ok, %{created_provider_message_id: "durable-provider-id"}}
                 end),
                 now: requeue_at
               )
    end

    test "uncertain durable reply stops until an explicit retry adds one possible-duplicate notice" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-unknown",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 3,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 payload: %{"text" => "possibly delivered"},
                 fallback_visible_text: "possibly delivered"
               })

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == "possibly delivered"
                   :unknown
                 end),
                 now: @base_time
               )

      assert unknown.status == :unknown
      assert unknown.attempt_count == 1
      assert is_nil(unknown.next_attempt_at)
      assert unknown.fallback_visible_text == "possibly delivered"

      assert {:error, :intent_not_dispatchable} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 delivery_adapter([:post_entry], fn _ ->
                   flunk("unknown delivery must not automatically retry")
                 end),
                 now: DateTime.add(@base_time, 60, :second)
               )

      notice = Ankole.I18n.t("conversations.delivery.reply.possible_duplicate_delivery")
      marked_text = notice <> "\n\npossibly delivered"
      second_attempt_at = DateTime.add(@base_time, 61, :second)

      assert {:ok, _} =
               Ankole.Conversations.Delivery.requeue(agent.uid, "bot", "durable-unknown",
                 now: second_attempt_at
               )

      assert {:ok, second_unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == marked_text
                   assert intent.payload["text"] == marked_text
                   :unknown
                 end),
                 now: second_attempt_at
               )

      assert second_unknown.status == :unknown
      assert second_unknown.attempt_count == 2
      assert is_nil(second_unknown.next_attempt_at)
      assert second_unknown.fallback_visible_text == marked_text
      assert second_unknown.payload["text"] == marked_text

      third_attempt_at = DateTime.add(second_attempt_at, 61, :second)

      assert {:ok, _} =
               Ankole.Conversations.Delivery.requeue(agent.uid, "bot", "durable-unknown",
                 now: third_attempt_at
               )

      assert {:ok, %Intent{status: :sent, attempt_count: 3}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == marked_text
                   assert intent.payload["text"] == marked_text
                   {:ok, %{created_provider_message_id: "unknown-recovery-provider-id"}}
                 end),
                 now: third_attempt_at
               )

      assert message_snapshot!(
               conversation_id: conversation_id!("lark:chat:group-a"),
               provider_message_id: "unknown-recovery-provider-id"
             ).text == marked_text
    end

    test "manual retry preserves one possible-duplicate notice after uncertainty exhausts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-unknown-manual",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 1,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 payload: %{"reply_presentation" => %{"answer" => ""}},
                 fallback_visible_text: "possibly delivered"
               })

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 delivery_adapter([:post_entry], fn _intent -> :unknown end),
                 now: @base_time
               )

      notice = Ankole.I18n.t("conversations.delivery.reply.possible_duplicate_delivery")
      marked_text = notice <> "\n\npossibly delivered"

      assert unknown.next_attempt_at == nil
      assert unknown.recovery_status == :blocked

      requeue_at = DateTime.add(@base_time, 1, :hour)

      assert {:ok, requeued} =
               Ankole.Conversations.Delivery.requeue(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 now: requeue_at
               )

      assert requeued.max_attempts == 2
      assert requeued.recovery_status == nil
      assert requeued.possible_duplicate == true
      assert requeued.fallback_visible_text == marked_text
      assert get_in(requeued.payload, ["reply_presentation", "answer"]) == notice

      assert {:ok, %Intent{status: :sent, attempt_count: 2}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 delivery_adapter([:post_entry], fn intent ->
                   assert intent.fallback_visible_text == marked_text
                   {:ok, %{created_provider_message_id: "manual-recovery-provider-id"}}
                 end),
                 now: requeue_at
               )
    end

    test "uncertain durable operation without visible text stays blocked" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-unknown-empty",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 2,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 payload: %{"text" => ""}
               })

      assert {:ok, unknown} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-unknown-empty",
                 delivery_adapter([:post_entry], fn _intent -> :unknown end),
                 now: @base_time
               )

      assert unknown.status == :unknown
      assert unknown.next_attempt_at == nil
      assert unknown.payload["text"] == ""
      assert unknown.recovery_status == :blocked

      assert unknown.recovery_reason ==
               "ambiguous_delivery_not_retried"

      refute Ankole.Conversations.Delivery.requeueable?(unknown)

      assert {:error, :intent_ambiguous_delivery_not_requeueable} =
               Ankole.Conversations.Delivery.requeue(
                 agent.uid,
                 "bot",
                 "durable-unknown-empty",
                 now: DateTime.add(@base_time, 1, :hour)
               )
    end

    test "permanent durable reply failure stops on its first provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-permanent",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "provider rejects this"
               })

      assert {:ok, failed} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-permanent",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:error, {:reply_delivery, :permanent, %{"code" => 40_201}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.attempt_count == 1
      assert failed.next_attempt_at == nil
      assert failed.recovery_status == :permanent
      assert failed.recovery_reason == "permanent_failure"

      refute Enum.any?(
               due_intent_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "durable-permanent")
             )
    end

    test "a reply whose attachment content is gone blocks at once for every adapter" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "missing-attachment",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "the report"
               })

      capture_log([level: :error], fn ->
        assert {:ok, %Intent{status: :failed}} =
                 Ankole.Conversations.Delivery.dispatch(
                   agent.uid,
                   "bot",
                   "missing-attachment",
                   delivery_adapter([:post_entry], fn _intent ->
                     {:error, :attachment_file_missing}
                   end),
                   now: @base_time
                 )
      end)

      blocked =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "missing-attachment"
        )

      assert blocked.next_attempt_at == nil
      assert blocked.recovery_status == :blocked
      assert blocked.last_error["reason"]["code"] == "attachment_file_missing"
    end

    test "operator-blocked durable replies wake when their binding is saved again" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-blocked",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 conversation_id: conversation_id!("lark:chat:group-a"),
                 fallback_visible_text: "blocked until config changes"
               })

      log =
        capture_log([level: :error], fn ->
          assert {:ok, %Intent{status: :failed}} =
                   Ankole.Conversations.Delivery.dispatch(
                     agent.uid,
                     "bot",
                     "durable-blocked",
                     delivery_adapter([:post_entry], fn _intent ->
                       {:error,
                        {:reply_delivery, :operator_action_required, %{"code" => 300_311}}}
                     end),
                     now: @base_time
                   )
        end)

      assert log =~ "signals gateway intent delivery stopped"

      blocked =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "durable-blocked"
        )

      assert blocked.status == :failed
      assert blocked.next_attempt_at == nil
      assert blocked.recovery_status == :blocked

      assert {:error, :intent_operator_action_required} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-blocked",
                 delivery_adapter([:post_entry], fn _intent -> {:ok, %{}} end),
                 now: DateTime.add(@base_time, 1, :day)
               )

      assert :ok = Delivery.wake_blocked_for_binding(agent.uid, "bot")

      woken =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "durable-blocked"
        )

      assert %DateTime{} = woken.next_attempt_at
      assert woken.attempt_count == 1
      assert woken.max_attempts == 2
      assert woken.recovery_state == %{}

      assert {:ok, %Intent{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "bot",
                 "durable-blocked",
                 delivery_adapter([:post_entry], fn _intent ->
                   {:ok, %{created_provider_message_id: "unblocked-provider-id"}}
                 end),
                 now: DateTime.add(woken.next_attempt_at, 1, :microsecond)
               )
    end

    test "TTL cleanup is an Oban default-queue worker over Signal and observation TTL tables" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, _} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-expiring"}),
                 now: @base_time
               )

      assert %Oban.Job{queue: "default"} =
               Ankole.Signals.Jobs.CleanupExpiredState.new(%{})
               |> Ecto.Changeset.apply_changes()

      counts =
        Ankole.Signals.StateCleanup.cleanup_expired_state(
          DateTime.add(@base_time, 2 * 24 * 60 * 60, :second)
        )

      assert counts.tombstones == 1
      assert Repo.aggregate(InputTombstone, :count) == 0
    end

    defp use_mock_signal_provider_plugin do
      original_state = :sys.get_state(Ankole.Plugins.Registry)
      {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

      :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
        %{
          discovered: %{spec.id => spec},
          active: %{spec.id => spec},
          enabled_ids: MapSet.new([spec.id])
        }
      end)

      on_exit(fn ->
        :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
      end)
    end
  end

  defp due_intent_events(now) do
    Repo.all(
      from job in Oban.Job,
        where:
          job.worker == "Ankole.Conversations.Delivery.Jobs.Dispatch" and
            job.state in ["available", "scheduled", "retryable"] and job.scheduled_at <= ^now,
        select: job.args
    )
  end

  defp schedule_recovery(intent) do
    :ok =
      Ankole.Conversations.Delivery.Jobs.Dispatch.schedule_in_tx(
        Repo,
        %{
          agent_uid: intent.agent_uid,
          binding_name: intent.binding_name,
          outbound_key: intent.outbound_key
        },
        DateTime.add(intent.platform_send_started_at, 60)
      )
  end
end
