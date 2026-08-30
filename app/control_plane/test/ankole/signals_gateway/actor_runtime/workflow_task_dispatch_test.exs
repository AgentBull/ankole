defmodule Ankole.SignalsGateway.ActorRuntime.WorkflowTaskDispatchTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.WorkflowTaskDispatch
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  test "dispatch claims the task with its profile, context, and independent conversation" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    profiles = [
      {"heavy", "light", "heavy"},
      {nil, "light", "light"},
      {nil, nil, "primary"}
    ]

    for {call_profile, run_profile, expected_profile} <- profiles do
      arguments =
        %{"prompt" => "Use the #{expected_profile} profile."}
        |> maybe_put("model_profile", call_profile)

      %{run: run, calls: [call], events: [event]} =
        workflow_fixture(agent.uid,
          model_profile: run_profile,
          arguments: [arguments]
        )

      actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
      now = DateTime.add(event.available_at, 1, :second)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: now,
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 200
      turn_start = turn_start_payload!(envelope)
      context = decoded_request_context(turn_start)

      assert turn_start.turn.actor.session_id == actor_key.session_id
      assert turn_start.model_ref.profile == expected_profile
      assert context["run_id"] == run.id
      assert context["call_id"] == call.id
      refute Map.has_key?(context, "turn_mode")
      refute Map.has_key?(context, "attempts")

      assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, call.id)

      conversation =
        Repo.get_by!(Conversation,
          subject_uid: agent.uid,
          conversation_key: actor_key.session_id
        )

      refute Map.has_key?(conversation.metadata, "origin")
    end
  end

  test "a missing worker defers the same queued event without claiming" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    now = DateTime.add(event.available_at, 1, :second)
    retry_at = DateTime.add(now, 30, :second)

    assert {:ok,
            %{
              status: :waiting_for_worker,
              reason: :worker_capacity,
              actor_event: deferred
            }} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert deferred.id == event.id
    assert deferred.available_at == retry_at
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, call.id)

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: actor_key.session_id
           )
  end

  test "a released run slot wakes exactly the earliest capacity-deferred task" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{calls: [first, second, third], events: [_first_event, second_event, _third_event]} =
      workflow_fixture(agent.uid,
        concurrency: 1,
        arguments: [
          %{"prompt" => "Occupy the run slot."},
          %{"prompt" => "Wait first for the run slot."},
          %{"prompt" => "Wait second for the run slot."}
        ]
      )

    assert {:ok, %{call: %AgentCall{status: "running"}}} =
             Workflow.claim_task_in_tx(Repo, first.id, agent.uid, 8)

    second_actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(second.id)}
    third_actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(third.id)}
    now = DateTime.add(second_event.available_at, 1, :second)
    deferred_at = DateTime.add(now, 30, :second)

    assert {:ok,
            %{status: :waiting_for_worker, reason: :agent_capacity, actor_event: second_event}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert {:ok,
            %{status: :waiting_for_worker, reason: :agent_capacity, actor_event: third_event}} =
             ReadyEventProcessor.process_ready_event_for_actor(third_actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert second_event.available_at == deferred_at
    assert third_event.available_at == deferred_at
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, second.id)
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, third.id)
    refute_receive {:actor_lane, _envelope}, 50

    before_submit = DateTime.utc_now(:microsecond)

    assert {:ok, %{accepted: true, call: %AgentCall{status: "succeeded"}}} =
             Workflow.submit_result(
               first.id,
               agent.uid,
               Workflow.task_session_id(first.id),
               %{"ok" => true, "value" => "released"}
             )

    after_submit = DateTime.utc_now(:microsecond)
    awakened = Repo.get!(ActorEvent, second_event.id)
    still_deferred = Repo.get!(ActorEvent, third_event.id)

    assert DateTime.compare(awakened.available_at, before_submit) in [:eq, :gt]
    assert DateTime.compare(awakened.available_at, after_submit) in [:eq, :lt]
    assert still_deferred.available_at == deferred_at

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_actor_key,
               now: after_submit,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _envelope}, 200
    assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, second.id)
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, third.id)
  end

  test "an already running task defers its same dispatch event" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)

    assert {:ok, %{call: %AgentCall{status: "running", attempts: 1}}} =
             Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    now = DateTime.add(event.available_at, 1, :second)

    assert {:ok, %{status: :waiting_for_worker, reason: :task_running, actor_event: deferred}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key, now: now)

    assert deferred.id == event.id
    assert deferred.available_at == DateTime.add(now, 30, :second)
    assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, call.id)
  end

  test "terminal calls and runs complete dispatch events without starting turns" do
    %{principal: agent} = agent_fixture()

    %{run: running_run, calls: [succeeded], events: [succeeded_event]} =
      workflow_fixture(agent.uid)

    assert {:ok, %{call: running_call}} =
             Workflow.claim_task_in_tx(Repo, succeeded.id, agent.uid, 8)

    assert {:ok, %{accepted: true, call: %AgentCall{status: "succeeded"}}} =
             Workflow.submit_result(
               running_call.id,
               agent.uid,
               Workflow.task_session_id(running_call.id),
               %{"ok" => true, "value" => "done"}
             )

    first_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(succeeded.id)}
    first_now = DateTime.add(succeeded_event.available_at, 1, :second)

    assert {:ok, %{status: :idle, actor_event: completed_call_event}} =
             ReadyEventProcessor.process_ready_event_for_actor(first_key, now: first_now)

    assert %DateTime{} = completed_call_event.completed_at
    assert Repo.get!(Run, running_run.id).status == "running"

    %{run: failed_run, calls: [queued], events: [queued_event]} = workflow_fixture(agent.uid)

    assert {:ok, %{run: %Run{status: "failed"}}} =
             Workflow.fail_replay(
               failed_run.id,
               "program_execution_failed",
               "The program stopped before this queued task started.",
               0
             )

    second_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(queued.id)}
    second_now = DateTime.add(queued_event.available_at, 1, :second)

    assert {:ok, %{status: :idle, actor_event: completed_run_event}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key, now: second_now)

    assert %DateTime{} = completed_run_event.completed_at
    assert %AgentCall{status: "cancelled", attempts: 0} = Repo.get!(AgentCall, queued.id)
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "transport failure rolls back the unstarted claim and defers the same event" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    now = DateTime.add(event.available_at, 1, :second)

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_delivery, actor_event: deferred}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert deferred.id == event.id
    assert deferred.available_at == DateTime.add(now, 30, :second)
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, call.id)
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "an unavailable model profile fails the unstarted task and completes its event" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)

    %{run: run, calls: [call], events: [event]} =
      workflow_fixture(agent.uid,
        arguments: [
          %{
            "prompt" => "Use a missing profile.",
            "model_profile" => "missing_workflow_profile"
          }
        ]
      )

    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    now = DateTime.add(event.available_at, 1, :second)

    assert {:ok,
            %{
              status: :model_profile_unavailable,
              actor_event: completed_event,
              call: %AgentCall{status: "failed", attempts: 0} = failed_call
            }} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert %DateTime{} = completed_event.completed_at
    assert failed_call.result["code"] == "workflow_model_profile_unavailable"
    assert failed_call.result["ok"] == false
    assert Repo.get!(Run, run.id).status == "running"
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "turn errors reuse one dispatch event until the third call attempt fails" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}

    reason =
      turn_error_reason(
        "workflow_worker_failed",
        "The Workflow Worker failed.",
        %{"retryable" => true}
      )

    terminal_dispatch_at =
      Enum.reduce(1..3, DateTime.add(event.available_at, 1, :second), fn attempt, dispatch_at ->
        assert {:ok, %{send_outcome: "sent_or_queued"}} =
                 ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                   now: dispatch_at,
                   lease_seconds: @long_lease_seconds
                 )

        assert_receive {:actor_lane, envelope}, 200
        turn_start = turn_start_payload!(envelope)
        turn_ref = turn_start.turn

        assert turn_ref.actor_event_id == event.id
        assert decoded_request_context(turn_start)["call_id"] == call.id

        assert {:ok,
                %{
                  status: :turn_failed,
                  dead_lettered?: false,
                  actor_event: failed_event,
                  retry_available_at: retry_available_at,
                  turn_error_compensation: %{call: compensated_call}
                }} =
                 ActorRuntime.handle_turn_error(domain_turn_ref(turn_ref), reason,
                   now: DateTime.add(dispatch_at, 1, :second)
                 )

        assert failed_event.id == event.id
        assert failed_event.input_state == "open"
        assert is_nil(failed_event.dead_letter_at)
        refute Repo.get_by(OutboxEntry, outbound_key: "ai-dead-letter:#{event.id}")

        if attempt < 3 do
          assert %AgentCall{status: "queued", attempts: ^attempt, id: call_id} =
                   compensated_call

          assert call_id == call.id

          assert %AgentCall{status: "queued", attempts: ^attempt} =
                   Repo.get!(AgentCall, call.id)
        else
          assert %AgentCall{status: "failed", attempts: 3, id: call_id} = compensated_call
          assert call_id == call.id
          assert compensated_call.result["code"] == "workflow_worker_failed"
          assert is_nil(Repo.get!(ActorEvent, event.id).completed_at)
        end

        retry_available_at
      end)

    assert {:ok,
            %{
              status: :idle,
              actor_event: completed_event,
              call: %AgentCall{status: "failed", attempts: 3}
            }} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: terminal_dispatch_at,
               lease_seconds: @long_lease_seconds
             )

    assert completed_event.id == event.id
    assert %DateTime{} = completed_event.completed_at
    assert is_nil(completed_event.dead_letter_at)
    refute Repo.get_by(OutboxEntry, outbound_key: "ai-dead-letter:#{event.id}")
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "a non-retryable turn error stays inside the Workflow call attempt budget" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    now = DateTime.add(event.available_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = envelope |> turn_start_payload!() |> Map.fetch!(:turn)

    reason =
      turn_error_reason(
        "workflow_worker_rejected",
        "The Workflow Worker rejected the turn.",
        %{}
      )

    assert {:ok,
            %{
              status: :turn_failed,
              dead_lettered?: false,
              turn_error_compensation: %{call: %AgentCall{status: "queued", attempts: 1}}
            }} =
             ActorRuntime.handle_turn_error(domain_turn_ref(turn_ref), reason,
               now: DateTime.add(now, 1, :second)
             )

    assert %ActorEvent{input_state: "open", dead_letter_at: nil, completed_at: nil} =
             Repo.get!(ActorEvent, event.id)

    refute Repo.get_by(OutboxEntry, outbound_key: "ai-dead-letter:#{event.id}")
  end

  test "a mailbox message defers around an unstarted or running task and wakes only its sleeper" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{run: run, calls: [first, second], events: dispatch_events} =
      workflow_fixture(agent.uid,
        arguments: [
          %{"prompt" => "Sleep and wait for mail."},
          %{"prompt" => "Sleep and stay asleep."}
        ]
      )

    assert {:ok, _sent} =
             Workflow.send_task_message(run.id, 0, agent.uid, "Early mail.", "tool-early")

    message_event =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{first.id}:msg:tool-early"
      )

    actor_key = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(first.id)}

    # Before the dispatch claim, the message keeps its mailbox meaning: it
    # defers instead of claiming or completing.
    now = DateTime.add(message_event.available_at, 1, :second)

    assert {:ok, %{status: :waiting_for_worker, reason: :task_not_started}} =
             WorkflowTaskDispatch.process(actor_key, message_event, now: now)

    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, first.id)

    # A running task keeps its turn: the message waits for the turn to end.
    assert {:ok, _claimed} = Workflow.claim_task_in_tx(Repo, first.id, agent.uid, 8)
    now = DateTime.add(now, 31, :second)

    assert {:ok, %{status: :waiting_for_worker, reason: :task_running}} =
             WorkflowTaskDispatch.process(actor_key, Repo.reload(message_event), now: now)

    # Park both tasks sleeping and close their dispatch events, as a finished
    # first turn would.
    assert {:ok, _claimed} = Workflow.claim_task_in_tx(Repo, second.id, agent.uid, 8)

    for call <- [first, second] do
      assert {:ok, _sleeping} =
               Workflow.sleep_task(call.id, agent.uid, Workflow.task_session_id(call.id), %{
                 wake_after_ms: 3_600_000,
                 note: "Waiting for mail.",
                 attention: false
               })
    end

    for event <- dispatch_events do
      event
      |> Ecto.Changeset.change(%{completed_at: DateTime.utc_now(:microsecond)})
      |> Repo.update!()
    end

    # The redelivered message wakes exactly its own task. The sibling sleeper
    # keeps its state and its wake deadline.
    message_event = Repo.reload(message_event)
    now = DateTime.add(message_event.available_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)
    context = decoded_request_context(turn_start)

    assert turn_start.turn.actor.session_id == actor_key.session_id
    assert context["call_id"] == first.id
    assert context["run_id"] == run.id
    refute Map.has_key?(context, "turn_mode")
    refute Map.has_key?(context, "wake_count")
    refute Map.has_key?(context, "sleep_note")

    assert %AgentCall{status: "running", wake_count: 1} = Repo.get!(AgentCall, first.id)
    assert %AgentCall{status: "sleeping", wake_count: 1} = Repo.get!(AgentCall, second.id)

    assert Workflow.counts(Repo, run.id) |> Map.take(["running", "sleeping"]) ==
             %{"running" => 1, "sleeping" => 1}
  end

  test "dispatch rejects an invalid task session and hides another Agent's task" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)

    assert {:error, :workflow_task_not_found} =
             WorkflowTaskDispatch.process(
               %{agent_uid: other_agent.uid, session_id: event.session_id},
               event,
               []
             )

    assert {:error, :workflow_task_session_mismatch} =
             WorkflowTaskDispatch.process(
               %{agent_uid: agent.uid, session_id: "wf_task:9007199254740991"},
               event,
               []
             )

    assert {:error, :invalid_workflow_task_session} =
             WorkflowTaskDispatch.process(
               %{agent_uid: agent.uid, session_id: "wf_task:invalid"},
               %{event | session_id: "wf_task:invalid"},
               []
             )

    assert Repo.get!(AgentCall, call.id).status == "queued"
  end

  defp workflow_fixture(agent_uid, opts \\ []) do
    suffix = Integer.to_string(System.unique_integer([:positive]))

    run =
      Repo.insert!(
        Run.creation_changeset(%Run{}, %{
          agent_uid: agent_uid,
          owner_session_id: "workflow-owner-#{suffix}",
          reply_route: %{"binding_name" => "bot"},
          source_tool_call_id: "workflow-tool-#{suffix}",
          title: "Workflow #{suffix}",
          script: "return await agent('Run the task.');",
          args: %{},
          status: "running",
          concurrency: Keyword.get(opts, :concurrency, 8),
          max_agent_calls: 256,
          model_profile: Keyword.get(opts, :model_profile),
          error: %{}
        })
      )

    arguments =
      Keyword.get(opts, :arguments, [
        %{"prompt" => "Run Workflow task #{suffix}."}
      ])

    pending_calls =
      Enum.map(arguments, fn call_arguments ->
        %{namespace: nil, name: "agent", arguments: call_arguments}
      end)

    assert {:ok, %{new_calls: calls}} =
             Workflow.commit_replay_pending(run.id, pending_calls, 0)

    events =
      Enum.map(calls, fn call ->
        Repo.get_by!(ActorEvent,
          agent_uid: agent_uid,
          source_event_id: "workflow:call:#{call.id}:dispatch"
        )
      end)

    %{run: run, calls: calls, events: events}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
