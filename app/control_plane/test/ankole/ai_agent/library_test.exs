defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo

  setup do
    assert {:ok, %{skills: 13, changed: _changed}} = Library.sync_builtin_skills(force: true)
    :ok
  end

  test "syncs the first-party builtin skills into the catalog" do
    %{principal: agent} = agent_fixture()
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)

    assert Enum.map(skills, & &1["skill_name"]) ==
             ~w(brain-review browser create-deep-research design-md docx jupyter-live-kernel pdf pptx xlsx)

    assert Enum.all?(skills, & &1["default_enabled"])

    research = Enum.find(skills, &(&1["skill_name"] == "create-deep-research"))
    assert research["source_kind"] == "builtin"
    assert research["agent_plugin_id"] == "deep-research"

    assert research["relative_path"] ==
             "agent-plugins/deep-research/skills/create-deep-research"

    assert {:ok, prompt_skills} = Library.skills_for_system_prompt(agent.uid)
    prompt_research = Enum.find(prompt_skills, &(&1["skill_name"] == "create-deep-research"))
    assert prompt_research["source_kind"] == "builtin"
    assert prompt_research["agent_plugin_id"] == "deep-research"
    assert prompt_research["skill_root"] == "library"

    assert {:ok, research_view} = Library.skill_view(agent.uid, "create-deep-research")
    assert research_view["content"] =~ "Deep Research"

    for skill_name <- ~w(lark-im lark-office-suite lark-oa) do
      assert %AgentSkill{
               enabled_override: nil,
               default_enabled: true,
               source_kind: "builtin",
               agent_plugin_id: "lark"
             } =
               Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: skill_name)
    end

    assert {:ok, false} = AgentPlugins.effective_enabled?(agent.uid, "lark")

    assert {:ok, _browser} = Library.skill_view(agent.uid, "browser")

    assert Enum.find(skills, &(&1["skill_name"] == "jupyter-live-kernel"))["category"] ==
             "data-science"

    assert Enum.find(skills, &(&1["skill_name"] == "design-md"))

    assert {:ok, design_skill} = Library.skill_view(agent.uid, "design-md")
    assert design_skill["content"] =~ "~/DESIGN.md"
  end

  test "new agents are seeded with soul, mission, and design library entries" do
    %{principal: agent} = agent_fixture()

    assert {:ok, soul} = Library.get_soul(agent.uid)
    assert {:ok, mission} = Library.get_mission(agent.uid)
    assert {:ok, design} = Library.get_design(agent.uid)

    assert soul == File.read!(Path.expand("../../../../library/templates/SOUL.md", __DIR__))
    assert mission == File.read!(Path.expand("../../../../library/templates/MISSION.md", __DIR__))
    assert design == File.read!(Path.expand("../../../../library/templates/DESIGN.md", __DIR__))
  end

  test "rejects unimplemented library source kinds" do
    %{principal: agent} = agent_fixture()

    changeset =
      AgentLibraryContainerEntry.changeset(%AgentLibraryContainerEntry{}, %{
        agent_uid: agent.uid,
        path: "SETTING.md",
        source_kind: "setting",
        content: "unused",
        metadata: %{}
      })

    assert "is invalid" in errors_on(changeset).source_kind
  end

  test "skill_view merges canonical skill body with agent DB overlay" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["skill_uri"] == "skill://enabled/pdf/SKILL.md"
    assert skill["content"] =~ "# PDF"
    refute skill["content"] =~ "name: pdf"
    refute skill["has_agent_overlay"]

    assert {:ok, overlay} =
             Library.skill_append(agent.uid, "pdf", "Prefer page-by-page verification.")

    assert %AgentSkillOverlay{overlay_json: %{"text" => "Prefer page-by-page verification."}} =
             Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:ok, overlay} =
             Library.skill_append(agent.uid, "pdf", "Use render output as final evidence.")

    assert %AgentSkillOverlay{
             overlay_json: %{
               "text" =>
                 "Prefer page-by-page verification.\n\nUse render output as final evidence."
             }
           } = Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["has_agent_overlay"]
    assert skill["content"] =~ "Agent-specific additions"
    assert skill["content"] =~ "Prefer page-by-page verification."
    assert skill["content"] =~ "Use render output as final evidence."

    current = Repo.get!(AgentSkillOverlay, overlay.id)

    assert {:error, :skill_overlay_conflict} =
             Library.replace_skill_overlay_cas(
               agent.uid,
               "pdf",
               "stale-hash",
               %{"text" => "stale replacement"}
             )

    assert {:ok, replaced} =
             Library.replace_skill_overlay_cas(
               agent.uid,
               "pdf",
               current.content_hash,
               %{"text" => "Consolidated verification guidance."}
             )

    assert replaced.overlay_json == %{"text" => "Consolidated verification guidance."}

    assert {:error, :skill_file_not_found} =
             Library.skill_view(agent.uid, "pdf", "AGENT_APPEND.md")
  end

  test "lists skill overlays for the console and deletes them independently of enablement" do
    %{principal: agent} = agent_fixture()

    assert {:ok, []} = Library.list_skill_overlays(agent.uid)

    assert {:ok, _overlay} =
             Library.skill_append(agent.uid, "pdf", "Prefer page-by-page verification.")

    assert {:ok, _overlay} =
             Library.skill_append(
               agent.uid,
               "create-deep-research",
               "Name the disconfirming evidence first."
             )

    assert {:ok, overlays} = Library.list_skill_overlays(agent.uid)
    assert Enum.map(overlays, & &1["skill_name"]) |> Enum.sort() == ~w(create-deep-research pdf)

    pdf = Enum.find(overlays, &(&1["skill_name"] == "pdf"))
    assert pdf["skill_id"] == "pdf"
    assert pdf["agent_plugin_id"] == nil
    assert pdf["text"] == "Prefer page-by-page verification."
    assert pdf["effective_enabled"]
    assert is_binary(pdf["content_hash"])

    research = Enum.find(overlays, &(&1["skill_name"] == "create-deep-research"))
    assert research["skill_id"] == "deep-research:create-deep-research"
    assert research["agent_plugin_id"] == "deep-research"

    assert {:ok, _skill} = Library.set_agent_skill_override(agent.uid, "pdf", false)
    assert {:ok, overlays} = Library.list_skill_overlays(agent.uid)
    disabled = Enum.find(overlays, &(&1["skill_name"] == "pdf"))
    refute disabled["effective_enabled"]

    assert {:error, :skill_not_enabled} =
             Library.replace_skill_overlay_cas(
               agent.uid,
               "pdf",
               disabled["content_hash"],
               %{"text" => "unreachable"}
             )

    assert {:ok, %AgentSkillOverlay{deleted_at: %DateTime{}}} =
             Library.delete_skill_overlay(agent.uid, "pdf")

    assert {:ok, overlays} = Library.list_skill_overlays(agent.uid)
    assert Enum.map(overlays, & &1["skill_name"]) == ["create-deep-research"]

    assert {:error, :skill_overlay_not_found} = Library.delete_skill_overlay(agent.uid, "pdf")

    assert {:ok, _skill} = Library.set_agent_skill_override(agent.uid, "pdf", true)
    assert {:ok, _overlay} = Library.skill_append(agent.uid, "pdf", "Written after deletion.")
    assert {:ok, overlays} = Library.list_skill_overlays(agent.uid)
    assert Enum.find(overlays, &(&1["skill_name"] == "pdf"))["text"] == "Written after deletion."
  end

  test "skill overlay writes resolve cold AppConfigure defaults before opening a transaction" do
    %{principal: agent} = agent_fixture()

    on_exit(fn -> Cache.clear_for_test() end)
    Cache.clear_for_test()

    assert {:ok, %AgentSkillOverlay{overlay_json: %{"text" => "Cold-cache guidance."}}} =
             Library.skill_append(agent.uid, "pdf", "Cold-cache guidance.")
  end

  test "agent-installed skills are recorded from worker file observations" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{skills: 14}} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 skill_name: "agent-notes",
                 description: "Agent-installed note-taking skill.",
                 default_enabled: true,
                 tags: ["notes"],
                 category: "custom",
                 disable_model_invocation: false
               }
             ])

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)

    installed = Enum.find(skills, &(&1["skill_name"] == "agent-notes"))
    assert installed["source_kind"] == "installed"
    assert installed["relative_path"] == "agent-notes"
    assert installed["category"] == "custom"

    assert {:error, :skill_file_not_found} = Library.skill_view(agent.uid, "agent-notes")

    assert {:ok, %{skills: 13}} = Library.replace_installed_skill_observations(agent.uid, [])
    assert {:error, :skill_not_found} = Library.skill_view(agent.uid, "agent-notes")
  end

  test "installed Skills reject an invalid runtime declaration" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_ankole_runtime, "worker"}} =
             Library.replace_installed_skill_observations(agent.uid, [
               installed_skill_observation("invalid-runtime", "worker")
             ])
  end

  test "agent-installed registry rows survive builtin sync until new worker observations arrive" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{skills: 14}} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 "skill_name" => "agent-notes",
                 "description" => "Agent-installed note-taking skill.",
                 "default_enabled" => true,
                 "tags" => ["notes"],
                 "category" => "custom",
                 "disable_model_invocation" => false
               }
             ])

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

    assert {:ok, %{skills: 13}} = Library.sync_agent_skills(agent.uid)

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert Enum.any?(skills, &(&1["skill_name"] == "agent-notes"))
  end

  test "rejects Skill name collisions across first-party and installed sources" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:skill_source_name_conflicts, ["pdf"]}} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 skill_name: "pdf",
                 description: "Conflicting installed Skill.",
                 default_enabled: true,
                 tags: [],
                 disable_model_invocation: false
               }
             ])

    assert %AgentSkill{source_kind: "builtin", agent_plugin_id: nil} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "pdf")

    root = tmp_library_root!("plugin-collision")
    library_root = Path.join(root, "library")

    write_skill!(
      Path.join([library_root, "skills", "shared-name"]),
      "shared-name",
      "Standalone.",
      "# Standalone"
    )

    write_agent_plugin!(library_root, "collision-plugin", "shared-name")
    with_library_config(library_root: library_root)

    assert {:error, {:skill_source_name_conflicts, ["shared-name"]}} =
             Library.sync_builtin_skills(force: true)

    assert {:error, {:skill_source_name_conflicts, ["shared-name"]}} =
             Library.global_capabilities()
  end

  test "Agent Skill overrides can be set and cleared without rewriting the inherited default" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %AgentSkill{enabled_override: false}} =
             Library.set_agent_skill_override(agent.uid, "pdf", false)

    assert {:error, :skill_not_enabled} = Library.skill_view(agent.uid, "pdf")

    assert {:ok, %AgentSkill{enabled_override: true}} =
             Library.set_agent_skill_override(agent.uid, "pdf", true)

    assert {:ok, _skill} = Library.skill_view(agent.uid, "pdf")

    assert {:ok, %AgentSkill{enabled_override: nil}} =
             Library.set_agent_skill_override(agent.uid, "pdf", nil)

    assert {:ok, _skill} = Library.skill_view(agent.uid, "pdf")
  end

  test "effective Agent Plugin lookup does not resynchronize Skill registry rows" do
    %{principal: agent} = agent_fixture()
    skill = Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "lark-im")
    old_sync = ~U[2020-01-01 00:00:00.000000Z]

    skill
    |> Ecto.Changeset.change(synced_at: old_sync)
    |> Repo.update!()

    assert {:ok, false} = AgentPlugins.effective_enabled?(agent.uid, "lark")

    assert %AgentSkill{synced_at: ^old_sync} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "lark-im")
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
    ankole-runtime: background_job
    category: test
    ---

    # Internal
    """)

    assert {:ok, sources_after_skill_change} = SourceReader.read_builtin_skill_sources()
    assert SourceReader.catalog_hash(sources_after_skill_change) != catalog_hash

    assert Enum.find(sources_after_skill_change, &(&1.name == "shadowed")).metadata[
             "ankole-runtime"
           ] == "background_job"

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

  defp installed_skill_observation(name, runtime) do
    %{
      skill_name: name,
      description: "Installed #{name} Skill.",
      default_enabled: true,
      tags: [],
      disable_model_invocation: false,
      ankole_runtime: runtime
    }
  end

  defp write_agent_plugin!(library_root, plugin_id, skill_name) do
    plugin_root = Path.join([library_root, "agent-plugins", plugin_id])

    write_skill!(
      Path.join([plugin_root, "skills", skill_name]),
      skill_name,
      "Plugin member.",
      "# Plugin"
    )

    File.mkdir_p!(Path.join(plugin_root, ".codex-plugin"))

    File.write!(
      Path.join([plugin_root, ".codex-plugin", "plugin.json"]),
      Ankole.JSON.encode!(%{
        "name" => plugin_id,
        "version" => "1.0.0",
        "description" => "Collision test Plugin.",
        "skills" => "./skills/"
      })
    )
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
