defmodule Ankole.SignalsGateway.ActorRuntime.RPCWireTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  test "projects one library Skill into the shared RuntimeFabric summary" do
    summary =
      RPCWire.runtime_skill_summary(%{
        "skill_name" => "bullx-financial-data",
        "description" => "Use BullX financial data.",
        "default_enabled" => true,
        "source_kind" => "builtin",
        "relative_path" => "bullx-financial-data",
        "skill_root" => "internal",
        "metadata" => %{"ankole-runtime" => "any"},
        "category" => "data",
        "tags" => ["finance", "mcp"],
        "skill_uri" => "skill://internal/bullx-financial-data",
        "has_agent_overlay" => false
      })

    assert summary.skill_name == "bullx-financial-data"
    assert summary.description == "Use BullX financial data."
    assert summary.default_enabled
    assert summary.source_kind == "builtin"
    assert summary.relative_path == "bullx-financial-data"
    assert summary.skill_root == "internal"
    assert Torque.decode!(summary.metadata_json) == %{"ankole-runtime" => "any"}
    assert summary.category == "data"
    assert Torque.decode!(summary.tags_json) == ["finance", "mcp"]
    assert summary.skill_uri == "skill://internal/bullx-financial-data"
    refute summary.has_agent_overlay
  end
end
