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

  import Ankole.E2E.Scenarios.ScheduleAndTool, only: [run_reply_attachment_tool_loop: 1]

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_until: 2, wait_for_completed_final_reply: 3]

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.Workflow
  alias Ankole.Workflow.RunServer, as: WorkflowRunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "SIGTERM drains an active turn through completion acknowledgement without replay" do
    ctx = start_worker_e2e_stack!()

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_drain_1",
               message_id: "om_chaos_drain_1",
               chat_id: "oc_chaos_drain",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_FOLLOWUP_SLOW and reply exactly CHAOS_FOLLOWUP_FIRST_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_drain_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: input.agent_uid, session_id: input.session_id},
               now: DateTime.add(input.available_at, 1, :second),
               lease_seconds: 120
             )

    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000
    assert :ok = DockerWorker.signal_docker_worker!(ctx.container, "TERM")

    assert {:ok, %ActorEvent{completed_at: %DateTime{}, final_response_id: "resp_" <> _}} =
             wait_until(deadline(120_000), fn ->
               case Repo.get(ActorEvent, input.id) do
                 %ActorEvent{completed_at: %DateTime{}} = event -> event
                 _event -> nil
               end
             end)

    assert_receive {port, {:exit_status, 0}} when port == ctx.container.port, 30_000

    replacement_worker_id = "chaos-drain-replacement-#{System.unique_integer([:positive])}"

    replacement =
      start_additional_worker!(ctx.endpoint, replacement_worker_id, ctx.worker_auth_key)

    assert {:ok, %{status: :idle}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: input.agent_uid, session_id: input.session_id},
               now: DateTime.utc_now(:microsecond)
             )

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(replacement, input.id, deadline(120_000))

    assert FakeOpenAIState.counters()[:followup_slow] == 1

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_chaos_drain_1"
    )
  end

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
    assert {:ok, %{activation: activation, send_outcome: "sent_or_queued"}} =
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

    activation = Repo.reload(activation)
    replay_now = DateTime.add(activation.lease_expires_at, 1, :microsecond)

    case ActorRuntime.fail_activation_if_expired(activation.activation_uid, now: replay_now) do
      {:ok, _failed_activation} ->
        :ok

      {:error, :activation_not_due} ->
        assert Repo.reload(activation).status in ["failed", "stopped"]
    end

    replacement_worker_id = "chaos-replacement-#{System.unique_integer([:positive])}"

    replacement =
      start_additional_worker!(ctx.endpoint, replacement_worker_id, ctx.worker_auth_key)

    # Re-dispatch after the lease expired. The first attempts may still pick the
    # dead worker's route; that failure marks the route unusable and the retry
    # lands on the replacement.
    retry_until_sent!(input, replay_now)

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
  test "worker killed mid Workflow-task turn requeues the call and a new worker completes the run" do
    ctx = start_worker_e2e_stack!()

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_wf_kill_1",
               message_id: "om_chaos_wf_kill_1",
               chat_id: "oc_chaos_wf_kill",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_WF_KILL_START and reply exactly CHAOS_WF_KILL_STARTED_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_wf_kill_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: input.agent_uid, session_id: input.session_id},
               now: DateTime.add(input.available_at, 1, :second),
               lease_seconds: long_lease_seconds()
             )

    assert {:ok, start_reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert start_reply.text =~ "CHAOS_WF_KILL_STARTED_OK"

    run =
      Repo.one!(
        from(run in WorkflowRun,
          where: run.agent_uid == ^ctx.agent.uid,
          where: run.source_actor_event_id == ^input.id
        )
      )

    assert :ok = WorkflowRunServer.poke(run.id)

    assert {:ok, %AgentCall{} = call} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) do
                 %AgentCall{} = call -> {:ok, call}
                 nil -> nil
               end
             end)

    dispatch_event =
      Repo.get_by!(ActorEvent,
        agent_uid: ctx.agent.uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    # Short lease: the dead worker's activation must expire instead of holding
    # the task session.
    assert {:ok, %{activation: activation, send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: ctx.agent.uid, session_id: dispatch_event.session_id},
               now: DateTime.add(dispatch_event.available_at, 1, :second),
               lease_seconds: 5
             )

    # The fake upstream delays the task turn by 1.5s, so the kill lands while
    # the submit_result turn is provably in flight.
    assert_receive {:fake_llm_request, :workflow_kill_task, 1, _request}, 30_000
    DockerWorker.kill_docker_worker!(ctx.container)

    # PostgreSQL still owns the truth: the claimed call stays running with no
    # committed result.
    assert %AgentCall{status: "running", attempts: 1, result: nil} = Repo.get!(AgentCall, call.id)

    # The RunServer watchdog reconciles stale running tasks in production; run
    # the same function with the stale window logically elapsed.
    reconcile_now = DateTime.add(DateTime.utc_now(:microsecond), 6, :second)

    assert {:ok, %{reconciled: 1}} =
             Workflow.reconcile_stale_tasks(run.id, reconcile_now, reconcile_now)

    assert %AgentCall{status: "queued", attempts: 1} = Repo.get!(AgentCall, call.id)

    # The session activation still belongs to the dead worker until its lease
    # expiry is enforced, exactly as in the main-turn kill scenario.
    activation = Repo.reload(activation)
    expiry_now = DateTime.add(activation.lease_expires_at, 1, :microsecond)

    case ActorRuntime.fail_activation_if_expired(activation.activation_uid, now: expiry_now) do
      {:ok, _failed_activation} ->
        :ok

      {:error, :activation_not_due} ->
        assert Repo.reload(activation).status in ["failed", "stopped"]
    end

    replacement =
      start_additional_worker!(
        ctx.endpoint,
        "chaos-wf-replacement-#{System.unique_integer([:positive])}",
        ctx.worker_auth_key
      )

    # The retry clock must move past the dead activation's lease and follow the
    # +30s defer that an unsent Workflow dispatch writes into available_at.
    retry_result =
      wait_until(deadline(120_000), fn ->
        event = Repo.reload(dispatch_event)
        wall_now = DateTime.utc_now(:microsecond)

        base =
          if DateTime.compare(event.available_at, wall_now) == :gt,
            do: event.available_at,
            else: wall_now

        retry_now = DateTime.add(base, 1, :second)

        outcome =
          ReadyEventProcessor.process_ready_event_for_actor(
            %{agent_uid: ctx.agent.uid, session_id: event.session_id},
            now: retry_now,
            lease_seconds: long_lease_seconds()
          )

        Process.put(:wf_chaos_retry_outcome, outcome)

        case outcome do
          {:ok, %{send_outcome: "sent_or_queued"} = result} -> result
          {:ok, _other} -> nil
          {:error, _reason} -> nil
        end
      end)

    case retry_result do
      {:ok, _sent} ->
        :ok

      :timeout ->
        flunk(
          "the requeued Workflow task was never accepted by the replacement worker; " <>
            "last outcome: #{inspect(Process.get(:wf_chaos_retry_outcome), limit: 20)}"
        )
    end

    assert {:ok, %AgentCall{} = call} =
             wait_until(deadline(120_000), fn ->
               case Repo.get!(AgentCall, call.id) do
                 %AgentCall{status: "succeeded"} = done -> {:ok, done}
                 %AgentCall{status: status} when status in ["failed", "cancelled"] -> {:ok, call}
                 _pending -> nil
               end
             end)

    assert call.status == "succeeded"
    assert call.result == %{"ok" => true, "value" => "killed-and-recovered"}
    assert call.attempts == 2

    assert :ok = WorkflowRunServer.poke(run.id)

    assert {:ok, %ActorEvent{} = completion} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(ActorEvent,
                      agent_uid: ctx.agent.uid,
                      source_event_id: "workflow:#{run.id}:completed"
                    ) do
                 %ActorEvent{} = event -> {:ok, event}
                 nil -> nil
               end
             end)

    assert Repo.get!(WorkflowRun, run.id).status == "completed"

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: ctx.agent.uid, session_id: completion.session_id},
               now: DateTime.add(completion.available_at, 1, :second),
               lease_seconds: long_lease_seconds()
             )

    assert {:ok, done_reply, _message} =
             wait_for_completed_final_reply(replacement, completion.id, deadline(120_000))

    assert done_reply.text =~ "CHAOS_WF_KILL_DONE_OK"

    assert_lark_final_reply(
      ctx.fake_feishu,
      done_reply,
      "CHAOS_WF_KILL_DONE_OK",
      :reply,
      "om_chaos_wf_kill_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "RuntimeFabric router restart reauthenticates the old route and a live worker completes turns" do
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

    assert {:ok, %AgentComputerWorker{status: "ready", stop_reason: nil}} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(AgentComputerWorker, worker_id: ctx.worker_id) do
                 %AgentComputerWorker{status: "ready"} = worker -> worker
                 _worker -> nil
               end
             end)

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
    retry_until_sent!(input, DateTime.add(input.available_at, 1, :second))

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
  test "live worker heartbeat rebuilds its missing volatile registry row" do
    ctx = start_worker_e2e_stack!()
    worker = Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)

    assert {:ok, _deleted} = Repo.delete(worker)
    assert is_nil(Repo.get_by(AgentComputerWorker, worker_id: ctx.worker_id))

    assert {:ok, %AgentComputerWorker{} = recovered} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(AgentComputerWorker, worker_id: ctx.worker_id) do
                 %AgentComputerWorker{id: id, status: "ready"} = current
                 when id != worker.id ->
                   current

                 _worker ->
                   nil
               end
             end)

    assert recovered.incarnation_id == worker.incarnation_id
    assert recovered.transport_route == worker.transport_route
    assert recovered.version == worker.version
    assert recovered.capacity == worker.capacity
    assert recovered.load == %{"active_turns" => 0}
    assert recovered.metadata == worker.metadata
    assert DateTime.after?(recovered.last_worker_heartbeat_at, worker.last_worker_heartbeat_at)
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "an attachment removed after the turn commits blocks delivery without a phantom file message" do
    ctx = start_worker_e2e_stack!()
    %{outbox: outbox} = run_reply_attachment_tool_loop(ctx)

    assert [
             %{"user_files_relative_path" => relative_path}
           ] = outbox.payload["attachments"]

    host_path =
      Path.join([
        ctx.container.agents_root,
        ctx.agent.uid,
        "user-files",
        relative_path
      ])

    assert File.regular?(host_path)
    assert :ok = File.rm(host_path)

    results = run_outbox_dispatch!()
    key = outbox.outbound_key

    failed_row =
      Enum.find_value(results, fn
        {_status, %OutboxEntry{outbound_key: ^key} = row} -> row
        _other -> nil
      end)

    assert failed_row, "outbox row missing from dispatch results: #{inspect(results)}"
    assert failed_row.status == :failed
    assert failed_row.attempt_count == 1
    assert failed_row.next_attempt_at == nil

    assert failed_row.recovery_state == %{
             "reason" => "operator_action_required",
             "state" => "blocked"
           }

    assert get_in(failed_row.last_error, ["reason", "code"]) == "attachment_file_missing"
    assert get_in(failed_row.last_error, ["reason", "worker_file_code"]) == "file_not_found"

    refute_receive {:fake_feishu, {:file_uploaded, _file_key}}, 100

    refute ctx.fake_feishu.state
           |> FakeFeishu.State.visible_messages("oc_chaos_reply_attachment")
           |> Enum.any?(&(&1.sender == :bot and &1.msg_type == "file"))
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

    initial_connection_count = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
    assert initial_connection_count > 0
    assert :ok = FakeFeishu.State.drop_ws_connections(ctx.fake_feishu.state)

    for _index <- 1..initial_connection_count do
      assert_receive {:fake_feishu, {:ws_disconnected, _conn_id}}, 15_000
    end

    # Wait until every dropped consumer has a replacement. The disconnect
    # events remove the old connections before a matching count can succeed.
    assert {:ok, _count} =
             wait_until(deadline(30_000), fn ->
               count = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
               count >= initial_connection_count && count
             end)

    # The provider redelivers the same event after reconnect; the gateway must
    # not create a second entry or a second actor event.
    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    wait_for_event_ack!(ctx.fake_feishu, "evt_chaos_redelivery_1")
    finalize_due_inbound_batch_events!()

    redelivered_events =
      ActorEvent
      |> where([input], input.agent_uid == ^ctx.agent.uid)
      |> where([input], input.source_entry_id == "om_chaos_redelivery_1")
      |> order_by([input], asc: input.inserted_at, asc: input.id)
      |> Repo.all()

    assert length(redelivered_events) == 1, inspect(redelivered_events, limit: :infinity)

    assert %{} = wait_for_signal_entry!("lark:oc_chaos_redelivery", "om_chaos_redelivery_1")
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "a rejected provider send leaves no platform message and stops for good" do
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

    # A non-transport business rejection of a plain send is permanent: no
    # automatic retry may fire, and the row must carry the recovery state
    # that records the stop instead of failing silently.
    assert failed_row.status == :failed
    assert failed_row.recovery_state["state"] == "permanent"
    assert failed_row.next_attempt_at == nil

    assert {:error, :outbox_manual_requeue_required} =
             Ankole.SignalsGateway.dispatch_outbox_by_key(
               failed_row.agent_uid,
               failed_row.binding_name,
               failed_row.outbound_key,
               now: DateTime.utc_now(:microsecond)
             )

    # A `:generic` delivery (command feedback) has no operator requeue
    # surface — permanent means stopped for good; only `:durable_ai_reply`
    # rows accept an explicit retry.
    assert failed_row.delivery_class == :generic

    assert {:error, :outbox_not_requeueable} =
             Ankole.SignalsGateway.requeue_outbox(
               failed_row.agent_uid,
               failed_row.binding_name,
               failed_row.outbound_key
             )

    # Stopped means stopped: nothing was partially sent then or later.
    bot_visible_after =
      ctx.fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_chaos_sendfail")
      |> Enum.filter(&(&1.sender == :bot))

    assert bot_visible_after == []
  end

  # Re-dispatches one pending input until a live worker accepts it. Routes to
  # dead workers fail first and get marked unusable; that is the recovery path
  # under test, so the retry loop tolerates those outcomes.
  defp retry_until_sent!(input, now) do
    assert {:ok, _result} =
             wait_until(deadline(90_000), fn ->
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
