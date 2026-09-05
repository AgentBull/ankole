defmodule Ankole.SignalsGateway.ActorRuntime.TurnRefTest do
  use ExUnit.Case, async: true

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @actor_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"
  @steer_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d6"
  @other_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d7"
  @now ~U[2026-07-02 01:34:05.000000Z]
  @worker_id "worker-1"

  describe "match/4" do
    test "decides every mode from the rows, the fence, and the mode alone" do
      for {label, mode, overrides, expected} <- match_table() do
        assert TurnRef.match(rows(overrides), fence(), mode, now: @now) == expected, label
      end
    end

    test "abort and complete need the deliveries to be loaded" do
      for mode <- [:abort, :complete] do
        assert_raise ArgumentError, ~r/needs rows\.deliveries/, fn ->
          TurnRef.match(rows(%{deliveries: nil}), fence(), mode, now: @now)
        end
      end
    end
  end

  defp match_table do
    not_found = {:error, :actor_runtime_fence_not_found}
    not_assigned = {:error, :worker_not_assigned_to_turn}
    expired = DateTime.add(@now, -1, :second)

    [
      # progress: live, lease-alive, full fence, revision at or above the worker's
      {"progress accepts the matching fence", :progress, %{}, :ok},
      {"progress accepts a newer pending revision", :progress,
       %{activation: activation(revision: 3)}, :ok},
      {"progress rejects a missing activation", :progress, %{activation: nil}, not_found},
      {"progress rejects a dead activation", :progress,
       %{activation: activation(status: "stopped")}, {:error, :activation_not_live}},
      {"progress rejects a lease that ends at now", :progress,
       %{activation: activation(lease_expires_at: @now)}, {:error, :activation_lease_expired}},
      {"progress checks status before the lease", :progress,
       %{activation: activation(status: "failed", lease_expires_at: expired)},
       {:error, :activation_not_live}},
      {"progress checks the lease before the fence fields", :progress,
       %{activation: activation(lease_expires_at: expired, actor_epoch: 4)},
       {:error, :activation_lease_expired}},
      {"progress rejects another agent", :progress,
       %{activation: activation(agent_uid: "agent-b")}, {:error, :stale_actor_key}},
      {"progress rejects another session", :progress,
       %{activation: activation(session_id: "session-2")}, {:error, :stale_actor_key}},
      {"progress rejects another activation", :progress,
       %{activation: activation(activation_uid: "activation-2")},
       {:error, :stale_activation_uid}},
      {"progress rejects another epoch", :progress, %{activation: activation(actor_epoch: 4)},
       {:error, :stale_actor_epoch}},
      {"progress rejects a worker revision above the activation", :progress,
       %{activation: activation(revision: 1)}, {:error, :stale_revision}},
      {"progress rejects another current event", :progress,
       %{activation: activation(current_actor_event_id: @other_event_id)},
       {:error, :stale_actor_event_id}},

      # abort: full fence without status or lease, then every live delivery
      {"abort accepts the matching fence", :abort, %{}, :ok},
      {"abort accepts a dead activation with an ended lease", :abort,
       %{activation: activation(status: "stopped", lease_expires_at: expired)}, :ok},
      {"abort accepts a newer pending revision", :abort, %{activation: activation(revision: 3)},
       :ok},
      {"abort rejects a missing activation", :abort, %{activation: nil}, not_found},
      {"abort rejects another agent", :abort, %{activation: activation(agent_uid: "agent-b")},
       {:error, :stale_actor_key}},
      {"abort rejects another session", :abort,
       %{activation: activation(session_id: "session-2")}, {:error, :stale_actor_key}},
      {"abort rejects another activation", :abort,
       %{activation: activation(activation_uid: "activation-2")},
       {:error, :stale_activation_uid}},
      {"abort rejects another epoch", :abort, %{activation: activation(actor_epoch: 4)},
       {:error, :stale_actor_epoch}},
      {"abort rejects a worker revision above the activation", :abort,
       %{activation: activation(revision: 1)}, {:error, :stale_revision}},
      {"abort rejects another current event", :abort,
       %{activation: activation(current_actor_event_id: @other_event_id)},
       {:error, :stale_actor_event_id}},
      {"abort rejects a turn without live deliveries", :abort, %{deliveries: []}, not_found},
      {"abort rejects a delivery of another agent", :abort,
       %{deliveries: [delivery(agent_uid: "agent-b")]}, {:error, :stale_actor_key}},
      {"abort rejects a delivery of another session", :abort,
       %{deliveries: [delivery(session_id: "session-2")]}, {:error, :stale_actor_key}},
      {"abort rejects a delivery of another activation", :abort,
       %{deliveries: [delivery(activation_uid: "activation-2")]},
       {:error, :stale_activation_uid}},
      {"abort rejects a delivery of another epoch", :abort,
       %{deliveries: [delivery(actor_epoch: 4)]}, {:error, :stale_actor_epoch}},
      {"abort rejects a delivery under another event fence", :abort,
       %{deliveries: [delivery(actor_event_id_fence: @other_event_id)]},
       {:error, :stale_actor_event_id}},
      {"abort finds the mismatch in any position", :abort,
       %{deliveries: [delivery(), delivery(actor_epoch: 4)]}, {:error, :stale_actor_epoch}},
      {"abort ignores the delivery revision", :abort,
       %{deliveries: [delivery(), delivery(actor_event_id: @steer_event_id, revision: 9)]}, :ok},
      {"abort does not need a received main delivery", :abort,
       %{deliveries: [delivery(state: "created")]}, :ok},

      # complete: like progress on the activation, then deliveries plus the received main delivery
      {"complete accepts the matching fence", :complete, %{}, :ok},
      {"complete accepts a newer pending revision", :complete,
       %{activation: activation(revision: 3)}, :ok},
      {"complete accepts an accepted main delivery", :complete,
       %{deliveries: [delivery(state: "accepted")]}, :ok},
      {"complete needs only the main delivery received", :complete,
       %{deliveries: [delivery(), delivery(actor_event_id: @steer_event_id, state: "created")]},
       :ok},
      {"complete relies on lookup for the activation identity", :complete,
       %{activation: activation(agent_uid: "agent-b", activation_uid: "activation-2")}, :ok},
      {"complete rejects a missing activation", :complete, %{activation: nil}, not_found},
      {"complete rejects a dead activation", :complete,
       %{activation: activation(status: "failed")}, {:error, :activation_not_live}},
      {"complete rejects a lease that ends at now", :complete,
       %{activation: activation(lease_expires_at: @now)}, {:error, :activation_lease_expired}},
      {"complete rejects another epoch", :complete, %{activation: activation(actor_epoch: 4)},
       {:error, :stale_actor_epoch}},
      {"complete rejects a worker revision above the activation", :complete,
       %{activation: activation(revision: 1)}, {:error, :stale_revision}},
      {"complete rejects another current event", :complete,
       %{activation: activation(current_actor_event_id: @other_event_id)},
       {:error, :stale_actor_event_id}},
      {"complete rejects a turn without live deliveries", :complete, %{deliveries: []},
       not_found},
      {"complete rejects a delivery of another agent", :complete,
       %{deliveries: [delivery(agent_uid: "agent-b")]}, {:error, :stale_actor_key}},
      {"complete rejects a delivery of another session", :complete,
       %{deliveries: [delivery(session_id: "session-2")]}, {:error, :stale_actor_key}},
      {"complete rejects a delivery of another activation", :complete,
       %{deliveries: [delivery(activation_uid: "activation-2")]},
       {:error, :stale_activation_uid}},
      {"complete rejects a delivery of another epoch", :complete,
       %{deliveries: [delivery(actor_epoch: 4)]}, {:error, :stale_actor_epoch}},
      {"complete rejects a delivery under another event fence", :complete,
       %{deliveries: [delivery(actor_event_id_fence: @other_event_id)]},
       {:error, :stale_actor_event_id}},
      {"complete checks the delivery fence before the main delivery state", :complete,
       %{deliveries: [delivery(state: "created", actor_epoch: 4)]}, {:error, :stale_actor_epoch}},
      {"complete rejects a main delivery the worker never received", :complete,
       %{deliveries: [delivery(state: "created")]}, {:error, :main_delivery_not_received}},
      {"complete rejects live deliveries without the main event", :complete,
       %{deliveries: [delivery(actor_event_id: @steer_event_id)]},
       {:error, :main_delivery_not_received}},

      # route_read / route_write: worker, live activation, live assignment; write also revision
      {"route_read accepts the matching fence", :route_read, %{}, :ok},
      {"route_write accepts the matching fence", :route_write, %{}, :ok},
      {"route_read accepts a newer pending revision", :route_read,
       %{activation: activation(revision: 3)}, :ok},
      {"route_write accepts a newer pending revision", :route_write,
       %{activation: activation(revision: 3)}, :ok},
      {"route_read accepts a worker revision above the activation", :route_read,
       %{activation: activation(revision: 1)}, :ok},
      {"route_write rejects a worker revision above the activation", :route_write,
       %{activation: activation(revision: 1)}, {:error, :stale_revision}},
      {"route_read ignores the lease", :route_read,
       %{activation: activation(lease_expires_at: expired)}, :ok},
      {"route_write ignores the lease", :route_write,
       %{activation: activation(lease_expires_at: expired)}, :ok},
      {"route_read rejects a missing worker", :route_read, %{worker: nil}, not_assigned},
      {"route_write rejects a missing worker", :route_write, %{worker: nil}, not_assigned},
      {"route_read rejects a missing activation", :route_read, %{activation: nil}, not_assigned},
      {"route_write rejects a missing activation", :route_write, %{activation: nil},
       not_assigned},
      {"route_read rejects another epoch", :route_read, %{activation: activation(actor_epoch: 4)},
       not_assigned},
      {"route_write rejects another epoch", :route_write,
       %{activation: activation(actor_epoch: 4)}, not_assigned},
      {"route_read rejects another current event", :route_read,
       %{activation: activation(current_actor_event_id: @other_event_id)}, not_assigned},
      {"route_write rejects another current event", :route_write,
       %{activation: activation(current_actor_event_id: @other_event_id)}, not_assigned},
      {"route_read rejects a dead activation", :route_read,
       %{activation: activation(status: "failed")}, not_assigned},
      {"route_write rejects a dead activation", :route_write,
       %{activation: activation(status: "failed")}, not_assigned},
      {"route_read rejects a missing assignment", :route_read, %{assignment: nil}, not_assigned},
      {"route_write rejects a missing assignment", :route_write, %{assignment: nil},
       not_assigned},
      {"route_write checks the assignment before the revision", :route_write,
       %{assignment: nil, activation: activation(revision: 1)}, not_assigned},
      {"route_write relies on lookup for the activation identity", :route_write,
       %{activation: activation(agent_uid: "agent-b", activation_uid: "activation-2")}, :ok},

      # terminal_retry: static fence with revision >= on a finished or failed activation
      {"terminal_retry accepts a finished activation with a newer revision", :terminal_retry,
       %{activation: activation(current_actor_event_id: nil, revision: 3)}, :ok},
      {"terminal_retry accepts a draining activation", :terminal_retry,
       %{activation: activation(status: "draining", current_actor_event_id: nil)}, :ok},
      {"terminal_retry accepts a failed activation", :terminal_retry,
       %{activation: activation(status: "failed", current_actor_event_id: nil)}, :ok},
      {"terminal_retry ignores the lease and the assignment", :terminal_retry,
       %{activation: activation(lease_expires_at: expired), assignment: nil}, :ok},
      {"terminal_retry rejects a stopped activation", :terminal_retry,
       %{activation: activation(status: "stopped")}, not_assigned},
      {"terminal_retry rejects a starting activation", :terminal_retry,
       %{activation: activation(status: "starting")}, not_assigned},
      {"terminal_retry rejects a missing worker", :terminal_retry, %{worker: nil}, not_assigned},
      {"terminal_retry rejects a missing activation", :terminal_retry, %{activation: nil},
       not_assigned},
      {"terminal_retry rejects another epoch", :terminal_retry,
       %{activation: activation(actor_epoch: 4)}, not_assigned},
      {"terminal_retry rejects a worker revision above the activation", :terminal_retry,
       %{activation: activation(revision: 1)}, not_assigned}
    ]
  end

  defp fence do
    %TurnRef{
      agent_uid: "agent-a",
      session_id: "session-1",
      activation_uid: "activation-1",
      actor_epoch: 3,
      actor_event_id: @actor_event_id,
      revision: 2
    }
  end

  defp rows(overrides) do
    Map.merge(
      %{
        worker: worker(),
        activation: activation(),
        assignment: assignment(),
        deliveries: [delivery()]
      },
      overrides
    )
  end

  defp activation(overrides \\ []) do
    struct!(
      %ActorSessionActivation{
        agent_uid: "agent-a",
        session_id: "session-1",
        activation_uid: "activation-1",
        actor_epoch: 3,
        current_actor_event_id: @actor_event_id,
        revision: 2,
        status: "active",
        lease_expires_at: DateTime.add(@now, 60, :second),
        assigned_worker_id: @worker_id
      },
      overrides
    )
  end

  defp delivery(overrides \\ []) do
    struct!(
      %ActorEventDelivery{
        actor_event_id: @actor_event_id,
        agent_uid: "agent-a",
        session_id: "session-1",
        activation_uid: "activation-1",
        actor_epoch: 3,
        actor_event_id_fence: @actor_event_id,
        revision: 0,
        state: "sent"
      },
      overrides
    )
  end

  defp worker do
    %AgentComputerWorker{worker_id: @worker_id, status: "ready", transport_route: "route-1"}
  end

  defp assignment do
    %ActorSessionWorkerAssignment{
      agent_uid: "agent-a",
      session_id: "session-1",
      worker_id: @worker_id,
      status: "assigned"
    }
  end

  test "from_proto normalizes the generated fence" do
    assert {:ok, turn_ref} =
             TurnRef.from_proto(%FabricProto.ActorTurnRef{
               actor: %FabricProto.ActorKey{
                 agent_uid: " Agent-A ",
                 session_id: " session-1 "
               },
               activation_uid: " activation-1 ",
               actor_epoch: 3,
               actor_event_id: " #{@actor_event_id} ",
               revision: 2
             })

    assert turn_ref.agent_uid == "agent-a"
    assert turn_ref.session_id == "session-1"
    assert turn_ref.activation_uid == "activation-1"
    assert turn_ref.actor_epoch == 3
    assert turn_ref.actor_event_id == @actor_event_id
    assert turn_ref.revision == 2
  end

  test "invalid turn refs fail" do
    proto = proto_turn_ref()

    invalid_refs = [
      %{proto | actor: %{proto.actor | agent_uid: " "}},
      %{proto | actor: nil},
      %{proto | actor_epoch: 0},
      %{proto | activation_uid: ""},
      %{proto | revision: -1},
      nil
    ]

    for invalid_ref <- invalid_refs do
      assert {:error, :invalid_turn_ref} = TurnRef.from_proto(invalid_ref)
    end
  end

  test "to_proto round-trips through from_proto" do
    assert {:ok, turn_ref} = TurnRef.from_proto(proto_turn_ref())

    assert {:ok, ^turn_ref} = turn_ref |> TurnRef.to_proto() |> TurnRef.from_proto()
    assert TurnRef.to_proto(turn_ref).actor_event_id == @actor_event_id
  end

  test "actor_key returns normalized actor identity" do
    assert {:ok, turn_ref} = TurnRef.from_proto(proto_turn_ref())

    assert TurnRef.actor_key(turn_ref) == %{agent_uid: "agent-a", session_id: "session-1"}
  end

  test "from_activation and from_delivery produce proto-compatible refs" do
    activation = %ActorSessionActivation{
      activation_uid: "activation-3",
      actor_epoch: 5,
      current_actor_event_id: @actor_event_id,
      revision: 7
    }

    activation_ref =
      TurnRef.from_activation(%{agent_uid: " Agent-C ", session_id: "session-3"}, activation)

    assert activation_ref.agent_uid == "agent-c"
    assert {:ok, ^activation_ref} = activation_ref |> TurnRef.to_proto() |> TurnRef.from_proto()

    delivery = %ActorEventDelivery{
      agent_uid: " Agent-D ",
      session_id: "session-4",
      activation_uid: "activation-4",
      actor_epoch: 6,
      actor_event_id_fence: @actor_event_id,
      revision: 8
    }

    delivery_ref = TurnRef.from_delivery(delivery)

    assert delivery_ref.agent_uid == "agent-d"
    assert {:ok, ^delivery_ref} = delivery_ref |> TurnRef.to_proto() |> TurnRef.from_proto()
  end

  defp proto_turn_ref do
    %FabricProto.ActorTurnRef{
      actor: %FabricProto.ActorKey{
        agent_uid: " Agent-A ",
        session_id: "session-1"
      },
      activation_uid: "activation-1",
      actor_epoch: 3,
      actor_event_id: @actor_event_id,
      revision: 2
    }
  end
end
