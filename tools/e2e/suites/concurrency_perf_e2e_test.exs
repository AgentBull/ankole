defmodule Ankole.E2E.ConcurrencyPerfE2ETest do
  @moduledoc """
  Basic concurrency and throughput baseline: N independent chats drive direct
  turns across two worker containers without cross-talk, and streamed final
  replies land in their own chats.

  The wall-clock ceiling is deliberately loose — it guards against order-of-
  magnitude regressions, not an SLA.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_for_completed_final_reply: 3, wait_until: 2]


  @chats 6
  @wall_clock_ceiling_ms 240_000

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "concurrent direct turns across two workers stay isolated per chat" do
    ctx = start_worker_e2e_stack!()

    second_worker_id = "lark-e2e-worker-#{System.unique_integer([:positive])}"

    second_container =
      start_additional_worker!(ctx.endpoint, second_worker_id, ctx.worker_auth_key)

    started_ms = System.monotonic_time(:millisecond)

    inputs =
      for index <- 1..@chats do
        assert :ok =
                 FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
                   event_id: "evt_perf_#{index}",
                   message_id: "om_perf_#{index}",
                   chat_id: "oc_perf_chat_#{index}",
                   chat_type: "p2p",
                   text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
                   mentions: [lark_bot_mention()]
                 )

        {index, actor_event_by_source_entry_id!(ctx.agent.uid, "om_perf_#{index}")}
      end

    for {_index, input} <- inputs do
      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               wait_until(deadline(180_000), fn ->
                 case process_ready_event_for_actor!(
                        input,
                        DateTime.add(input.available_at, 1, :second)
                      ) do
                   {:error, :no_worker_available} -> nil
                   {:ok, %{status: :idle}} -> nil
                   result -> result
                 end
               end)
    end

    completed =
      for {index, input} <- inputs do
        assert {:ok, reply, _message} =
                 wait_for_completed_final_reply(ctx.container, input.id, deadline(180_000))

        assert reply.text =~ "CHAOS_DIRECT_OK"
        assert reply.signal_channel_id == "lark:oc_perf_chat_#{index}"
        {index, input, reply}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert elapsed_ms < @wall_clock_ceiling_ms,
           "#{@chats} concurrent direct turns took #{elapsed_ms}ms (ceiling #{@wall_clock_ceiling_ms}ms)"

    # No cross-talk: every streamed final reply lands in its own chat.
    for {index, _input, reply} <- completed do
      assert_lark_final_reply(
        ctx.fake_feishu,
        reply,
        "CHAOS_DIRECT_OK",
        :reply,
        "om_perf_#{index}"
      )
    end

    # Both containers stayed admitted for the whole run.
    assert Repo.get_by!(Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker,
             worker_id: ctx.worker_id
           )

    assert Repo.get_by!(Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker,
             worker_id: second_worker_id
           )

    _keep_referenced = second_container
  end
end
