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
      run_cron_fire: 2
    ]

  alias Ankole.E2E.FakeOpenAIState

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  test "checkback and cron schedules are created by tools and fire into turns" do
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

    cron_fire = run_cron_fire(ctx, cron.cron_schedule)

    assert_lark_final_reply(
      ctx.fake_feishu,
      cron_fire.reply,
      "CHAOS_CRON_WAKE_OK",
      :post,
      "oc_chaos_schedule"
    )

    counters = FakeOpenAIState.counters()
    assert counters[:checkback_tool] == 2
    assert counters[:checkback_wakeup] == 1
    assert counters[:cron_tool] == 2
    assert counters[:cron_wakeup] == 1
  end
end
