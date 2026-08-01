defmodule Ankole.AgentHomePathsTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentHomePaths

  test "matches the shared Elixir and TypeScript path vectors" do
    vectors =
      __DIR__
      |> Path.join("../../../kernel/proto/ankole/runtime_fabric/v1/agent_home_path_vectors.json")
      |> File.read!()
      |> Ankole.JSON.decode!()

    for vector <- vectors["valid"] do
      assert AgentHomePaths.home(vector["agent_uid"]) == vector["home"]
      assert AgentHomePaths.codex_home(vector["agent_uid"]) == vector["codex_home"]

      assert AgentHomePaths.session_workspace(vector["agent_uid"], vector["workspace_id"]) ==
               vector["session_workspace"]

      assert AgentHomePaths.job_workspace(vector["agent_uid"], vector["job_id"]) ==
               vector["job_workspace"]
    end

    for agent_uid <- vectors["invalid_agent_uids"] do
      assert {:error, :invalid_agent_home_uid} = AgentHomePaths.validate_agent_uid(agent_uid)
      assert_raise ArgumentError, fn -> AgentHomePaths.home(agent_uid) end
    end

    for workspace_id <- vectors["invalid_workspace_ids"] do
      assert_raise ArgumentError, fn ->
        AgentHomePaths.session_workspace("agent-1", workspace_id)
      end
    end

    for job_id <- vectors["invalid_job_ids"] do
      assert_raise ArgumentError, fn -> AgentHomePaths.job_workspace("agent-1", job_id) end
    end
  end

  test "documents use their uppercase canonical names" do
    assert AgentHomePaths.document("agent-1", "soul") == "/agents/agent-1/SOUL.md"
    assert AgentHomePaths.document("agent-1", "mission") == "/agents/agent-1/MISSION.md"
    assert AgentHomePaths.document("agent-1", "design") == "/agents/agent-1/DESIGN.md"
  end
end
