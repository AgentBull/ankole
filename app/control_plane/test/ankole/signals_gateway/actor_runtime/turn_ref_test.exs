defmodule Ankole.SignalsGateway.ActorRuntime.TurnRefTest do
  use ExUnit.Case, async: true

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @actor_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"

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
