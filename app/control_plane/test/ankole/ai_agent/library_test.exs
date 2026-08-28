defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo

  test "syncs the first-party builtin skills into the catalog" do
    %{principal: agent} = agent_fixture()
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert Enum.all?(skills, & &1["default_enabled"])

    research = Enum.find(skills, &(&1["skill_name"] == "create-deep-research"))
    assert research["source_kind"] == "builtin"
    assert research["agent_plugin_id"] == "deep-research"

    assert research["relative_path"] ==
             "agent-plugins/deep-research/skills/create-deep-research"

    assert {:ok, %{"skills" => runtime_skills, "agent_plugins" => agent_plugins}} =
             Library.runtime_catalog_for_agent(agent.uid)

    runtime_research = Enum.find(runtime_skills, &(&1["skill_name"] == "create-deep-research"))
    assert runtime_research["source_kind"] == "builtin"
    assert runtime_research["agent_plugin_id"] == "deep-research"
    assert runtime_research["skill_root"] == "library"

    research_plugin = Enum.find(agent_plugins, &(&1["id"] == "deep-research"))

    assert Enum.any?(
             research_plugin["skills"],
             &(&1["catalog_name"] == runtime_research["skill_name"])
           )

    lineage = Enum.find(skills, &(&1["skill_name"] == "idea-lineage"))
    assert lineage["metadata"]["brain_recall_only"]

    runtime_lineage = Enum.find(runtime_skills, &(&1["skill_name"] == "idea-lineage"))
    assert runtime_lineage["metadata"]["brain_recall_only"]

    assert {:ok, shipped_sources} = Library.shipped_skill_sources()
    assert Enum.count(shipped_sources, &(&1.name == "idea-lineage")) == 1

    assert {:ok, research_view} = Library.skill_view(agent.uid, "create-deep-research")
    assert research_view["content"] =~ "Deep Research"

    assert {:ok, lineage_view} = Library.skill_view(agent.uid, "idea-lineage")
    assert lineage_view["content"] =~ "Idea lineage"

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

    assert {:ok, brainstorming} = Library.skill_view(agent.uid, "brainstorming")
    assert brainstorming["content"] =~ "This is a playbook, not a fixed workflow."
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

  test "skill_view merges canonical skill body with delivered skill lessons" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["skill_uri"] == "skill://enabled/pdf/SKILL.md"
    assert skill["content"] =~ "# PDF"
    refute skill["content"] =~ "name: pdf"
    refute skill["has_agent_overlay"]

    context = %{
      evidence_job_ids: MapSet.new([1001, 1002]),
      human_input_job_ids: MapSet.new([1001]),
      checked_release: "test-release"
    }

    assert {:ok, %{accepted: [lesson], rejected: []}} =
             Library.apply_skill_lesson_adds(
               agent.uid,
               [
                 %{
                   "skill_name" => "pdf",
                   "content" =>
                     "If page extraction returns empty text, render the page before retrying.",
                   "evidence_job_ids" => [1001, 1002]
                 }
               ],
               context
             )

    assert lesson.author_kind == "dreaming"
    assert lesson.checked_release == "test-release"
    assert is_binary(lesson.checked_skill_hash)
    assert %DateTime{} = lesson.review_after

    assert {:ok, %AgentSkillLesson{}} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Verify totals against the source table before delivery.",
               agent.uid
             )

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["has_agent_overlay"]
    assert skill["content"] =~ "Agent-specific additions"
    assert skill["content"] =~ "Field notes (dated; verify against the current environment):"
    assert skill["content"] =~ "If page extraction returns empty text"
    assert skill["content"] =~ ", human] Verify totals"

    {human_index, _} = :binary.match(skill["content"], "Verify totals")
    {dreaming_index, _} = :binary.match(skill["content"], "If page extraction")
    assert human_index < dreaming_index

    assert {:error, :skill_file_not_found} =
             Library.skill_view(agent.uid, "pdf", "AGENT_APPEND.md")
  end

  test "lists skill lessons for the console and retires them independently of enablement" do
    %{principal: agent} = agent_fixture()

    assert {:ok, []} = Library.list_skill_lessons(agent.uid)

    assert {:ok, %AgentSkillLesson{} = pdf_lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Prefer page-by-page verification.",
               agent.uid
             )

    assert {:ok, _lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "create-deep-research",
               "Name the disconfirming evidence first.",
               agent.uid
             )

    assert {:ok, lessons} = Library.list_skill_lessons(agent.uid)
    assert Enum.map(lessons, & &1["skill_name"]) |> Enum.sort() == ~w(create-deep-research pdf)

    pdf = Enum.find(lessons, &(&1["skill_name"] == "pdf"))
    assert pdf["agent_plugin_id"] == nil
    assert pdf["content"] == "Prefer page-by-page verification."
    assert pdf["author_kind"] == "human"
    assert pdf["author_uid"] == agent.uid
    assert pdf["effective_enabled"]
    assert pdf["review_after"] == nil

    research = Enum.find(lessons, &(&1["skill_name"] == "create-deep-research"))
    assert research["agent_plugin_id"] == "deep-research"

    assert {:ok, _skill} = Library.set_agent_skill_override(agent.uid, "pdf", false)

    assert {:error, :skill_not_enabled} =
             Library.create_skill_lesson(agent.uid, "pdf", "unreachable", agent.uid)

    assert {:ok, lessons} = Library.list_skill_lessons(agent.uid)
    disabled = Enum.find(lessons, &(&1["skill_name"] == "pdf"))
    refute disabled["effective_enabled"]

    assert {:ok, %AgentSkillLesson{retire_reason: "human_revoked"}} =
             Library.retire_skill_lesson(agent.uid, pdf_lesson.id)

    assert {:error, :skill_lesson_already_retired} =
             Library.retire_skill_lesson(agent.uid, pdf_lesson.id)

    assert {:ok, lessons} = Library.list_skill_lessons(agent.uid)
    retired = Enum.find(lessons, &(&1["skill_name"] == "pdf"))
    assert retired["retire_reason"] == "human_revoked"
    assert is_binary(retired["retired_at"])
  end

  test "renders a Skill lesson set atomically through the batch API" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{"pdf" => empty_pdf, "xlsx" => empty_xlsx}} =
             Library.rendered_skill_lessons(agent.uid, ["pdf", "xlsx"])

    refute empty_pdf["has_lessons"]
    assert empty_pdf["text"] == ""
    assert empty_pdf["content_hash"] == ""
    refute empty_xlsx["has_lessons"]

    assert {:ok, _lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Prefer page-by-page verification.",
               agent.uid
             )

    assert {:ok, %{"pdf" => pdf, "xlsx" => xlsx}} =
             Library.rendered_skill_lessons(agent.uid, ["pdf", "xlsx"])

    assert pdf["has_lessons"]
    assert pdf["text"] =~ "Field notes (dated; verify against the current environment):"
    assert pdf["text"] =~ ", human] Prefer page-by-page verification."
    assert is_binary(pdf["content_hash"]) and pdf["content_hash"] != ""
    refute xlsx["has_lessons"]

    assert {:error, :duplicate_skill_name} =
             Library.rendered_skill_lessons(agent.uid, ["pdf", "pdf"])

    agent.uid
    |> then(&Repo.get_by!(AgentSkill, agent_uid: &1, skill_name: "xlsx"))
    |> AgentSkill.changeset(%{enabled_override: false})
    |> Repo.update!()

    assert {:error, :skill_not_enabled} =
             Library.rendered_skill_lessons(agent.uid, ["pdf", "xlsx"])
  end

  test "skill lesson writes resolve cold AppConfigure defaults before opening a transaction" do
    %{principal: agent} = agent_fixture()

    on_exit(fn -> Cache.clear_for_test() end)
    Cache.clear_for_test()

    assert {:ok, %AgentSkillLesson{content: "Cold-cache guidance."}} =
             Library.create_skill_lesson(agent.uid, "pdf", "Cold-cache guidance.", agent.uid)
  end

  test "agent-installed skills are recorded from worker file observations" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 skill_name: "agent-notes",
                 description: "Agent-installed note-taking skill.",
                 default_enabled: true,
                 tags: ["notes"],
                 category: "custom"
               }
             ])

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)

    installed = Enum.find(skills, &(&1["skill_name"] == "agent-notes"))
    assert installed["source_kind"] == "installed"
    assert installed["relative_path"] == "agent-notes"
    assert installed["category"] == "custom"

    assert {:ok, runtime_skills} = Library.runtime_skills_for_agent(agent.uid)
    runtime_installed = Enum.find(runtime_skills, &(&1["skill_name"] == "agent-notes"))
    assert runtime_installed["metadata"]["category"] == "custom"

    assert {:error, :skill_file_not_found} = Library.skill_view(agent.uid, "agent-notes")

    assert {:ok, _} = Library.replace_installed_skill_observations(agent.uid, [])
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

    assert {:ok, _} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 "skill_name" => "agent-notes",
                 "description" => "Agent-installed note-taking skill.",
                 "default_enabled" => true,
                 "tags" => ["notes"],
                 "category" => "custom"
               }
             ])

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

    assert {:ok, _} = Library.sync_agent_skills(agent.uid)

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
                 tags: []
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

  test "Agent Plugin overrides store only explicit choices" do
    %{principal: agent} = agent_fixture()

    assert [[0]] = Repo.query!("SELECT count(*) FROM agent_plugin_overrides").rows

    assert {:ok, %{agent_plugin_id: "deep-research", enabled: false}} =
             AgentPlugins.set_agent_override(agent.uid, "deep-research", false)

    assert [["deep-research", false]] =
             Repo.query!(
               """
               SELECT agent_plugin_id, enabled
               FROM agent_plugin_overrides
               WHERE agent_uid = $1
               """,
               [agent.uid]
             ).rows

    assert {:ok, nil} = AgentPlugins.set_agent_override(agent.uid, "deep-research", nil)
    assert [[0]] = Repo.query!("SELECT count(*) FROM agent_plugin_overrides").rows
  end

  test "a sync with unchanged sources rewrites no registry rows" do
    %{principal: agent} = agent_fixture()
    frozen = ~U[2020-01-01 00:00:00.000000Z]

    {row_count, _rows} =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent.uid)
      |> Repo.update_all(set: [synced_at: frozen, updated_at: frozen])

    assert row_count > 0
    assert {:ok, %{changed: false}} = Library.sync_agent_skills(agent.uid)

    refreshed =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent.uid)
      |> Repo.all()

    assert length(refreshed) == row_count
    assert Enum.all?(refreshed, &(&1.synced_at == frozen and &1.updated_at == frozen))
  end

  test "a sync rewrites only the skill row whose source content changed" do
    %{principal: agent} = agent_fixture()
    frozen = ~U[2020-01-01 00:00:00.000000Z]

    AgentSkill
    |> where([skill], skill.agent_uid == ^agent.uid)
    |> Repo.update_all(set: [synced_at: frozen, updated_at: frozen])

    AgentSkill
    |> where([skill], skill.agent_uid == ^agent.uid and skill.skill_name == "pdf")
    |> Repo.update_all(set: [description: "Stale description."])

    assert {:ok, %{changed: true}} = Library.sync_agent_skills(agent.uid)

    pdf = Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "pdf")
    refute pdf.description == "Stale description."
    assert DateTime.after?(pdf.synced_at, frozen)

    untouched =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent.uid and skill.skill_name != "pdf")
      |> Repo.all()

    assert untouched != []
    assert Enum.all?(untouched, &(&1.synced_at == frozen and &1.updated_at == frozen))
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
    assert {:ok, runtime_skills} = Library.runtime_skills_for_agent(agent.uid)
    runtime_shadowed = Enum.find(runtime_skills, &(&1["skill_name"] == "shadowed"))
    assert runtime_shadowed["skill_root"] == "internal"
    assert runtime_shadowed["metadata"]["skill_root"] == "internal"

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
