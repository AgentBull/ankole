defmodule Ankole.SignalsGateway.ActorRuntime.WorkerSubagentConfigTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.SubagentDelegations.Config

  test "Deep Research policy is complete, scoped, and strictly validated" do
    agent_uid = "deep-research-policy-#{System.unique_integer([:positive])}"
    definition = Config.definition()
    assert :ok = Config.ensure_registered()
    on_exit(fn -> AppConfigure.delete_for_agent(agent_uid, definition) end)

    assert {:ok, defaults} = AppConfigure.get(definition, agent_id: agent_uid)

    assert defaults == %{
             "wallclock_budget" => 7_200_000,
             "submission_grace" => 600_000,
             "retention_days" => 30
           }

    assert {:error, {:invalid_deep_research_keys, ["retention_days"]}} =
             AppConfigure.put_for_agent(
               agent_uid,
               definition,
               Map.delete(defaults, "retention_days")
             )

    assert {:error, {:invalid_deep_research_value, "submission_grace", %{min: 0, max: 3_600_000}}} =
             AppConfigure.put_for_agent(
               agent_uid,
               definition,
               Map.put(defaults, "submission_grace", 3_600_001)
             )

    override = %{defaults | "retention_days" => 45}
    assert {:ok, ^override} = AppConfigure.put_for_agent(agent_uid, definition, override)
    assert {:ok, ^override} = AppConfigure.get(definition, agent_id: agent_uid)
  end
end
