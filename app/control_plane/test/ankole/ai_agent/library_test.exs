defmodule Ankole.AIAgent.LibraryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.Schemas.Skill
  alias Ankole.AIAgent.Library.Skills
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo

  test "Skill frontmatter supports YAML block scalars, quotes, and lists" do
    root = Path.join(System.tmp_dir!(), "ankole-skill-yaml-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "yaml-example"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join([root, "yaml-example", "SKILL.md"]), """
    ---
    name: yaml-example
    description: >-
      Read a report:
      preserve its meaning.
    tags: ["one,two", 'three']
    default_enabled: false
    ---
    # Example
    """)

    assert {:ok, source} = SourceReader.read_skill_source(root, "library", "yaml-example")
    assert source.description == "Read a report: preserve its meaning."
    assert source.metadata["tags"] == ["one,two", "three"]
    refute source.default_enabled

    path = Path.join([root, "yaml-example", "SKILL.md"])
    valid = File.read!(path)
    File.write!(path, String.replace(valid, "name: yaml-example", "name: false"))

    assert {:error, :invalid_skill_name} =
             SourceReader.read_skill_source(root, "library", "yaml-example")

    File.write!(
      path,
      String.replace(valid, "name: yaml-example", "name: yaml-example\nankole-runtime: true")
    )

    assert {:error, {:invalid_ankole_runtime, true}} =
             SourceReader.read_skill_source(root, "library", "yaml-example")
  end

  test "syncs the first-party builtin skills into the catalog" do
    %{principal: agent} = agent_fixture()
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert Enum.all?(skills, & &1["enabled"])

    research = Enum.find(skills, &(&1["skill_name"] == "create-deep-research"))
    assert research["source_kind"] == "agent_plugin"
    assert research["agent_plugin_id"] == "deep-research"

    assert research["relative_path"] ==
             "create-deep-research"

    assert {:ok, %{"skills" => runtime_skills, "agent_plugins" => agent_plugins}} =
             Library.runtime_catalog_for_agent(agent.uid)

    runtime_research = Enum.find(runtime_skills, &(&1["skill_name"] == "create-deep-research"))
    assert runtime_research["source_kind"] == "agent_plugin"
    assert runtime_research["agent_plugin_id"] == "deep-research"
    assert runtime_research["skill_root"] == "drive"

    research_plugin = Enum.find(agent_plugins, &(&1["id"] == "deep-research"))

    assert Enum.any?(
             research_plugin["skills"],
             &(&1["catalog_name"] == runtime_research["skill_name"])
           )

    assert {:ok, shipped_sources} = Library.shipped_skill_sources()
    assert Enum.count(shipped_sources, &(&1.name == "idea-lineage")) == 1

    assert {:ok, _research_view} = Library.skill_view(agent.uid, "create-deep-research")
    assert {:ok, _lineage_view} = Library.skill_view(agent.uid, "idea-lineage")

    for skill_name <- ~w(lark-im lark-approvals lark-tasks lark-calendar) do
      assert %Skill{enabled_for_all: true, source_kind: :agent_plugin, agent_plugin_id: "lark"} =
               Repo.get_by!(Skill, slug: skill_name)
    end

    assert {:ok, false} = AgentPlugins.effective_enabled?(agent.uid, "lark")

    assert {:ok, _browser} = Library.skill_view(agent.uid, "browser")

    assert Enum.find(skills, &(&1["skill_name"] == "jupyter-live-kernel"))["category"] ==
             "data-science"

    assert Enum.find(skills, &(&1["skill_name"] == "design-md"))

    assert {:ok, _design_skill} = Library.skill_view(agent.uid, "design-md")
    assert {:ok, _brainstorming} = Library.skill_view(agent.uid, "brainstorming")
  end

  test "the enabled Lark Plugin exposes the generated approvals Toolkit" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _plugin} = AgentPlugins.set_agent_override(agent.uid, "lark", true)

    assert {:ok, %{"skills" => runtime_skills}} = Library.runtime_catalog_for_agent(agent.uid)

    approvals = Enum.find(runtime_skills, &(&1["skill_name"] == "lark-approvals"))
    assert approvals["metadata"]["ankole-runtime"] in [nil, "any"]

    assert {:ok, %{"content" => yaml}} =
             Library.skill_view(agent.uid, "lark-approvals", "agents/openai.yaml")

    assert {:ok, %{"dependencies" => %{"tools" => [declaration]}}} =
             YamlElixir.read_from_string(yaml)

    assert declaration["transport"] == "connector"
    assert declaration["toolkit"] == "lark_approvals"
    assert "approvals_approve" in declaration["enabled_tools"]
  end

  test "skill_view merges canonical skill body with delivered skill lessons" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["skill_uri"] == "/drive/Skills/pdf/SKILL.md"
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

    assert lesson.author_kind == :dreaming
    assert lesson.checked_release == "test-release"
    assert is_binary(lesson.checked_skill_hash)
    assert %DateTime{} = lesson.review_after

    assert {:ok, %AgentSkillLesson{}} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Verify totals against the source table before delivery.",
               Ankole.ActorRef.from_principal(agent)
             )

    assert {:ok, skill} = Library.skill_view(agent.uid, "pdf")
    assert skill["has_agent_overlay"]
    assert skill["content"] =~ "If page extraction returns empty text"
    {human_index, _} = :binary.match(skill["content"], "Verify totals")
    {dreaming_index, _} = :binary.match(skill["content"], "If page extraction")
    assert human_index < dreaming_index

    assert {:error, :not_found} =
             Library.skill_view(agent.uid, "pdf", "AGENT_APPEND.md")
  end

  test "lists skill lessons and retires them independently of enablement" do
    %{principal: agent} = agent_fixture()

    assert lessons(agent.uid) == []

    assert {:ok, %AgentSkillLesson{} = pdf_lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Prefer page-by-page verification.",
               Ankole.ActorRef.from_principal(agent)
             )

    assert {:ok, _lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "create-deep-research",
               "Name the disconfirming evidence first.",
               Ankole.ActorRef.from_principal(agent)
             )

    lessons = lessons(agent.uid)
    assert Enum.map(lessons, & &1.skill_name) == ~w(create-deep-research pdf)

    pdf = Enum.find(lessons, &(&1.skill_name == "pdf"))
    assert pdf.content == "Prefer page-by-page verification."
    assert pdf.author_kind == :human
    assert pdf.author == Ankole.ActorRef.from_principal(agent)
    assert pdf.review_after == nil

    %{principal: manager} = human_fixture()

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: manager.uid,
        resource_pattern: "tenant_console:skill_bindings",
        action: "update"
      })

    {:ok, skill} = Skills.get("pdf")
    assert {:ok, _skill} = Skills.set_all(actor_fixture(manager), "pdf", false, skill.revision)

    assert {:error, :skill_not_enabled} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "unreachable",
               Ankole.ActorRef.from_principal(agent)
             )

    assert {:ok, %AgentSkillLesson{retire_reason: :human_revoked}} =
             Library.retire_skill_lesson(agent.uid, pdf_lesson.id)

    assert {:error, :skill_lesson_already_retired} =
             Library.retire_skill_lesson(agent.uid, pdf_lesson.id)

    retired = agent.uid |> lessons() |> Enum.find(&(&1.skill_name == "pdf"))
    assert retired.retire_reason == :human_revoked
    assert %DateTime{} = retired.retired_at
  end

  defp lessons(agent_uid) do
    Ankole.AIAgent.list_agent_skill_lessons!(
      query: [filter: [agent_uid: agent_uid], sort: [skill_name: :asc]]
    )
  end

  test "skill lesson writes resolve cold AppConfigure defaults before opening a transaction" do
    %{principal: agent} = agent_fixture()

    Cache.clear_for_test()

    assert {:ok, %AgentSkillLesson{content: "Cold-cache guidance."}} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Cold-cache guidance.",
               Ankole.ActorRef.from_principal(agent)
             )
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

  test "source reader uses runtime roots, internal shadowing, and whole-package fingerprints" do
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
    assert Enum.map(sources, & &1.name) == ["public-only", "shadowed"]

    shadowed = Enum.find(sources, &(&1.name == "shadowed"))
    assert shadowed.description == "Internal description."
    assert shadowed.metadata["skill_root"] == "internal"
    assert Enum.map(shadowed.files, & &1.path) == ["SKILL.md", "references/guide.md"]
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "target/"))
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "node_modules/"))
    refute Enum.any?(shadowed.files, &String.starts_with?(&1.path, "__pycache__/"))

    assert Enum.find(shadowed.files, &(&1.path == "SKILL.md")).content =~ "# Internal"

    assert Enum.find(shadowed.files, &(&1.path == "references/guide.md")).content ==
             "original reference"

    File.write!(Path.join([internal_skill, "references", "guide.md"]), "changed reference")
    assert {:ok, sources_after_reference_change} = SourceReader.read_builtin_skill_sources()

    assert Enum.find(sources_after_reference_change, &(&1.name == "shadowed")).source_hash !=
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

    assert Enum.find(sources_after_skill_change, &(&1.name == "shadowed")).source_hash !=
             shadowed.source_hash

    assert Enum.find(sources_after_skill_change, &(&1.name == "shadowed")).metadata[
             "ankole-runtime"
           ] == "background_job"

    %{principal: agent} = agent_fixture()
    assert {:ok, runtime_skills} = Library.runtime_skills_for_agent(agent.uid)
    runtime_shadowed = Enum.find(runtime_skills, &(&1["skill_name"] == "shadowed"))
    assert runtime_shadowed["skill_root"] == "drive"
    refute Map.has_key?(runtime_shadowed["metadata"], "skill_root")

    with_library_config(
      library_root: Path.join(root, "library"),
      internal_skills_root: Path.join(root, "missing-internal")
    )

    assert {:ok, sources_without_internal} = SourceReader.read_builtin_skill_sources()
    assert Enum.map(sources_without_internal, & &1.name) == ["public-only", "shadowed"]

    assert Enum.find(sources_without_internal, &(&1.name == "shadowed")).description ==
             "Public description."
  end

  test "agent plugin and skill sources cache per library root within TTL while seed templates stay compiled" do
    root_a = tmp_library_root!("cache-root-a")
    root_b = tmp_library_root!("cache-root-b")
    library_a = Path.join(root_a, "library")
    library_b = Path.join(root_b, "library")

    write_skill!(Path.join([library_a, "skills", "alpha"]), "alpha", "Alpha skill.", "# Alpha")
    write_skill!(Path.join([library_b, "skills", "beta"]), "beta", "Beta skill.", "# Beta")
    write_agent_plugin!(library_a, "plugin-alpha", "plugin-alpha-skill")
    write_agent_plugin!(library_b, "plugin-beta", "plugin-beta-skill")

    previous = Application.get_env(:ankole, Ankole.AIAgent.Library, [])
    on_exit(fn -> Application.put_env(:ankole, Ankole.AIAgent.Library, previous) end)

    Application.put_env(:ankole, Ankole.AIAgent.Library,
      library_root: library_a,
      internal_skills_root: nil,
      source_cache_ttl_ms: 300_000
    )

    assert {:ok, [%{id: "plugin-alpha"}]} =
             AgentPlugins.SourceReader.read_trusted_agent_plugins()

    assert {:ok, [%{name: "alpha"}]} = SourceReader.read_builtin_skill_sources()

    File.rm_rf!(Path.join([library_a, "agent-plugins", "plugin-alpha"]))
    File.rm_rf!(Path.join([library_a, "skills", "alpha"]))

    assert {:ok, [%{id: "plugin-alpha"}]} =
             AgentPlugins.SourceReader.read_trusted_agent_plugins()

    assert {:ok, [%{name: "alpha"}]} = SourceReader.read_builtin_skill_sources()

    Application.put_env(:ankole, Ankole.AIAgent.Library,
      library_root: library_b,
      internal_skills_root: nil,
      source_cache_ttl_ms: 300_000
    )

    assert {:ok, [%{id: "plugin-beta"}]} =
             AgentPlugins.SourceReader.read_trusted_agent_plugins()

    assert {:ok, [%{name: "beta"}]} = SourceReader.read_builtin_skill_sources()

    # Personal Assistant seeding and document reads rely on compiled seed templates and
    # PostgreSQL contracts rather than reading `templates/*.md` from `library_root` on disk.
    refute File.exists?(Path.join(library_b, "templates"))
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    Ankole.PrincipalsFixtures.worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: pa}} = Ankole.Principals.ensure_personal_assistant(human.uid)

    assert {:ok, %{"agents" => %{"content" => agents_md}, "design" => %{"content" => design_md}}} =
             Library.list_agent_documents(pa.uid)

    assert agents_md != ""
    assert design_md != ""
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
