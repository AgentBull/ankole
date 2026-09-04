defmodule Ankole.SignalsGateway.ActorRuntime.TurnFenceTest do
  @moduledoc """
  One table per fence site. Each site receives the same live turn with one
  fence field changed at a time, then a dead activation, then an expired lease.
  A rejection leaves the turn untouched, so one turn serves every rejection of
  a site and only the last case of a site changes persisted state.
  """

  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth

  @other_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"

  describe "worker progress (progress)" do
    test "rejects each fence mismatch, a dead activation, and an expired lease before renewing" do
      %{input: input, turn_ref: turn_ref} = start_live_turn()
      now = DateTime.utc_now(:microsecond)
      test_process = self()

      # A rejected progress message forwards nothing to the reply preview.
      progress = fn ref ->
        ActorRuntime.handle_worker_progress(
          worker_progress_payload(ref, "reply_presentation",
            refs: %{"presentation_event" => %{"kind" => "tool.activity", "payload" => %{}}}
          ),
          now: now,
          presentation_event_fun: fn actor_event_id, event ->
            send(test_process, {:reply_presentation_event, actor_event_id, event})
          end
        )
      end

      assert_rejections(progress, turn_ref,
        agent_uid: :actor_runtime_fence_not_found,
        session_id: :actor_runtime_fence_not_found,
        activation_uid: :actor_runtime_fence_not_found,
        actor_epoch: :stale_actor_epoch,
        actor_event_id: :stale_actor_event_id,
        revision: :stale_revision
      )

      set_activation!(turn_ref, status: "failed")
      assert {:error, :activation_not_live} = progress.(turn_ref)
      set_activation!(turn_ref, status: "active")

      set_activation!(turn_ref, lease_expires_at: expired_lease())
      assert {:error, :activation_lease_expired} = progress.(turn_ref)
      set_activation!(turn_ref, lease_expires_at: alive_lease())

      assert_turn_untouched(input, turn_ref)
      refute_received {:reply_presentation_event, _actor_event_id, _event}

      assert {:ok, %ActorSessionActivation{} = activation} = progress.(turn_ref)

      assert DateTime.compare(activation.lease_expires_at, DateTime.add(now, 2_099, :second)) ==
               :gt

      input_id = input.id
      assert_received {:reply_presentation_event, ^input_id, %{"kind" => "tool.activity"}}
    end
  end

  describe "turn abort (abort)" do
    test "rejects each fence mismatch but accepts an expired lease" do
      %{input: input, turn_ref: turn_ref} = start_live_turn()
      abort = &fail_retryable/1

      assert_rejections(abort, turn_ref,
        agent_uid: :actor_runtime_fence_not_found,
        session_id: :actor_runtime_fence_not_found,
        activation_uid: :actor_runtime_fence_not_found,
        actor_epoch: :stale_actor_epoch,
        actor_event_id: :actor_runtime_fence_not_found,
        revision: :stale_revision
      )

      assert_turn_untouched(input, turn_ref)

      set_activation!(turn_ref, lease_expires_at: expired_lease())
      assert {:ok, %{status: :turn_failed, superseded_deliveries: 1}} = abort.(turn_ref)

      assert %ActorSessionActivation{status: "failed", current_actor_event_id: nil} =
               activation_row(turn_ref)

      assert ["superseded"] = delivery_states(turn_ref)
      assert is_nil(Repo.get!(ActorEvent, input.id).completed_at)
    end
  end

  describe "turn accepted (delivery selection)" do
    test "each fence mismatch finds no sent delivery; the exact fence accepts it" do
      %{turn_ref: turn_ref} = start_live_turn()
      accept = fn ref -> ActorRuntime.handle_turn_accepted(turn_accepted_payload(ref)) end

      assert_rejections(accept, turn_ref,
        agent_uid: :sent_delivery_not_found,
        session_id: :sent_delivery_not_found,
        activation_uid: :sent_delivery_not_found,
        actor_epoch: :sent_delivery_not_found,
        actor_event_id: :sent_delivery_not_found,
        revision: :sent_delivery_not_found
      )

      assert ["sent"] = delivery_states(turn_ref)
      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} = accept.(turn_ref)
    end
  end

  describe "turn completion (complete)" do
    test "rejects each fence mismatch, a dead activation, an expired lease, and an unsent main delivery" do
      %{input: input, turn_ref: turn_ref} = start_live_turn()
      complete = fn ref -> complete_turn_silent(ref) end

      assert_rejections(complete, turn_ref,
        agent_uid: :actor_runtime_fence_not_found,
        session_id: :actor_runtime_fence_not_found,
        activation_uid: :actor_runtime_fence_not_found,
        actor_epoch: :stale_actor_epoch,
        actor_event_id: :actor_runtime_fence_not_found,
        revision: :stale_revision
      )

      set_activation!(turn_ref, status: "failed")
      assert {:error, :activation_not_live} = complete.(turn_ref)
      set_activation!(turn_ref, status: "active")

      set_activation!(turn_ref, lease_expires_at: expired_lease())
      assert {:error, :activation_lease_expired} = complete.(turn_ref)
      set_activation!(turn_ref, lease_expires_at: alive_lease())

      set_deliveries!(turn_ref, state: "created")
      assert {:error, :main_delivery_not_received} = complete.(turn_ref)
      set_deliveries!(turn_ref, state: "sent")

      assert_turn_untouched(input, turn_ref)

      assert {:ok, %{status: :turn_completed}} = complete.(turn_ref)
      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
    end
  end

  describe "worker route authorization (route_read, route_write)" do
    test "rejects a foreign route, each static fence mismatch, a dead activation, and a released assignment" do
      %{turn_ref: turn_ref, route: route} = start_live_turn()

      for effect <- [:read, :write] do
        authorize = fn ref -> WorkerRouteAuth.authorize_turn_route(ref, route, effect) end

        assert {:error, :worker_not_assigned_to_turn} =
                 WorkerRouteAuth.authorize_turn_route(turn_ref, unique_route(), effect)

        assert_rejections(authorize, turn_ref,
          agent_uid: :worker_not_assigned_to_turn,
          session_id: :worker_not_assigned_to_turn,
          activation_uid: :worker_not_assigned_to_turn,
          actor_epoch: :worker_not_assigned_to_turn,
          actor_event_id: :worker_not_assigned_to_turn
        )

        set_activation!(turn_ref, status: "failed")
        assert {:error, :worker_not_assigned_to_turn} = authorize.(turn_ref)
        set_activation!(turn_ref, status: "active")

        set_assignment!(turn_ref, status: "released")
        assert {:error, :worker_not_assigned_to_turn} = authorize.(turn_ref)
        set_assignment!(turn_ref, status: "assigned")

        # Route authorization never reads the lease; the durable write fences do.
        set_activation!(turn_ref, lease_expires_at: expired_lease())
        assert :ok = authorize.(turn_ref)
        set_activation!(turn_ref, lease_expires_at: alive_lease())

        assert :ok = authorize.(turn_ref)
      end
    end

    test "a newer worker revision is readable but not writable" do
      %{turn_ref: turn_ref, route: route} = start_live_turn()
      newer = %{turn_ref | revision: turn_ref.revision + 1}

      assert :ok = WorkerRouteAuth.authorize_turn_route(newer, route, :read)

      assert {:error, :stale_revision} =
               WorkerRouteAuth.authorize_turn_route(newer, route, :write)

      # The assignment check precedes the revision rule.
      set_assignment!(turn_ref, status: "released")

      assert {:error, :worker_not_assigned_to_turn} =
               WorkerRouteAuth.authorize_turn_route(newer, route, :write)
    end
  end

  describe "terminal retry authorization (terminal_retry)" do
    test "a completed turn accepts its static fence with an older applied revision" do
      %{turn_ref: turn_ref, route: route} = start_live_turn()

      assert :ok = WorkerRouteAuth.authorize_turn_completion_route(turn_ref, route)
      assert {:ok, %{status: :turn_completed}} = complete_turn_silent(turn_ref)

      # The activation no longer names the event; only the terminal rule can pass.
      set_activation!(turn_ref, revision: turn_ref.revision + 2)
      assert :ok = WorkerRouteAuth.authorize_turn_completion_route(turn_ref, route)

      assert {:error, :worker_not_assigned_to_turn} =
               WorkerRouteAuth.authorize_turn_completion_route(turn_ref, unique_route())

      assert_rejections(
        &WorkerRouteAuth.authorize_turn_completion_route(&1, route),
        %{turn_ref | revision: turn_ref.revision + 2},
        agent_uid: :worker_not_assigned_to_turn,
        session_id: :worker_not_assigned_to_turn,
        activation_uid: :worker_not_assigned_to_turn,
        actor_epoch: :worker_not_assigned_to_turn,
        actor_event_id: :worker_not_assigned_to_turn,
        revision: :worker_not_assigned_to_turn
      )

      set_activation!(turn_ref, status: "stopped")

      assert {:error, :worker_not_assigned_to_turn} =
               WorkerRouteAuth.authorize_turn_completion_route(turn_ref, route)
    end

    test "an aborted turn accepts its static fence while the superseded delivery exists" do
      %{turn_ref: turn_ref, route: route} = start_live_turn()

      assert {:ok, %{status: :turn_failed}} = fail_retryable(turn_ref)

      assert :ok = WorkerRouteAuth.authorize_turn_completion_route(turn_ref, route)

      assert_rejections(
        &WorkerRouteAuth.authorize_turn_completion_route(&1, route),
        turn_ref,
        agent_uid: :worker_not_assigned_to_turn,
        session_id: :worker_not_assigned_to_turn,
        activation_uid: :worker_not_assigned_to_turn,
        actor_epoch: :worker_not_assigned_to_turn,
        actor_event_id: :worker_not_assigned_to_turn,
        revision: :worker_not_assigned_to_turn
      )

      set_activation!(turn_ref, status: "stopped")

      assert {:error, :worker_not_assigned_to_turn} =
               WorkerRouteAuth.authorize_turn_completion_route(turn_ref, route)
    end
  end

  describe "active steer" do
    test "an expired lease waits for generation instead of nudging the worker" do
      %{agent: agent, turn_ref: turn_ref} = start_live_turn()
      emit_steer(agent)
      set_activation!(turn_ref, lease_expires_at: DateTime.add(@base_time, 2, :second))

      assert {:ok, %{status: :waiting_for_generation, command: "command.steer"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      refute_receive {:actor_lane, _envelope}
      assert ["sent"] = delivery_states(turn_ref)
    end

    test "a completed current event turns the steer into its own generation" do
      %{agent: agent, input: input, turn_ref: turn_ref} = start_live_turn()
      steer_event = emit_steer(agent)

      Repo.update_all(
        from(event in ActorEvent, where: event.id == ^input.id),
        set: [completed_at: DateTime.add(@base_time, 2, :second)]
      )

      assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: %TurnRef{} = steer_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 3, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert steer_turn_ref.actor_event_id == steer_event.id
      assert steer_turn_ref.activation_uid == turn_ref.activation_uid
      assert_receive {:actor_lane, envelope}
      assert turn_start_payload!(envelope).turn.actor_event_id == steer_event.id
    end
  end

  defp start_live_turn do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()

    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "PING", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: %TurnRef{} = turn_ref}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    assert turn_start_payload!(envelope).turn.actor_event_id == input.id
    assert turn_ref.actor_event_id == input.id

    %{agent: agent, input: input, route: route, turn_ref: turn_ref}
  end

  # A retryable worker failure keeps the event open instead of dead-lettering it.
  defp fail_retryable(turn_ref) do
    fail_turn(turn_ref, "worker_loop_failed", "worker loop failed", %{"retryable" => true})
  end

  defp emit_steer(agent) do
    assert {:ok, %{actor_event: steer_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/steer change course", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    steer_event
  end

  # Applies one mutated fence field at a time and asserts the site's rejection.
  defp assert_rejections(site, %TurnRef{} = turn_ref, expected_by_field) do
    for {field, expected} <- expected_by_field do
      mutated = Map.put(turn_ref, field, mutated_value(turn_ref, field))
      assert {:error, ^expected} = site.(mutated), "fence field #{field}"
    end
  end

  defp mutated_value(_turn_ref, :agent_uid), do: "agent-someone-else"
  defp mutated_value(_turn_ref, :session_id), do: "session-someone-else"
  defp mutated_value(_turn_ref, :activation_uid), do: "activation-stale"
  defp mutated_value(turn_ref, :actor_epoch), do: turn_ref.actor_epoch + 1
  defp mutated_value(_turn_ref, :actor_event_id), do: @other_event_id
  defp mutated_value(turn_ref, :revision), do: turn_ref.revision + 1

  defp assert_turn_untouched(%ActorEvent{} = input, turn_ref) do
    assert is_nil(Repo.get!(ActorEvent, input.id).completed_at)
    assert Repo.get!(ActorEvent, input.id).input_state == "open"
    assert ["sent"] = delivery_states(turn_ref)

    assert %ActorSessionActivation{status: "active", current_actor_event_id: current} =
             activation_row(turn_ref)

    assert current == input.id
  end

  defp activation_row(turn_ref) do
    Repo.get_by!(ActorSessionActivation, activation_uid: turn_ref.activation_uid)
  end

  defp delivery_states(turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> order_by([delivery], asc: delivery.attempt_no)
    |> select([delivery], delivery.state)
    |> Repo.all()
  end

  defp set_activation!(turn_ref, set) do
    {1, _rows} =
      Repo.update_all(
        from(activation in ActorSessionActivation,
          where: activation.activation_uid == ^turn_ref.activation_uid
        ),
        set: set
      )

    :ok
  end

  defp set_deliveries!(turn_ref, set) do
    {count, _rows} =
      Repo.update_all(
        from(delivery in ActorEventDelivery,
          where: delivery.actor_event_id_fence == ^turn_ref.actor_event_id
        ),
        set: set
      )

    assert count >= 1
    :ok
  end

  defp set_assignment!(turn_ref, set) do
    {1, _rows} =
      Repo.update_all(
        from(assignment in ActorSessionWorkerAssignment,
          where: assignment.agent_uid == ^turn_ref.agent_uid,
          where: assignment.session_id == ^turn_ref.session_id
        ),
        set: set
      )

    :ok
  end

  defp expired_lease, do: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
  defp alive_lease, do: DateTime.add(DateTime.utc_now(:microsecond), 3_600, :second)
end
