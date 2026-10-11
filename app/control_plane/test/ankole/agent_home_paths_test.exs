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
      assert AgentHomePaths.home() == vector["home"]

      assert AgentHomePaths.session_workspace(vector["workspace_id"]) ==
               vector["session_workspace"]
    end

    for workspace_id <- vectors["invalid_workspace_ids"] do
      assert_raise ArgumentError, fn ->
        AgentHomePaths.session_workspace(workspace_id)
      end
    end
  end
end
