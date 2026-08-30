defmodule Ankole.E2E.LarkMainFlowE2ETest do
  @moduledoc """
  Main user-story flow: fake Feishu WS ingress drives the real Docker worker
  and the real Lark outbox HTTP path. Scenarios run serially against one worker
  container; the fake-LLM counters at the end pin the exact upstream traffic.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.Ingress

  alias Ankole.E2E.FakeOpenAIState

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  test "ingress guardrails, direct turns, isolation, followups, and /retry" do
    ctx = start_worker_e2e_stack!(secondary: true, multi_agent: true)

    run_lark_adapter_guardrails(ctx)
    run_unaddressed_ignore_guardrail(ctx)
    run_observe_all_record_only_projection(ctx)

    direct = run_direct_duplicate_and_llm_retry(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_direct_1"
    )

    isolation = run_channel_session_isolation(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      isolation.reply,
      "CHAOS_GROUP_ISOLATION_OK",
      :reply,
      "om_group_isolation_check_1"
    )

    run_multi_agent_mention_isolation(ctx)

    run_followup_queue(ctx)
    run_recalled_followup_queue(ctx)

    retry = run_retry_command(ctx, direct.input.id)

    assert_lark_final_reply(
      ctx.fake_feishu,
      retry.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_direct_1"
    )

    counters = FakeOpenAIState.counters()
    assert counters[:direct] >= 2
    assert counters[:dm_isolation_seed] == 1
    assert counters[:group_isolation_check] == 1
    assert counters[:followup_slow] == 1
    assert counters[:followup_second] == 1
    assert counters[:followup_recall_slow] == 1
    assert Map.get(counters, :recalled_followup, 0) == 0
  end
end
