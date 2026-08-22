defmodule Ankole.SignalsGatewayOutboxRecoveryTest do
  use Ankole.DataCase, async: false

  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Entry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import ExUnit.CaptureLog

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "outbox recovery retry and cleanup" do
    test "in-flight outbox recovers by reconciliation or marks unknown when unprovable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, unknown_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-unknown",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 created_source_entry_id: "maybe-provider-id"
               })

      {:ok, _sending} =
        unknown_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, still_sending} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 outbox_adapter([:post_entry], fn _outbox ->
                   flunk("in-flight outbox must not be sent again")
                 end),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert still_sending.status == :sending

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 outbox_adapter([:post_entry], fn _outbox ->
                   flunk("unknown in-flight outbox must not be sent again")
                 end),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown_after_send

      refute Repo.get_by(Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "maybe-provider-id"
             )

      assert {:ok, reconcile_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed",
                 created_source_entry_id: "confirmed-provider-id"
               })

      {:ok, _sending} =
        reconcile_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, recovered} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-reconcile",
                 outbox_adapter(
                   [:post_entry, :outbound_reconciliation],
                   fn _outbox -> flunk("reconciled outbox must not be sent again") end,
                   fn _outbox -> {:ok, %{created_source_entry_id: "confirmed-provider-id"}} end
                 ),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert recovered.status == :succeeded

      assert Repo.get_by!(
               Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "confirmed-provider-id"
             ).text == "confirmed"
    end

    test "invalid reconcile result marks in-flight outbox unknown without crashing" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-invalid-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 created_source_entry_id: "maybe-sent-provider-id"
               })

      {:ok, _sending} =
        seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-invalid-reconcile",
                 outbox_adapter(
                   [:post_entry, :outbound_reconciliation],
                   fn _outbox -> flunk("reconciled outbox must not be sent again") end,
                   fn _outbox -> :ok end
                 ),
                 now: DateTime.add(@base_time, 61, :second)
               )

      assert unknown.status == :unknown_after_send
      assert unknown.last_error["reason"] == "reconciliation adapter error"
      assert unknown.last_error["error"]["items"] |> hd() == "invalid_adapter_result"
    end

    test "a late send error cannot overwrite a terminal state committed by recovery" do
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
                 outbound_key: "late-send-error",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "delivered by takeover",
                 created_source_entry_id: "takeover-provider-id"
               })

      takeover_adapter =
        outbox_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _outbox -> flunk("takeover must reconcile, not send") end,
          fn _outbox -> {:ok, %{created_source_entry_id: "takeover-provider-id"}} end
        )

      late_error_adapter =
        outbox_adapter([:post_entry], fn _outbox ->
          assert {:ok, %OutboxEntry{status: :succeeded}} =
                   SignalsGateway.dispatch_outbox(
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
          assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 1}} =
                   SignalsGateway.dispatch_outbox(
                     agent.uid,
                     "bot",
                     "late-send-error",
                     late_error_adapter,
                     now: @base_time
                   )
        end)

      assert log =~ "signals gateway outbox ignored a stale attempt result"

      committed =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "late-send-error"
        )

      assert committed.status == :succeeded
      assert committed.next_attempt_at == nil
      assert committed.last_error == %{}

      refute Enum.any?(
               due_outbox_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "late-send-error")
             )

      assert Repo.get_by!(
               Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "takeover-provider-id"
             ).text == "delivered by takeover"
    end

    test "a late reconcile result cannot downgrade a succeeded durable reply" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "late-reconcile-unknown",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 payload: %{"text" => "reconciled reply"},
                 fallback_visible_text: "reconciled reply",
                 created_source_entry_id: "reconciled-provider-id"
               })

      {:ok, _sending} =
        seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      recovery_at = DateTime.add(@base_time, 61, :second)

      winner_adapter =
        outbox_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _outbox -> flunk("winner must reconcile, not send") end,
          fn _outbox -> {:ok, %{created_source_entry_id: "reconciled-provider-id"}} end
        )

      loser_adapter =
        outbox_adapter(
          [:post_entry, :outbound_reconciliation],
          fn _outbox -> flunk("loser must reconcile, not send") end,
          fn _outbox ->
            assert {:ok, %OutboxEntry{status: :succeeded}} =
                     SignalsGateway.dispatch_outbox(
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
          assert {:ok, %OutboxEntry{status: :succeeded}} =
                   SignalsGateway.dispatch_outbox(
                     agent.uid,
                     "bot",
                     "late-reconcile-unknown",
                     loser_adapter,
                     now: recovery_at
                   )
        end)

      assert log =~ "signals gateway outbox ignored a stale attempt result"

      committed =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "late-reconcile-unknown"
        )

      assert committed.status == :succeeded
      assert committed.next_attempt_at == nil
      refute committed.recovery_state["possible_duplicate"]

      refute Enum.any?(
               due_outbox_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "late-reconcile-unknown")
             )

      assert Repo.get_by!(
               Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "reconciled-provider-id"
             ).text == "reconciled reply"
    end

    test "outbox runtime event dispatch picks up stale in-flight sends for reconciliation" do
      use_mock_signal_provider_plugin()
      MockOutbox.put_reconcile_result({:ok, %{created_source_entry_id: "stale-provider-id"}})

      on_exit(fn -> MockOutbox.delete_reconcile_result() end)

      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, stale_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "stale-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed by reconcile",
                 created_source_entry_id: "stale-provider-id"
               })

      due_now = DateTime.add(@base_time, 61, :second)

      {:ok, _sending} =
        stale_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, fresh_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "fresh-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "still in flight",
                 created_source_entry_id: "fresh-provider-id"
               })

      {:ok, _fresh} =
        fresh_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: DateTime.add(due_now, -30, :second)
        })
        |> Repo.update()

      assert [%{"outbound_key" => "stale-sending"}] = due_outbox_events(due_now)

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox_by_key(
                 agent.uid,
                 "bot",
                 "stale-sending",
                 now: due_now
               )

      assert Repo.get_by!(
               Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "stale-provider-id"
             ).text == "confirmed by reconcile"
    end

    test "outbox runtime event dispatch honors retry backoff" do
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
                 outbound_key: "post-retry",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "retry me"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 outbox_adapter([:post_entry], fn _outbox ->
                   {:error,
                    {:reply_delivery, :retryable,
                     %{"code" => "rate_limited", "retry_after_seconds" => 30}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.next_attempt_at == DateTime.add(@base_time, 30, :second)

      assert {:error, :outbox_not_due} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 outbox_adapter([:post_entry], fn _outbox -> {:ok, %{}} end),
                 now: DateTime.add(@base_time, 1, :second)
               )

      due_now = DateTime.add(failed.next_attempt_at, 1, :microsecond)

      assert [%{"outbound_key" => "post-retry"}] = due_outbox_events(due_now)

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == "retry me"
                   {:ok, %{created_source_entry_id: "retry-provider-id"}}
                 end),
                 now: due_now
               )
    end

    test "durable AI replies stop at the retry ceiling and explicit requeue keeps one row" do
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
                 outbound_key: "durable-retry",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 1,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "must eventually arrive"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 outbox_adapter([:post_entry], fn _outbox ->
                   {:error, {:reply_delivery, :retryable, %{"code" => 300_120}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.attempt_count == failed.max_attempts
      assert failed.next_attempt_at == nil
      assert failed.fallback_visible_text == "must eventually arrive"
      refute failed.recovery_state["possible_duplicate"]

      assert failed.recovery_state == %{
               "state" => "exhausted",
               "reason" => "max_attempts_reached"
             }

      refute Enum.any?(
               due_outbox_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "durable-retry")
             )

      assert {:error, :outbox_manual_requeue_required} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 outbox_adapter([:post_entry], fn _outbox -> flunk("exhausted row sent") end),
                 now: DateTime.add(@base_time, 1, :day)
               )

      requeue_at = DateTime.add(@base_time, 1, :day)

      assert {:ok, requeued} =
               SignalsGateway.requeue_outbox(
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

      assert {:error, :outbox_not_requeueable} =
               SignalsGateway.requeue_outbox(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 now: requeue_at
               )

      assert Enum.any?(
               due_outbox_events(requeue_at),
               &(&1["outbound_key"] == "durable-retry")
             )

      assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 2}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-retry",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == "must eventually arrive"
                   {:ok, %{created_source_entry_id: "durable-provider-id"}}
                 end),
                 now: requeue_at
               )
    end

    test "uncertain durable reply retries with a visible possible-duplicate notice" do
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
                 outbound_key: "durable-unknown",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 3,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 payload: %{"text" => "possibly delivered"},
                 fallback_visible_text: "possibly delivered"
               })

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == "possibly delivered"
                   :unknown
                 end),
                 now: @base_time
               )

      notice = Ankole.I18n.t("signals_gateway.reply.possible_duplicate_delivery")
      marked_text = notice <> "\n\npossibly delivered"

      assert unknown.status == :unknown_after_send
      assert unknown.attempt_count == 1
      assert %DateTime{} = unknown.next_attempt_at
      assert unknown.fallback_visible_text == marked_text
      assert unknown.payload["text"] == marked_text
      assert unknown.recovery_state["possible_duplicate"] == true
      assert unknown.recovery_state["possible_duplicate_notice"] == notice

      second_attempt_at = DateTime.add(unknown.next_attempt_at, 1, :microsecond)

      assert Enum.any?(
               due_outbox_events(second_attempt_at),
               &(&1["outbound_key"] == "durable-unknown")
             )

      assert {:ok, second_unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == marked_text
                   assert outbox.payload["text"] == marked_text
                   :unknown
                 end),
                 now: second_attempt_at
               )

      assert second_unknown.status == :unknown_after_send
      assert second_unknown.attempt_count == 2
      assert %DateTime{} = second_unknown.next_attempt_at
      assert second_unknown.fallback_visible_text == marked_text
      assert second_unknown.payload["text"] == marked_text

      third_attempt_at = DateTime.add(second_unknown.next_attempt_at, 1, :microsecond)

      assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 3}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == marked_text
                   assert outbox.payload["text"] == marked_text
                   {:ok, %{created_source_entry_id: "unknown-recovery-provider-id"}}
                 end),
                 now: third_attempt_at
               )

      assert Repo.get_by!(
               Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "unknown-recovery-provider-id"
             ).text == marked_text
    end

    test "manual retry preserves one possible-duplicate notice after uncertainty exhausts" do
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
                 outbound_key: "durable-unknown-manual",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 1,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 payload: %{"reply_presentation" => %{"answer" => ""}},
                 fallback_visible_text: "possibly delivered"
               })

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 outbox_adapter([:post_entry], fn _outbox -> :unknown end),
                 now: @base_time
               )

      notice = Ankole.I18n.t("signals_gateway.reply.possible_duplicate_delivery")
      marked_text = notice <> "\n\npossibly delivered"

      assert unknown.next_attempt_at == nil
      assert unknown.recovery_state["state"] == "exhausted"

      requeue_at = DateTime.add(@base_time, 1, :hour)

      assert {:ok, requeued} =
               SignalsGateway.requeue_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 now: requeue_at
               )

      assert requeued.max_attempts == 2
      assert requeued.recovery_state["state"] == nil
      assert requeued.recovery_state["possible_duplicate"] == true
      assert requeued.fallback_visible_text == marked_text
      assert get_in(requeued.payload, ["reply_presentation", "answer"]) == notice

      assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 2}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown-manual",
                 outbox_adapter([:post_entry], fn outbox ->
                   assert outbox.fallback_visible_text == marked_text
                   {:ok, %{created_source_entry_id: "manual-recovery-provider-id"}}
                 end),
                 now: requeue_at
               )
    end

    test "uncertain durable operation without visible text stays blocked" do
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
                 outbound_key: "durable-unknown-empty",
                 delivery_class: :durable_ai_reply,
                 max_attempts: 2,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 payload: %{"text" => ""}
               })

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-unknown-empty",
                 outbox_adapter([:post_entry], fn _outbox -> :unknown end),
                 now: @base_time
               )

      assert unknown.status == :unknown_after_send
      assert unknown.next_attempt_at == nil
      assert unknown.payload["text"] == ""
      assert unknown.recovery_state["state"] == "blocked"

      assert unknown.recovery_state["reason"] ==
               "ambiguous_delivery_without_visible_text"

      refute SignalsGateway.requeueable_outbox?(unknown)

      assert {:error, :outbox_ambiguous_delivery_not_requeueable} =
               SignalsGateway.requeue_outbox(
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
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "durable-permanent",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "provider rejects this"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-permanent",
                 outbox_adapter([:post_entry], fn _outbox ->
                   {:error, {:reply_delivery, :permanent, %{"code" => 40_201}}}
                 end),
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.attempt_count == 1
      assert failed.next_attempt_at == nil
      assert failed.recovery_state["state"] == "permanent"
      assert failed.recovery_state["reason"] == "permanent_failure"

      refute Enum.any?(
               due_outbox_events(DateTime.add(@base_time, 1, :day)),
               &(&1["outbound_key"] == "durable-permanent")
             )
    end

    test "operator-blocked durable replies wake when their binding is saved again" do
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
                 outbound_key: "durable-blocked",
                 delivery_class: :durable_ai_reply,
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "blocked until config changes"
               })

      log =
        capture_log([level: :error], fn ->
          assert {:ok, %OutboxEntry{status: :failed}} =
                   SignalsGateway.dispatch_outbox(
                     agent.uid,
                     "bot",
                     "durable-blocked",
                     outbox_adapter([:post_entry], fn _outbox ->
                       {:error,
                        {:reply_delivery, :operator_action_required, %{"code" => 300_311}}}
                     end),
                     now: @base_time
                   )
        end)

      assert log =~ "signals gateway outbox delivery stopped"

      blocked =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "durable-blocked"
        )

      assert blocked.status == :failed
      assert blocked.next_attempt_at == nil
      assert blocked.recovery_state["state"] == "blocked"

      assert {:error, :outbox_operator_action_required} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-blocked",
                 outbox_adapter([:post_entry], fn _outbox -> {:ok, %{}} end),
                 now: DateTime.add(@base_time, 1, :day)
               )

      assert :ok = Outbox.wake_blocked_for_binding(agent.uid, "bot")

      woken =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "durable-blocked"
        )

      assert %DateTime{} = woken.next_attempt_at
      assert woken.attempt_count == 1
      assert woken.max_attempts == 2
      assert woken.recovery_state == %{}

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "durable-blocked",
                 outbox_adapter([:post_entry], fn _outbox ->
                   {:ok, %{created_source_entry_id: "unblocked-provider-id"}}
                 end),
                 now: DateTime.add(woken.next_attempt_at, 1, :microsecond)
               )
    end

    test "TTL cleanup is an Oban default-queue worker over SignalsGateway TTL tables" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, _} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-expiring"}),
                 now: @base_time
               )

      assert %Oban.Job{queue: "default"} =
               Ankole.SignalsGateway.Jobs.CleanupExpiredState.new(%{})
               |> Ecto.Changeset.apply_changes()

      counts =
        SignalsGateway.cleanup_expired_state(DateTime.add(@base_time, 2 * 24 * 60 * 60, :second))

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

  defp due_outbox_events(now) do
    SignalsGateway.runtime_event_snapshot()
    |> Enum.filter(fn {channel, payload} ->
      channel == RuntimeEvents.outbox_due_channel() and runtime_event_due?(payload, now)
    end)
    |> Enum.map(fn {_channel, payload} -> payload end)
  end

  defp runtime_event_due?(%{"due_at" => nil}, _now), do: true

  defp runtime_event_due?(%{"due_at" => due_at}, now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, due_at, _offset} -> DateTime.compare(due_at, now) != :gt
      _invalid -> false
    end
  end

  defp runtime_event_due?(_payload, _now), do: true
end
