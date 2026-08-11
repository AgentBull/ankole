defmodule Ankole.SignalsGateway.ActorRuntime.WorkerTakeoverTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.Channel

  # Replacing a worker releases the fences its predecessor held, and an old turn
  # that cannot be replayed is dead-lettered in that same transaction. The
  # dead-letter notice is a provider-visible intent, so its route can be gone by
  # then. Takeover must not depend on that route: one unreachable old event
  # would otherwise keep every later incarnation stale, and every Agent and Job
  # on that worker with it.
  describe "worker takeover past an unroutable old turn" do
    test "replacement incarnation takes over when the old turn's adapter is gone" do
      %{agent: agent, route: route, input: input} = start_unreplayable_turn()

      binding_fixture(agent.uid, "bot", :ignore, adapter: "missing-adapter")

      assert {:ok, replacement} = admit_worker(route, %{incarnation_id: "incarnation-2"})
      assert replacement.incarnation_id == "incarnation-2"
      assert replacement.status == "ready"

      assert Repo.get!(ActorEvent, input.id).input_state == "dead_letter"

      # The user-visible intent is still committed. It waits in the outbox until
      # the adapter is registered again instead of being lost.
      notice = Repo.get_by!(OutboxEntry, outbound_key: "ai-dead-letter:#{input.id}")
      assert notice.status == :created

      assert {:ok, _worker} = heartbeat(replacement, route)
    end

    test "replacement incarnation takes over when the old channel takes no replies" do
      %{route: route, input: input} = start_unreplayable_turn()

      listen_only_channel!(input.signal_channel_id)

      assert {:ok, replacement} = admit_worker(route, %{incarnation_id: "incarnation-2"})
      assert replacement.incarnation_id == "incarnation-2"

      # A channel that never accepts replies has nowhere to put the notice, so
      # the dead-lettered event row is the whole record of the failure. Nothing
      # claims the notice was delivered.
      dead_lettered = Repo.get!(ActorEvent, input.id)
      assert dead_lettered.input_state == "dead_letter"
      assert %DateTime{} = dead_lettered.dead_letter_at
      refute Repo.get_by(OutboxEntry, outbound_key: "ai-dead-letter:#{input.id}")

      assert {:ok, _worker} = heartbeat(replacement, route)
    end
  end

  defp start_unreplayable_turn do
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

    assert {:ok, %{turn_ref: turn_ref}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert turn_ref.actor_event_id == input.id
    assert_receive {:actor_lane, _envelope}

    # An executed tool call cannot be replayed, so losing this worker has to
    # dead-letter the event rather than run the same effect twice.
    complete_aigateway_turn!(turn_ref, "",
      output_items: [
        %{
          "type" => "function_call",
          "name" => "command",
          "call_id" => "call-1",
          "arguments" => "{}"
        }
      ]
    )

    %{agent: agent, route: route, input: input, turn_ref: turn_ref}
  end

  defp listen_only_channel!(signal_channel_id) do
    Channel
    |> Repo.get!(signal_channel_id)
    |> Channel.changeset(%{reply_mode: :none})
    |> Repo.update!()
  end

  defp heartbeat(worker, route) do
    ActorRuntime.handle_worker_heartbeat(
      worker_heartbeat_payload(worker),
      %{authenticated?: true, transport_route: route}
    )
  end
end
