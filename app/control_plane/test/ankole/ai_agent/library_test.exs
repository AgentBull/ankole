defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.Repo

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

  test "skill_view merges canonical skill body with agent DB overlay" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skill} = Library.skill_view(agent.uid, "nano-pdf")
    assert skill["file_path"] == "/workspace/library-containers/skills/nano-pdf/SKILL.md"
    assert skill["content"] =~ "# nano-pdf"
    refute skill["content"] =~ "name: nano-pdf"
    refute skill["has_agent_overlay"]

    assert {:ok, overlay} =
             Library.skill_append(agent.uid, "nano-pdf", "Prefer page-by-page verification.")

    assert %AgentSkillOverlay{overlay_json: %{"text" => "Prefer page-by-page verification."}} =
             Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:ok, skill} = Library.skill_view(agent.uid, "nano-pdf")
    assert skill["has_agent_overlay"]
    assert skill["content"] =~ "Agent-specific additions"
    assert skill["content"] =~ "Prefer page-by-page verification."

    assert {:error, :skill_file_not_found} =
             Library.skill_view(agent.uid, "nano-pdf", "AGENT_APPEND.md")
  end

  test "agent-installed skills are recorded from worker file observations" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{skills: 4}} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 skill_name: "agent-notes",
                 relative_path: "agent-notes",
                 description: "Agent-installed note-taking skill.",
                 default_enabled: true,
                 metadata: %{"category" => "custom"},
                 xxh3_128: "7b16fe7c3e492b87d9615265f0856cec",
                 file_count: 1
               }
             ])

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)

    installed = Enum.find(skills, &(&1["skill_name"] == "agent-notes"))
    assert installed["source_kind"] == "installed"
    assert installed["relative_path"] == "agent-notes"
    assert installed["category"] == "custom"

    assert {:error, :skill_file_not_found} = Library.skill_view(agent.uid, "agent-notes")

    assert {:ok, %{skills: 3}} = Library.replace_installed_skill_observations(agent.uid, [])
    assert {:error, :skill_not_found} = Library.skill_view(agent.uid, "agent-notes")
  end

  test "agent-installed registry rows survive builtin sync until new worker observations arrive" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{skills: 4}} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 "skill_name" => "agent-notes",
                 "relative_path" => "agent-notes",
                 "description" => "Agent-installed note-taking skill.",
                 "default_enabled" => true,
                 "metadata" => %{"category" => "custom"},
                 "content_hash" => "7b16fe7c3e492b87d9615265f0856cec",
                 "file_count" => 1
               }
             ])

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

    assert {:ok, %{skills: 3}} = Library.sync_agent_skills(agent.uid)

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert Enum.any?(skills, &(&1["skill_name"] == "agent-notes"))
  end
end
