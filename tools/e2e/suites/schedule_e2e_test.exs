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
      cron_event_for_schedule!: 1,
      deadline: 1,
      wait_for_completed_actor_event_message: 3,
      wait_until: 2
    ]

  import Ecto.Query

  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry

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
    assert counters[:cron_wakeup] == 1
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

    fire_input = fire_cron_schedule!(ctx, schedule)

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

    fire_input = fire_cron_schedule!(ctx, schedule)

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

  defp fire_cron_schedule!(ctx, schedule) do
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
