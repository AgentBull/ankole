defmodule Ankole.E2E.ConcurrencyPerfE2ETest do
  @moduledoc """
  Basic concurrency and throughput baseline: N independent chats of two Agents
  drive direct turns on the two Agents' Worker containers without cross-talk,
  and streamed final replies land in their own chats.

  The wall-clock ceiling is deliberately loose — it guards against order-of-
  magnitude regressions, not an SLA.
  """

  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_for_completed_final_reply: 3, wait_until: 2]

  alias Ankole.E2E.DockerWorker
  alias Ankole.AgentWorkers.AgentWorker

  @chats 6
  @wall_clock_ceiling_ms 240_000

  setup do
    cleanup_committed_fixtures_on_exit!()
    :ok
  end

  @tag timeout: 600_000
  test "concurrent direct turns of two Agents stay isolated per chat" do
    ctx = start_worker_e2e_stack!(secondary: true)

    workers =
      Map.new(
        [ctx.agent, ctx.secondary_agent],
        &{&1.uid, Repo.get_by!(AgentWorker, agent_uid: &1.uid)}
      )

    started_ms = System.monotonic_time(:millisecond)

    inputs =
      for index <- 1..@chats do
        {agent, app_id, mention} =
          if rem(index, 2) == 1,
            do: {ctx.agent, primary_app_id(), lark_bot_mention()},
            else:
              {ctx.secondary_agent, secondary_app_id(),
               lark_bot_mention("ou_lark_bot_b", "@_user_1", "Agent B")}

        assert :ok =
                 FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
                   event_id: "evt_perf_#{index}",
                   message_id: "om_perf_#{index}",
                   chat_id: "oc_perf_chat_#{index}",
                   chat_type: "p2p",
                   text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
                   mentions: [mention],
                   to_app: app_id
                 )

        {index, agent, signal_by_provider_message_id!(agent.uid, "om_perf_#{index}")}
      end

    for {_index, _agent, input} <- inputs do
      assert {:ok, %{status: :driving}} =
               ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))
    end

    completed =
      for {index, agent, input} <- inputs do
        assert {:ok, reply, _message} =
                 wait_for_completed_final_reply(
                   DockerWorker.container(agent.uid),
                   input.id,
                   deadline(180_000)
                 )

        assert reply.message.text =~ "CHAOS_DIRECT_OK"

        assert reply.message.conversation_id ==
                 Ankole.Conversations.External.get_conversation("lark:oc_perf_chat_#{index}").id

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

    # Both Workers stayed on the same computer and connection for the whole run.
    for {agent_uid, before} <- workers do
      assert %AgentWorker{state: :ready} =
               after_run = Repo.get_by!(AgentWorker, agent_uid: agent_uid)

      assert after_run.generation == before.generation
      assert after_run.transport_route == before.transport_route
    end
  end
end
