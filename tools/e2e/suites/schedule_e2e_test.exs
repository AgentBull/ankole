defmodule Ankole.E2E.ScheduleE2ETest do
  @moduledoc """
  Schedule tools end to end: check_back_later and cron creation through the
  real worker tool loop, then firing the scheduled events back into turns.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness

  import Ankole.E2E.Scenarios.ScheduleAndTool,
    only: [
      run_checkback_tool_loop: 1,
      run_checkback_fire: 2,
      run_cron_tool_loop: 1,
      configure_cron_fanout: 2,
      run_cron_fire: 2
    ]

  import Ankole.E2E.WaitHelpers,
    only: [
      ai_messages_for_actor_event: 1,
      cron_event_for_schedule!: 1,
      deadline: 1,
      wait_for_actor_event_dead_letter: 3,
      wait_for_completed_actor_event_message: 3,
      wait_until: 2
    ]

  import Ecto.Query

  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :human_offboarding
  test "Human revocation lets the admitted Worker attempt finish and prevents old work after restoration" do
    alias Ankole.Principals.{HumanAccess, WorkCleanup}
    ctx = start_worker_e2e_stack!()
    checkback = run_checkback_tool_loop(ctx)
    cron = run_cron_tool_loop(ctx)
    uid = checkback.input.human_uid
    assert is_binary(uid)
    assert cron.input.human_uid == uid

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_offboarding_admitted",
               message_id: "om_offboarding_admitted",
               chat_id: "oc_offboarding_admitted",
               chat_type: "p2p",
               text: "CHAOS_FOLLOWUP_SLOW",
               mentions: [],
               create_time_ms: DateTime.to_unix(DateTime.add(base_time(), 30), :millisecond)
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_offboarding_admitted")
    assert input.human_uid == uid

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1))

    assert_receive {:fake_llm_request, :followup_slow, 1, _}, 15_000

    assert {:ok, disabled} =
             HumanAccess.restrict_from_provider(uid, "lark-main", "departure", "offboarding-e2e")

    assert {:ok, %{running: 1}} = WorkCleanup.cleanup(uid, disabled.access_version)

    assert {:ok, _message} =
             wait_for_completed_actor_event_message(ctx.container, input.id, deadline(60_000))

    assert_actor_event_completed!(input.id)

    assert Repo.get!(Ankole.Schedule.Schemas.ScheduledEvent, checkback.checkback.id).status ==
             "cancelled"

    assert Repo.get!(Ankole.Schedule.Schemas.CronSchedule, cron.cron_schedule.id).status ==
             "paused"

    assert {:error, :human_access_revoked} = Schedule.run_cron_schedule(cron.cron_schedule.id)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_offboarding_blocked",
               message_id: "om_offboarding_blocked",
               chat_id: "oc_offboarding_blocked",
               chat_type: "p2p",
               text: "CHAOS_FOLLOWUP_SECOND_OK",
               mentions: [],
               create_time_ms: DateTime.to_unix(DateTime.add(base_time(), 31), :millisecond)
             )

    wait_for_event_ack!(ctx.fake_feishu, "evt_offboarding_blocked")
    finalize_due_inbound_batch_events!()

    refute Repo.exists?(
             from e in ActorEvent, where: e.source_entry_id == "om_offboarding_blocked"
           )

    {:ok, ticket} = Ankole.IdentityProviders.DirectoryAccess.begin_sync("lark-main")

    {:ok, _} =
      Ankole.IdentityProviders.DirectoryAccess.finish_sync(
        ticket,
        "verified-return",
        [{uid, :healthy}],
        admission_scope: "none",
        maximum_removal_percent: 20
      )

    [restriction] = HumanAccess.restrictions(uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(
               uid,
               restriction.id,
               nil,
               "Verified current directory",
               "clear-e2e"
             )

    {:ok, review} = Ankole.AuthZ.restoration_review(uid)

    assert {:ok, _} =
             HumanAccess.restore(
               uid,
               review.fingerprint,
               nil,
               "Approved current permission rules",
               "restore-e2e"
             )

    assert {:error, :human_access_revoked} = Schedule.run_cron_schedule(cron.cron_schedule.id)
    assert {:ok, _} = WorkCleanup.cleanup(uid, disabled.access_version)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_offboarding_fresh",
               message_id: "om_offboarding_fresh",
               chat_id: "oc_offboarding_fresh",
               chat_type: "p2p",
               text: "CHAOS_FOLLOWUP_SECOND_OK",
               mentions: [],
               create_time_ms: DateTime.to_unix(DateTime.add(base_time(), 32), :millisecond)
             )

    fresh = actor_event_by_source_entry_id!(ctx.agent.uid, "om_offboarding_fresh")
    assert fresh.human_access_version == disabled.access_version

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(fresh, DateTime.add(fresh.available_at, 1))

    assert {:ok, _message} =
             wait_for_completed_actor_event_message(ctx.container, fresh.id, deadline(60_000))

    assert_actor_event_completed!(fresh.id)
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :schedule_fanout
  test "scheduled work runs once and cron results fan out with independent retry" do
    ctx = start_worker_e2e_stack!()

    checkback = run_checkback_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      checkback.reply,
      "CHAOS_CHECKBACK_OK",
      :reply,
      "om_checkback_tool_1"
    )

    checkback_wake = run_checkback_fire(ctx, checkback.checkback)

    assert_lark_final_reply(
      ctx.fake_feishu,
      checkback_wake.reply,
      "CHAOS_CHECKBACK_WAKE_OK",
      :reply,
      "om_checkback_tool_1"
    )

    cron = run_cron_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      cron.reply,
      "CHAOS_CRON_OK",
      :reply,
      "om_cron_tool_1"
    )

    cron_schedule = configure_cron_fanout(ctx, cron.cron_schedule)
    cron_fire = run_cron_fire(ctx, cron_schedule)

    assert_lark_final_reply(
      ctx.fake_feishu,
      cron_fire.reply,
      "CHAOS_CRON_WAKE_OK",
      :post,
      "oc_chaos_schedule"
    )

    assert_lark_final_reply(
      ctx.fake_feishu,
      cron_fire.secondary_reply,
      "CHAOS_CRON_WAKE_OK",
      :post,
      "oc_chaos_schedule_secondary"
    )

    assert Enum.sort(Enum.map(cron_fire.outboxes, & &1.attempt_count)) == [1, 2]

    counters = FakeOpenAIState.counters()
    assert counters[:checkback_tool] == 2
    assert counters[:checkback_wakeup] == 1
    assert counters[:cron_tool] == 2
    assert counters[:cron_wakeup] == 2

    for chat_id <- ["oc_chaos_schedule", "oc_chaos_schedule_secondary"],
        message <- FakeFeishu.State.visible_messages(ctx.fake_feishu.state, chat_id) do
      text =
        FakeFeishu.State.rendered_message_text(ctx.fake_feishu.state, message.id) || ""

      refute text =~ "<sাইলent_success/>"
      refute text =~ ~s("outcome")
    end
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :schedule_fanout
  test "a structured silent result completes without a platform message" do
    ctx = start_worker_e2e_stack!()
    cron = run_cron_tool_loop(ctx)

    assert {:ok, schedule} =
             Schedule.update_cron_schedule(cron.cron_schedule.id, %{
               "delivery" => Map.put(cron.cron_schedule.delivery, "quiet_success", true)
             })

    before_ids =
      Enum.map(
        FakeFeishu.State.visible_messages(ctx.fake_feishu.state, "oc_chaos_schedule"),
        & &1.id
      )

    fire_input = fire_cron_schedule!(schedule)

    assert {:ok, _message} =
             wait_for_completed_actor_event_message(
               ctx.container,
               fire_input.id,
               deadline(60_000)
             )

    assert Repo.get!(ActorEvent, fire_input.id).turn_outcome == "silent"

    refute Repo.exists?(
             from(entry in OutboxEntry, where: entry.source_actor_event_id == ^fire_input.id)
           )

    assert Enum.map(
             FakeFeishu.State.visible_messages(ctx.fake_feishu.state, "oc_chaos_schedule"),
             & &1.id
           ) == before_ids
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :schedule_fanout
  test "invalid scheduled results stop after a completed tool without replaying the task" do
    ctx = start_worker_e2e_stack!()
    cron = run_cron_tool_loop(ctx)

    assert {:ok, schedule} =
             Schedule.update_cron_schedule(cron.cron_schedule.id, %{
               "payload" => %{"task" => "CHAOS_CRON_INVALID_RESULT"}
             })

    fire_input = fire_cron_schedule!(schedule)

    assert {:ok, failed} =
             wait_for_actor_event_dead_letter(ctx.container, fire_input.id, deadline(60_000))

    assert is_nil(failed.completed_at)
    assert failed.dead_letter_reason["code"] == "invalid_scheduled_reply"

    messages = ai_messages_for_actor_event(fire_input.id)
    assert [_command] = tool_call_items(messages, "command")
    assert command_tool_succeeded?(messages)
    assert FakeOpenAIState.counters()[:cron_invalid_result] == 3

    activation =
      Repo.get_by!(ActorSessionActivation,
        agent_uid: fire_input.agent_uid,
        session_id: fire_input.session_id
      )

    refute ActorSessionActivation.live?(activation)

    refute Repo.exists?(
             from(delivery in ActorEventDelivery,
               where: delivery.actor_event_id == ^fire_input.id,
               where: delivery.state in ^ActorEventDelivery.live_states()
             )
           )

    assert {:ok, %{status: :idle}} =
             process_ready_event_for_actor!(
               fire_input,
               DateTime.add(activation.lease_expires_at, 1, :second)
             )

    assert FakeOpenAIState.counters()[:cron_invalid_result] == 3
    assert [_command] = tool_call_items(ai_messages_for_actor_event(fire_input.id), "command")

    notice =
      Repo.get_by!(OutboxEntry,
        source_actor_event_id: fire_input.id,
        outbound_key: "ai-dead-letter:#{fire_input.id}"
      )

    expected_notice =
      Ankole.I18n.t("signals_gateway.reply.dead_letter", %{"ref" => fire_input.id})

    assert notice.fallback_visible_text == expected_notice

    dispatch_and_assert_lark_outbox(
      ctx.fake_feishu,
      notice,
      expected_notice,
      :post,
      "oc_chaos_schedule"
    )

    for message <- FakeFeishu.State.visible_messages(ctx.fake_feishu.state, "oc_chaos_schedule") do
      text = FakeFeishu.State.rendered_message_text(ctx.fake_feishu.state, message.id) || ""
      refute text =~ "<sাইলent_success/>"
      refute text =~ ~s("outcome")
    end
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :schedule_fanout
  test "a cron target whose route is gone stops visibly while the other target delivers" do
    ctx = start_worker_e2e_stack!()

    cron = run_cron_tool_loop(ctx)
    schedule = configure_cron_fanout(ctx, cron.cron_schedule)

    # The route disappears after the schedule froze its target list. One
    # unreachable target must not cancel the others.
    secondary_channel_id = "lark:oc_chaos_schedule_secondary"
    assert %Channel{} = channel = Repo.get(Channel, secondary_channel_id)
    assert {:ok, _deleted} = Repo.delete(channel)

    fire_input = fire_cron_schedule!(schedule)

    assert {:ok, message} =
             wait_for_completed_actor_event_message(
               ctx.container,
               fire_input.id,
               deadline(60_000)
             )

    assert {:ok, [_, _] = rows} =
             wait_until(deadline(20_000), fn ->
               rows = final_reply_rows(fire_input.id, message.id)
               if length(rows) == 2, do: rows, else: nil
             end)

    by_channel = Map.new(rows, &{&1.signal_channel_id, &1})
    live = Map.fetch!(by_channel, "lark:oc_chaos_schedule")
    gone = Map.fetch!(by_channel, secondary_channel_id)

    refute live.status == :unsupported

    # Terminal and named, not a row that waits for a retry that cannot help.
    assert gone.status == :unsupported
    assert gone.last_error["code"] == "unroutable_reply_route"

    assert {:ok, stopped} = Outbox.list_stopped_deliveries(ctx.agent.uid)
    assert Enum.any?(stopped, &(&1.outbound_key == gone.outbound_key))
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :schedule_fanout
  test "a cron fire whose every target is gone still completes its Turn" do
    ctx = start_worker_e2e_stack!()

    cron = run_cron_tool_loop(ctx)
    schedule = configure_cron_fanout(ctx, cron.cron_schedule)

    for channel_id <- ["lark:oc_chaos_schedule", "lark:oc_chaos_schedule_secondary"] do
      assert %Channel{} = channel = Repo.get(Channel, channel_id)
      assert {:ok, _deleted} = Repo.delete(channel)
    end

    fire_input = fire_cron_schedule!(schedule)

    # Nobody can receive the answer, but the run still ends and every route says
    # why, instead of leaving the Turn stuck.
    assert {:ok, _message} =
             wait_for_completed_actor_event_message(
               ctx.container,
               fire_input.id,
               deadline(60_000)
             )

    assert %ActorEvent{completed_at: %DateTime{}} = Repo.get(ActorEvent, fire_input.id)

    rows =
      OutboxEntry
      |> where([row], row.source_actor_event_id == ^fire_input.id)
      |> Repo.all()

    assert rows != []
    assert Enum.all?(rows, &(&1.status == :unsupported))
  end

  defp fire_cron_schedule!(schedule) do
    cron_event = cron_event_for_schedule!(schedule.id)

    assert {:ok, %{status: :fired, actor_event: fire_input}} =
             Schedule.fire_due_event(cron_event.id, now: cron_event.due_at)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               fire_input,
               DateTime.add(cron_event.due_at, 1, :second)
             )

    fire_input
  end

  defp final_reply_rows(actor_event_id, ai_message_id) do
    OutboxEntry
    |> where([row], row.source_actor_event_id == ^actor_event_id)
    |> where([row], row.ai_message_id == ^ai_message_id)
    |> Repo.all()
  end
end
