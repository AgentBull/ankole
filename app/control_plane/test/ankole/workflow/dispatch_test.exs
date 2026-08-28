defmodule Ankole.Workflow.CreationTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  test "create is idempotent, clamps configured limits, and inserts no calls" do
    %{principal: agent} = agent_fixture()
    attrs = valid_attrs(agent.uid)

    assert {:ok, %{run: %Run{} = run}} = Workflow.create_with_dispatch(attrs)
    run_id = run.id
    assert {:ok, %{run: %Run{id: ^run_id}}} = Workflow.create_with_dispatch(attrs)
    assert run.concurrency == 8
    assert run.max_agent_calls == 32
    assert Repo.aggregate(Run, :count) == 1
    assert Repo.aggregate(AgentCall, :count) == 0
  end

  test "create rejects values outside product bounds before configured clamping" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_workflow_concurrency, %{min: 1, max: 32}}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("concurrency", 33)
             |> Workflow.create_with_dispatch()

    assert {:error, {:invalid_workflow_max_agent_calls, %{min: 1, max: 1_024}}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("max_agent_calls", 1_025)
             |> Workflow.create_with_dispatch()
  end

  test "create rejects oversized and non-object arguments" do
    %{principal: agent} = agent_fixture()

    assert {:error, %Ecto.Changeset{}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("args", %{"payload" => String.duplicate("x", 65_536)})
             |> Workflow.create_with_dispatch()

    assert {:error, %Ecto.Changeset{}} =
             agent.uid
             |> valid_attrs()
             |> Map.put("args", ["not", "an", "object"])
             |> Workflow.create_with_dispatch()
  end

  test "create rejects non-string attribute keys" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_workflow_attribute_key, :title}} =
             agent.uid
             |> valid_attrs()
             |> Map.put(:title, "Atom title")
             |> Workflow.create_with_dispatch()
  end

  defp valid_attrs(agent_uid) do
    %{
      "agent_uid" => agent_uid,
      "owner_session_id" => "session-parent",
      "reply_route" => %{"binding_name" => "bot"},
      "source_tool_call_id" => "tool-workflow-1",
      "title" => "Review the change",
      "script" => "return await agent('Review the change');",
      "args" => %{},
      "concurrency" => 32,
      "max_agent_calls" => 1_024
    }
  end
end
