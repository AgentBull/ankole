defmodule Ankole.E2E.ChaosE2ETest do
  @moduledoc """
  Chaos scenarios: worker death mid-turn, RuntimeFabric restart, WS redelivery
  dedup, and provider-send failure consistency. Recovery must always come from
  PostgreSQL facts (fences, pending events, outbox state machine) — never from
  transport state.
  """

  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_until: 2, wait_for_completed_final_reply: 3]

  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.ReadyEventProcessor
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "worker killed mid-turn leaves no partial commit and the input replays on a new worker" do
    ctx = start_worker_e2e_stack!()

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_kill_1",
               message_id: "om_chaos_kill_1",
               chat_id: "oc_chaos_kill",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_FOLLOWUP_SLOW and reply exactly CHAOS_FOLLOWUP_FIRST_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_kill_1")

    # Short lease: after the worker dies, the activation must expire instead of
    # blocking the session forever.
    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: input.agent_uid, session_id: input.session_id},
               now: DateTime.add(input.available_at, 1, :second),
               lease_seconds: 5
             )

    # The fake upstream delays this scenario's completion by 1.5s, so the kill
    # lands while the turn is provably in flight.
    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000
    DockerWorker.kill_docker_worker!(ctx.container)

    # PG stays the source of truth: the input is still pending and nothing was
    # partially committed by the dead worker.
    assert %ActorEvent{completed_at: nil} = Repo.get(ActorEvent, input.id)

    assert [] =
             OutboxEntry
             |> where([outbox], outbox.source_actor_event_id == ^input.id)
             |> Repo.all()

    replacement_worker_id = "chaos-replacement-#{System.unique_integer([:positive])}"

    replacement =
      start_additional_worker!(ctx.endpoint, replacement_worker_id, ctx.worker_auth_key)

    # Re-dispatch after the lease expired. The first attempts may still pick the
    # dead worker's route; that failure marks the route unusable and the retry
    # lands on the replacement.
    retry_until_sent!(input, DateTime.add(input.available_at, 120, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(replacement, input.id, deadline(120_000))

    assert reply.text =~ "CHAOS_FOLLOWUP_FIRST_OK"
    assert_actor_event_completed!(input.id)

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_chaos_kill_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "RuntimeFabric router restart releases stale routes and replacement worker completes turns" do
    ctx = start_worker_e2e_stack!()

    router_port =
      case URI.parse(ctx.endpoint) do
        %URI{port: port} when is_integer(port) -> port
      end

    safe_stop_router()

    restart_router_on_port!(router_port, ctx.worker_auth_key)

    replacement_worker_id = "router-replacement-#{System.unique_integer([:positive])}"

    replacement =
      start_additional_worker!(ctx.endpoint, replacement_worker_id, ctx.worker_auth_key)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_router_restart_1",
               message_id: "om_chaos_router_restart_1",
               chat_id: "oc_chaos_router_restart",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_router_restart_1")

    # The worker reconnects on its own; dispatch retries until its re-admitted
    # route accepts the turn.
    retry_until_sent!(input, DateTime.add(input.available_at, 120, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(replacement, input.id, deadline(120_000))

    assert reply.text =~ "CHAOS_DIRECT_OK"

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_chaos_router_restart_1"
    )
  end

  @tag timeout: 120_000
  @tag ownership_timeout: 120_000
  test "event redelivery after a WS reconnect stays deduplicated" do
    ctx = start_worker_e2e_stack!(worker: false)

    attrs = [
      event_id: "evt_chaos_redelivery_1",
      message_id: "om_chaos_redelivery_1",
      chat_id: "oc_chaos_redelivery",
      chat_type: "p2p",
      text: "@_user_1 Deduplicate me across reconnects.",
      mentions: [lark_bot_mention()]
    ]

    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    assert %ActorEvent{} = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_redelivery_1")

    assert :ok = FakeFeishu.State.drop_ws_connections(ctx.fake_feishu.state)
    assert_receive {:fake_feishu, {:ws_disconnected, _conn_id}}, 15_000

    # FakeFeishu counts every WS accept. Waiting past the initial connection and
    # the dropped socket proves the adapter opened a fresh consumer before the
    # provider redelivery below.
    assert {:ok, _count} =
             wait_until(deadline(30_000), fn ->
               count = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
               count >= 3 && count
             end)

    # The provider redelivers the same event after reconnect; the gateway must
    # not create a second entry or a second actor event.
    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    wait_for_event_ack!(ctx.fake_feishu, "evt_chaos_redelivery_1")
    finalize_due_inbound_batches!()

    assert 1 ==
             ActorEvent
             |> where([input], input.agent_uid == ^ctx.agent.uid)
             |> where([input], input.source_entry_id == "om_chaos_redelivery_1")
             |> Repo.aggregate(:count)

    assert %{} = wait_for_signal_entry!("lark:oc_chaos_redelivery", "om_chaos_redelivery_1")
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "a rejected provider send leaves no platform message and retries cleanly" do
    ctx = start_worker_e2e_stack!(worker: false)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_sendfail_1",
               message_id: "om_chaos_sendfail_1",
               chat_id: "oc_chaos_sendfail",
               chat_type: "p2p",
               text: "/new",
               mentions: []
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_sendfail_1")
    assert input.type == "command.new"

    assert {:ok, %{status: :command_consumed, feedback: "Started a new conversation."}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert_actor_event_finished!(input.id)
    outbox = Repo.get_by!(OutboxEntry, source_actor_event_id: input.id)
    assert outbox.payload == %{"text" => "Started a new conversation."}

    # One-shot injected business rejection BEFORE any platform state change:
    # the dispatch attempt must fail without a visible message.
    FakeFeishu.State.fail_next(ctx.fake_feishu.state, :reply_message, {:code, 500_100})

    results = run_outbox_dispatch!()
    key = outbox.outbound_key

    failed_row =
      Enum.find_value(results, fn
        {_status, %OutboxEntry{outbound_key: ^key} = row} -> row
        _other -> nil
      end)

    assert failed_row, "outbox row missing from dispatch results: #{inspect(results)}"
    refute failed_row.status == :succeeded

    bot_visible =
      ctx.fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_chaos_sendfail")
      |> Enum.filter(&(&1.sender == :bot))

    assert bot_visible == []

    # Stand in for the dispatcher's backoff timer, then retry: exactly one
    # message becomes visible (uuid idempotency prevents duplicates).
    failed_row
    |> Ecto.Changeset.change(next_attempt_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    retried = dispatch_outbox_succeeded!(outbox)
    message = platform_message!(ctx.fake_feishu, retried.created_source_entry_id)
    assert message.text =~ "Started a new conversation."

    bot_visible_after =
      ctx.fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_chaos_sendfail")
      |> Enum.filter(&(&1.sender == :bot))

    assert length(bot_visible_after) == 1
  end

  # Re-dispatches one pending input until a live worker accepts it. Routes to
  # dead workers fail first and get marked unusable; that is the recovery path
  # under test, so the retry loop tolerates those outcomes.
  defp retry_until_sent!(input, now) do
    assert {:ok, _result} =
             wait_until(deadline(90_000), fn ->
               {:ok, _summary} = ActorRuntime.watchdog_once(lease_grace_seconds: 0)

               case ReadyEventProcessor.process_ready_event_for_actor(
                      %{agent_uid: input.agent_uid, session_id: input.session_id},
                      now: now,
                      lease_seconds: long_lease_seconds()
                    ) do
                 {:ok, %{send_outcome: "sent_or_queued"} = result} -> result
                 {:ok, _other} -> nil
                 {:error, _reason} -> nil
               end
             end),
           "input #{input.id} was never accepted by a live worker"
  end

  defp restart_router_on_port!(router_port, worker_auth_key) do
    endpoint = "tcp://0.0.0.0:#{router_port}"

    assert {:ok, _endpoint} =
             wait_until(deadline(5_000), fn ->
               case Broker.start_router(endpoint,
                      worker_auth_key: worker_auth_key,
                      poll_interval_ms: 1
                    ) do
                 {:ok, endpoint} -> {:ok, endpoint}
                 {:error, _reason} -> nil
               end
             end),
           "router did not release and restart on #{endpoint}"
  end
end
