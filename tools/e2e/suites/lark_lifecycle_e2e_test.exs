defmodule Ankole.E2E.LarkLifecycleE2ETest do
  @moduledoc """
  Turn lifecycle under interruption: malformed streams, recalls, /stop, /new,
  steering, ambient decisions, entry lifecycle, and daily session reset.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness

  import Ankole.E2E.Scenarios.Ingress,
    only: [run_direct_duplicate_and_llm_retry: 1, run_compress_command: 2]

  import Ankole.E2E.Scenarios.Lifecycle

  alias Ankole.E2E.FakeOpenAIState

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  test "cancellation, steering, ambient, entry lifecycle, and session reset" do
    ctx = start_worker_e2e_stack!()

    # Seed one completed direct conversation; the recalled-entry lifecycle and
    # /new scenarios below act on it.
    direct = run_direct_duplicate_and_llm_retry(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_direct_1"
    )

    failed = run_malformed_stream_failure(ctx)
    assert failed.message.status == "error"

    recalled = run_recall_during_generation(ctx)
    assert recalled.message.status == "error"

    stopped = run_stop_command_abort(ctx)
    assert stopped.message.status == "error"

    run_new_during_generation(ctx)

    run_steer_during_tool_boundary(ctx)
    run_idle_steer_generation(ctx)

    silent = run_ambient_silent_batch(ctx)
    assert silent.input.completed_at

    run_ambient_intervention(ctx)

    run_recalled_entry_lifecycle(ctx, direct.message.conversation_id)
    run_old_conversation_recall_after_new(ctx)
    run_daily_session_reset(ctx)
    run_new_command(ctx, direct.message.conversation_id)

    counters = FakeOpenAIState.counters()
    assert counters[:direct] >= 3
    assert Map.get(counters, :malformed_stream, 0) >= 1
    assert counters[:slow_recall_stream] == 1
    assert counters[:slow_stop_stream] == 1
    assert counters[:slow_new_stream] == 1
    assert counters[:new_after] == 1
    assert counters[:steer_tool] == 1
    assert counters[:steered_reply] == 1
    assert counters[:idle_steer] == 1
    assert counters[:ambient_noop_decision] == 1
    assert counters[:ambient_decision] == 1
    assert counters[:ambient_reply] == 1
    assert counters[:old_recall] == 1
    assert counters[:after_new_recall] == 1
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  test "/compress summarizes older transcript into a compaction artifact" do
    ctx = start_worker_e2e_stack!()

    direct = run_direct_duplicate_and_llm_retry(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_direct_1"
    )

    run_compress_command(ctx, direct.message.conversation_id)
  end
end
