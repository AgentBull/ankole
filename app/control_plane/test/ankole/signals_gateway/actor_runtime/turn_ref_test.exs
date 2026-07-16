defmodule Ankole.SignalsGateway.ActorRuntime.TurnRefTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @actor_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"

  test "from_wire normalizes string-keyed turn refs" do
    assert {:ok, turn_ref} =
             TurnRef.from_wire(%{
               "actor" => %{
                 "agent_uid" => " Agent-A ",
                 "session_id" => " session-1 "
               },
               "activation_uid" => " activation-1 ",
               "actor_epoch" => "3",
               "actor_event_id" => " #{@actor_event_id} ",
               "revision" => "2"
             })

    assert turn_ref.agent_uid == "agent-a"
    assert turn_ref.session_id == "session-1"
    assert turn_ref.activation_uid == "activation-1"
    assert turn_ref.actor_epoch == 3
    assert turn_ref.actor_event_id == @actor_event_id
    assert turn_ref.revision == 2
  end

  test "from_wire accepts atom-keyed turn refs" do
    assert {:ok, turn_ref} =
             TurnRef.from_wire(%{
               actor: %{
                 agent_uid: "Agent-B",
                 session_id: "session-2"
               },
               activation_uid: "activation-2",
               actor_epoch: 4,
               actor_event_id: @actor_event_id,
               revision: 0
             })

    assert turn_ref.agent_uid == "agent-b"
    assert turn_ref.session_id == "session-2"
    assert turn_ref.activation_uid == "activation-2"
    assert turn_ref.actor_epoch == 4
    assert turn_ref.actor_event_id == @actor_event_id
    assert turn_ref.revision == 0
  end

  test "from_request reads the turn payload key only" do
    wire = wire_turn_ref()

    assert {:ok, %TurnRef{}} = TurnRef.from_request(%{"turn" => wire})
    assert {:error, :missing_turn_ref} = TurnRef.from_request(%{"turn_ref" => wire})
  end

  test "invalid turn refs fail" do
    wire = wire_turn_ref()

    invalid_refs = [
      put_in(wire, ["actor", "agent_uid"], " "),
      Map.delete(wire, "actor"),
      Map.delete(wire, "revision"),
      Map.put(wire, "actor_epoch", "3x"),
      Map.put(wire, "revision", -1)
    ]

    for invalid_ref <- invalid_refs do
      assert {:error, :invalid_turn_ref} = TurnRef.from_wire(invalid_ref)
    end
  end

  test "to_wire emits the current ActorTurnRef shape" do
    assert {:ok, turn_ref} = TurnRef.from_wire(wire_turn_ref())

    wire = TurnRef.to_wire(turn_ref)

    assert wire["actor_event_id"] == @actor_event_id
  end

  test "actor_key returns normalized actor identity" do
    assert {:ok, turn_ref} = TurnRef.from_wire(wire_turn_ref())

    assert TurnRef.actor_key(turn_ref) == %{agent_uid: "agent-a", session_id: "session-1"}
  end

  test "from_activation and from_delivery produce wire-compatible refs" do
    activation = %ActorSessionActivation{
      activation_uid: "activation-3",
      actor_epoch: 5,
      current_actor_event_id: @actor_event_id,
      revision: 7
    }

    activation_ref =
      TurnRef.from_activation(%{agent_uid: " Agent-C ", session_id: "session-3"}, activation)

    assert activation_ref.agent_uid == "agent-c"
    assert {:ok, ^activation_ref} = activation_ref |> TurnRef.to_wire() |> TurnRef.from_wire()
    assert {:error, :invalid_turn_ref} = TurnRef.from_wire(activation_ref)

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
    assert {:ok, ^delivery_ref} = delivery_ref |> TurnRef.to_wire() |> TurnRef.from_wire()
    assert {:error, :invalid_turn_ref} = TurnRef.from_wire(delivery_ref)
  end

  defp wire_turn_ref do
    %{
      "actor" => %{
        "agent_uid" => " Agent-A ",
        "session_id" => "session-1"
      },
      "activation_uid" => "activation-1",
      "actor_epoch" => 3,
      "actor_event_id" => @actor_event_id,
      "revision" => 2
    }
  end
end
