defmodule Ankole.SignalsGateway.ActorRuntime.RPCWireTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  test "projects one library Skill into the shared RuntimeFabric summary" do
    summary =
      RPCWire.runtime_skill_summary(%{
        "skill_name" => "bullx-financial-data",
        "description" => "Use BullX financial data.",
        "source_kind" => "builtin",
        "relative_path" => "bullx-financial-data",
        "skill_root" => "internal",
        "metadata" => %{"ankole-runtime" => "any", "brain_recall_only" => true},
        "category" => "data"
      })

    assert summary.skill_name == "bullx-financial-data"
    assert summary.description == "Use BullX financial data."
    assert summary.source_kind == "builtin"
    assert summary.relative_path == "bullx-financial-data"
    assert summary.skill_root == "internal"

    assert Torque.decode!(summary.metadata_json) == %{
             "ankole-runtime" => "any",
             "brain_recall_only" => true
           }

    assert summary.category == "data"
  end
end
