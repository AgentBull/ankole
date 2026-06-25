defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library

  setup do
    assert {:ok, %{skills: 3, changed: _changed}} = Library.sync_builtin_skills(force: true)
    :ok
  end

  test "syncs the first-party builtin skills into the catalog" do
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent_fixture().principal.uid)

    assert Enum.map(skills, & &1["skill_name"]) == ~w(jupyter-live-kernel nano-pdf powerpoint)
    assert Enum.all?(skills, & &1["default_enabled"])

    assert Enum.find(skills, &(&1["skill_name"] == "jupyter-live-kernel"))["category"] ==
             "data-science"
  end

  test "new agents are seeded with soul and mission library entries" do
    %{principal: agent} = agent_fixture()

    assert {:ok, soul} = Library.get_soul(agent.uid)
    assert {:ok, mission} = Library.get_mission(agent.uid)

    assert soul == File.read!(Path.expand("../../../../library/templates/SOUL.md", __DIR__))
    assert mission == File.read!(Path.expand("../../../../library/templates/MISSION.md", __DIR__))
  end

  test "skill_view merges canonical skill body with agent append" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skill} = Library.skill_view(agent.uid, "nano-pdf")
    assert skill["file_path"] == "/workspace/library-containers/skills/nano-pdf/SKILL.md"
    assert skill["content"] =~ "# nano-pdf"
    refute skill["content"] =~ "name: nano-pdf"
    refute skill["has_agent_append"]

    assert {:ok, _entry} =
             Library.skill_append(agent.uid, "nano-pdf", "Prefer page-by-page verification.")

    assert {:ok, skill} = Library.skill_view(agent.uid, "nano-pdf")
    assert skill["has_agent_append"]
    assert skill["content"] =~ "Agent-specific additions"
    assert skill["content"] =~ "Prefer page-by-page verification."

    assert {:ok, append} = Library.skill_view(agent.uid, "nano-pdf", "AGENT_APPEND.md")
    assert append["content"] == "Prefer page-by-page verification."
  end

  test "materializes effective library-container files to a workspace path" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _entry} =
             Library.skill_append(agent.uid, "powerpoint", "Use the corporate title slide.")

    root =
      Path.join(System.tmp_dir!(), "ankole-library-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, paths} = Library.materialize_effective_library(agent.uid, root)

    assert Path.join(root, "SOUL.md") in paths
    assert File.exists?(Path.join(root, "MISSION.md"))
    assert File.exists?(Path.join(root, "skills/powerpoint/SKILL.md"))
    assert File.read!(Path.join(root, "skills/powerpoint/AGENT_APPEND.md")) =~ "corporate title"
  end
end
