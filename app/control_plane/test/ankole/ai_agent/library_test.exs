defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Repo

  setup do
    assert {:ok, %{skills: 3, changed: _changed}} = Library.sync_builtin_skills(force: true)
    :ok
  end

  test "syncs the first-party builtin skills into the catalog" do
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent_fixture().principal.uid)

    assert Enum.map(skills, & &1["skill_name"]) == ~w(jupyter-live-kernel nano-pdf ppt-master)
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
    assert skill["skill_uri"] == "skill://enabled/nano-pdf/SKILL.md"
    assert skill["content"] =~ "# nano-pdf"
    refute skill["content"] =~ "name: nano-pdf"
    refute skill["has_agent_overlay"]

    assert {:ok, overlay} =
             Library.skill_append(agent.uid, "nano-pdf", "Prefer page-by-page verification.")

    assert %AgentSkillOverlay{overlay_json: %{"text" => "Prefer page-by-page verification."}} =
             Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:ok, overlay} =
             Library.skill_append(agent.uid, "nano-pdf", "Use render output as final evidence.")

    assert %AgentSkillOverlay{
             overlay_json: %{
               "text" =>
                 "Prefer page-by-page verification.\n\nUse render output as final evidence."
             }
           } = Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:ok, skill} = Library.skill_view(agent.uid, "nano-pdf")
    assert skill["has_agent_overlay"]
    assert skill["content"] =~ "Agent-specific additions"
    assert skill["content"] =~ "Prefer page-by-page verification."
    assert skill["content"] =~ "Use render output as final evidence."

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

  test "set_agent_skill_enabled updates an existing registry row through the context facade" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %AgentSkill{enabled: false}} =
             Library.set_agent_skill_enabled(agent.uid, "nano-pdf", false)

    assert {:error, :skill_not_enabled} = Library.skill_view(agent.uid, "nano-pdf")

    assert {:ok, %AgentSkill{enabled: true}} =
             Library.set_agent_skill_enabled(agent.uid, "nano-pdf", true)

    assert {:ok, _skill} = Library.skill_view(agent.uid, "nano-pdf")
  end

  test "source reader uses runtime roots, internal shadowing, and metadata-only fingerprints" do
    root = tmp_library_root!("source-reader")
    public_skill = Path.join([root, "library", "skills", "shadowed"])
    public_only_skill = Path.join([root, "library", "skills", "public-only"])
    internal_skill = Path.join([root, "internal", "shadowed"])

    write_skill!(public_skill, "shadowed", "Public description.", "# Public")
    write_skill!(public_only_skill, "public-only", "Public-only description.", "# Public only")
    write_skill!(internal_skill, "shadowed", "Internal description.", "# Internal")

    File.mkdir_p!(Path.join(internal_skill, "target"))
    File.write!(Path.join([internal_skill, "target", "ignored.txt"]), "must not be scanned")
    File.mkdir_p!(Path.join(internal_skill, "node_modules"))
    File.write!(Path.join([internal_skill, "node_modules", "ignored.txt"]), "must not be scanned")
    File.mkdir_p!(Path.join(internal_skill, "__pycache__"))
    File.write!(Path.join([internal_skill, "__pycache__", "ignored.pyc"]), "must not be scanned")
    File.mkdir_p!(Path.join(internal_skill, "references"))
    File.write!(Path.join([internal_skill, "references", "guide.md"]), "original reference")

    with_library_config(
      library_root: Path.join(root, "library"),
      internal_skills_root: Path.join(root, "internal")
    )

    assert {:ok, sources} = SourceReader.read_builtin_skill_sources()
    catalog_hash = SourceReader.catalog_hash(sources)
    assert Enum.map(sources, & &1.name) == ["public-only", "shadowed"]

    shadowed = Enum.find(sources, &(&1.name == "shadowed"))
    assert shadowed.description == "Internal description."
    assert shadowed.metadata["skill_root"] == "internal"
    assert Enum.map(shadowed.files, & &1.path) == ["SKILL.md"]
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "target/"))
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "node_modules/"))
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "__pycache__/"))

    assert {:ok, content} = SourceReader.read_builtin_skill_file("shadowed", "SKILL.md")
    assert content =~ "# Internal"

    assert {:ok, reference} =
             SourceReader.read_builtin_skill_file("shadowed", "references/guide.md")

    assert reference == "original reference"

    File.write!(Path.join([internal_skill, "references", "guide.md"]), "changed reference")
    assert {:ok, sources_after_reference_change} = SourceReader.read_builtin_skill_sources()
    assert SourceReader.catalog_hash(sources_after_reference_change) == catalog_hash

    assert Enum.find(sources_after_reference_change, &(&1.name == "shadowed")).source_hash ==
             shadowed.source_hash

    File.write!(Path.join([internal_skill, "SKILL.md"]), """
    ---
    name: shadowed
    description: Internal description changed.
    default_enabled: true
    category: test
    ---

    # Internal
    """)

    assert {:ok, sources_after_skill_change} = SourceReader.read_builtin_skill_sources()
    assert SourceReader.catalog_hash(sources_after_skill_change) != catalog_hash

    %{principal: agent} = agent_fixture()
    assert {:ok, prompt_skills} = Library.skills_for_system_prompt(agent.uid)
    prompt_shadowed = Enum.find(prompt_skills, &(&1["skill_name"] == "shadowed"))
    assert prompt_shadowed["skill_root"] == "internal"
    assert prompt_shadowed["metadata"]["skill_root"] == "internal"

    with_library_config(
      library_root: Path.join(root, "library"),
      internal_skills_root: Path.join(root, "missing-internal")
    )

    assert {:ok, sources_without_internal} = SourceReader.read_builtin_skill_sources()
    assert Enum.map(sources_without_internal, & &1.name) == ["public-only", "shadowed"]

    assert Enum.find(sources_without_internal, &(&1.name == "shadowed")).description ==
             "Public description."
  end

  defp tmp_library_root!(name) do
    root =
      Path.join([
        System.tmp_dir!(),
        "ankole-library-test-#{name}-#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_skill!(dir, name, description, body) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    default_enabled: true
    category: test
    ---

    #{body}
    """)
  end

  defp with_library_config(config) do
    previous = Application.get_env(:ankole, Ankole.AIAgent.Library, [])

    Application.put_env(
      :ankole,
      Ankole.AIAgent.Library,
      Keyword.merge(previous, Keyword.put(config, :source_cache_ttl_ms, 0))
    )

    on_exit(fn -> Application.put_env(:ankole, Ankole.AIAgent.Library, previous) end)
  end
end
