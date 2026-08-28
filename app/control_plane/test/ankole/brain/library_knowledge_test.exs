defmodule Ankole.Brain.LibraryKnowledgeTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.Forget
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Promotion
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SelfHealing
  alias Ankole.Ecto.UUIDv7

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    dir =
      Path.join(
        System.tmp_dir!(),
        "ankole-knowledge-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "concepts"))
    on_exit(fn -> File.rm_rf!(dir) end)

    set_id = "test-set-#{System.unique_integer([:positive])}"

    %{
      dir: dir,
      set: %{kind: :knowledge, set_id: set_id, name: "Test knowledge", dir: dir}
    }
  end

  defp write_page!(dir, name, body_extra \\ "") do
    File.write!(Path.join(dir, "concepts/#{name}.md"), """
    ---
    slug: concepts/#{name}
    type: concept
    title: #{name}
    aliases:
      - #{name} alias
    ---

    # #{name}

    Shipped methodology content.#{body_extra}
    """)
  end

  defp sync!(set) do
    {:ok, report} = LibraryKnowledge.sync(sets: [set])
    report
  end

  defp lazy_skill_set(name \\ "voice-drafting-method") do
    %{
      kind: :lazy_skills,
      set_id: "lazy-skills-test",
      name: "Lazy Skill test inventory",
      skills: [
        %{
          name: name,
          description: "Draft from verified first-party voice evidence.",
          metadata: %{"tags" => ["ghostwriting", "代笔"]},
          source_hash: "skill-source-v1",
          files: [%{path: "SKILL.md", content: "FULL SKILL BODY MUST NOT ENTER BRAIN"}]
        }
      ]
    }
  end

  defp write_lazy_skill!(dir, name) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: Lazy Skill inventory test.
    brain-recall-only: true
    ---

    # Lazy Skill
    """)
  end

  defp write_agent_plugin!(library_root, plugin_id, skill_name) do
    plugin_root = Path.join([library_root, "agent-plugins", plugin_id])
    write_lazy_skill!(Path.join([plugin_root, "skills", skill_name]), skill_name)
    File.mkdir_p!(Path.join(plugin_root, ".codex-plugin"))

    File.write!(
      Path.join([plugin_root, ".codex-plugin", "plugin.json"]),
      Ankole.JSON.encode!(%{
        "name" => plugin_id,
        "version" => "1.0.0",
        "description" => "Lazy Skill conflict test Plugin.",
        "skills" => "./skills/"
      })
    )
  end

  defp with_library_root(root) do
    previous = Application.get_env(:ankole, Ankole.AIAgent.Library, [])

    Application.put_env(
      :ankole,
      Ankole.AIAgent.Library,
      Keyword.merge(previous,
        library_root: root,
        internal_skills_root: nil,
        source_cache_ttl_ms: 0
      )
    )

    on_exit(fn -> Application.put_env(:ankole, Ankole.AIAgent.Library, previous) end)
  end

  defp pending_type_suggestion(term) do
    Repo.insert!(%SchemaSuggestion{
      id: UUIDv7.autogenerate(),
      kind: "new_type",
      term: term,
      evidence_count: 100,
      rationale: "test evidence",
      status: "pending",
      created_at: DateTime.utc_now(:microsecond)
    })
  end

  test "projects pages as managed world objects with chunks and aliases", %{
    dir: dir,
    set: set
  } do
    write_page!(dir, "alpha-method")

    report = sync!(set)
    assert [%{status: :ok, projected: 1, rejected: 0}] = report.reports

    object = Repo.get_by!(Object, slug: "concepts/alpha-method")
    source = Repo.get_by!(Source, kind: "library", upstream_id: set.set_id)
    assert object.managed_by_source_id == source.id
    assert source.upstream_revision != nil

    chunks = Repo.all(from chunk in Chunk, where: chunk.object_id == ^object.id)
    assert chunks != []
    assert Enum.all?(chunks, &(&1.audience_scope == "world"))

    assert Repo.get_by(ObjectAlias, object_slug: "concepts/alpha-method")
  end

  test "one union sweep projects knowledge and lazy Skill metadata without copying Skill bodies",
       %{
         dir: dir,
         set: knowledge_set
       } do
    write_page!(dir, "sweep-method")
    skill_set = lazy_skill_set()

    assert {:ok, %{sets: 2, withdrawn_sets: []}} =
             LibraryKnowledge.sync(sets: [knowledge_set, skill_set])

    object = Repo.get_by!(Object, slug: "lazyload-agent-skills/voice-drafting-method")
    assert object.type == "agent-skills"
    assert object.title == "voice-drafting-method"
    assert object.body =~ "voice-drafting-method"
    assert object.body =~ "verified first-party voice evidence"
    assert object.body =~ "ghostwriting, 代笔"
    refute object.body =~ "FULL SKILL BODY"

    assert Chunk
           |> where([chunk], chunk.object_id == ^object.id)
           |> Repo.one!()
           |> Map.fetch!(:chunk_text) =~ "ghostwriting"

    aliases =
      ObjectAlias
      |> where([object_alias], object_alias.object_slug == ^object.slug)
      |> select([object_alias], object_alias.alias_norm)
      |> Repo.all()

    assert "voice-drafting-method" in aliases
    assert "ghostwriting" in aliases
    assert "代笔" in aliases

    assert {:ok, %{withdrawn_sets: []}} =
             LibraryKnowledge.sync(sets: [knowledge_set, skill_set])

    assert Repo.get_by!(Object, slug: "concepts/sweep-method").deleted_at == nil
    assert Repo.get_by!(Object, slug: object.slug).deleted_at == nil
  end

  test "a failed lazy Skill inventory keeps the previous projection live" do
    allow_cache_database_access()

    root =
      Path.join(
        System.tmp_dir!(),
        "ankole-lazy-inventory-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "skills"))
    on_exit(fn -> File.rm_rf!(root) end)
    with_library_root(root)

    name = "inventory-conflict"
    slug = "lazyload-agent-skills/#{name}"
    write_lazy_skill!(Path.join([root, "skills", name]), name)

    assert {:ok, %{withdrawn_sets: []}} = LibraryKnowledge.sync()
    assert Repo.get_by!(Object, slug: slug).deleted_at == nil

    write_agent_plugin!(root, "inventory-conflict-plugin", name)

    assert {:error, {:skill_source_name_conflicts, [^name]}} = LibraryKnowledge.sync()
    assert Repo.get_by!(Object, slug: slug).deleted_at == nil
  end

  test "self-healing reports a failed Skill inventory and continues later repairs" do
    allow_cache_database_access()

    root =
      Path.join(
        System.tmp_dir!(),
        "ankole-self-healing-inventory-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "skills"))
    on_exit(fn -> File.rm_rf!(root) end)
    with_library_root(root)

    name = "self-healing-inventory-conflict"
    write_lazy_skill!(Path.join([root, "skills", name]), name)
    write_agent_plugin!(root, "self-healing-inventory-plugin", name)

    {:ok, object} =
      Objects.create_object(
        %{slug: "notes/self-healing-probe", type: "note", title: "Self-healing probe"},
        :system
      )

    object
    |> Ecto.Changeset.change(chunking_signature: nil)
    |> Repo.update!()

    {result, log} = with_log(fn -> SelfHealing.sweep() end)

    assert {:ok, report} = result

    assert report.library_knowledge == %{
             status: :error,
             reason: inspect({:skill_source_name_conflicts, [name]})
           }

    assert report.rechunked >= 1

    assert Repo.get!(Object, object.id).chunking_signature ==
             Chunker.signature(Config.chunking())

    assert log =~ "library knowledge synchronization failed"
  end

  test "ordinary writes and generic OKF projection cannot create agent-skills Objects", %{
    dir: dir,
    set: set
  } do
    assert {:error, {:reserved_object_type, "agent-skills"}} =
             Objects.create_object(
               %{
                 slug: "concepts/forged-agent-skill",
                 type: "agent-skills",
                 title: "Forged"
               },
               :system
             )

    assert {:error, {:reserved_object_slug, "lazyload-agent-skills/forged"}} =
             Objects.create_object(
               %{
                 slug: "lazyload-agent-skills/forged",
                 type: "note",
                 title: "Forged"
               },
               :system
             )

    assert {:error, {:unknown_object_type, "invented", guidance}} =
             Objects.create_object(
               %{slug: "invented/example", type: "invented", title: "Invented"},
               :system
             )

    refute "agent-skills" in guidance.installed_types

    File.write!(Path.join(dir, "concepts/forged.md"), """
    ---
    slug: lazyload-agent-skills/forged
    type: concept
    title: Forged
    ---

    Body.
    """)

    assert [%{rejected: 1, projected: 0}] = sync!(set).reports
    refute Repo.get_by(Object, slug: "lazyload-agent-skills/forged")
  end

  test "an unchanged set is a no-op and a changed file re-projects", %{dir: dir, set: set} do
    write_page!(dir, "beta-method")
    assert [%{projected: 1}] = sync!(set).reports
    assert [%{projected: 0, unchanged: 1}] = sync!(set).reports

    write_page!(dir, "beta-method", "\n\nRevised body.")
    assert [%{projected: 1, unchanged: 0}] = sync!(set).reports
    assert Repo.get_by!(Object, slug: "concepts/beta-method").body =~ "Revised body."
  end

  test "an instance-owned row shadows the projection at its slug", %{dir: dir, set: set} do
    %{principal: human} = human_fixture()

    {:ok, _object} =
      Objects.create_object(
        %{slug: "concepts/gamma-method", type: "concept", title: "Mine", body: "Instance body."},
        human.uid
      )

    write_page!(dir, "gamma-method")
    assert [%{shadowed: 1, projected: 0}] = sync!(set).reports
    assert Repo.get_by!(Object, slug: "concepts/gamma-method").body == "Instance body."
  end

  test "fork clears the marker and later syncs shadow the forked page", %{dir: dir, set: set} do
    write_page!(dir, "delta-method")
    sync!(set)

    assert {:ok, forked} = Objects.fork_library_page("concepts/delta-method")
    assert forked.managed_by_source_id == nil
    assert {:error, :not_library_managed} = Objects.fork_library_page("concepts/delta-method")

    write_page!(dir, "delta-method", "\n\nUpstream revision after fork.")
    assert [%{shadowed: 1}] = sync!(set).reports
    refute Repo.get_by!(Object, slug: "concepts/delta-method").body =~ "after fork"
  end

  test "lazy Skill projections cannot fork into instance ownership" do
    assert {:ok, _report} = LibraryKnowledge.sync(sets: [lazy_skill_set()])

    slug = "lazyload-agent-skills/voice-drafting-method"
    object = Repo.get_by!(Object, slug: slug)
    assert object.managed_by_source_id != nil

    assert {:error, {:reserved_object_type, "agent-skills"}} =
             Objects.fork_library_page(slug)

    assert Repo.get_by!(Object, slug: slug).managed_by_source_id == object.managed_by_source_id
  end

  test "schema promotion cannot claim the lazy Skill route or retype its managed pages" do
    assert {:ok, _report} = LibraryKnowledge.sync(sets: [lazy_skill_set()])
    %{principal: human} = human_fixture()

    reserved_route = pending_type_suggestion("reserved-route")

    assert {:error, {:reserved_object_slug_prefix, "lazyload-agent-skills/"}} =
             Promotion.approve(reserved_route.id, human.uid,
               slug_prefix: "lazyload-agent-skills/"
             )

    slug = "lazyload-agent-skills/voice-drafting-method"
    assert {:ok, _tag} = Links.add_tag(slug, "methodology")
    methodology = pending_type_suggestion("methodology")

    assert {:ok, %{status: :type_created, type: "methodology", migrated: 0}} =
             Promotion.approve(methodology.id, human.uid)

    projected = Repo.get_by!(Object, slug: slug)
    assert projected.type == "agent-skills"
    assert projected.managed_by_source_id != nil
  end

  test "instance edits to a managed page are refused; periphery is open", %{dir: dir, set: set} do
    write_page!(dir, "epsilon-method")
    sync!(set)
    %{principal: human} = human_fixture()

    assert {:error, {:library_managed, _slug, _hint}} =
             Objects.update_object(
               "concepts/epsilon-method",
               %{body: "edited", expected_content_hash: "x"},
               human.uid
             )

    assert {:error, {:library_managed, _slug, _hint}} =
             Forget.forget_object("concepts/epsilon-method", "cleanup", human.uid)

    assert {:error, {:library_managed, _slug, _hint}} =
             Objects.restore("concepts/epsilon-method")

    assert {:ok, _timeline} =
             Ankole.Brain.Timelines.write_timeline(
               %{
                 object_slug: "concepts/epsilon-method",
                 date: ~D[2026-08-28],
                 summary: "Instance event on a shipped page",
                 provenance: "test",
                 audience_scope: "world"
               },
               human.uid
             )
  end

  test "a removed file withdraws its page, purge spares it, and its return restores it", %{
    dir: dir,
    set: set
  } do
    write_page!(dir, "zeta-method")
    sync!(set)

    File.rm!(Path.join(dir, "concepts/zeta-method.md"))
    assert [%{withdrawn: 1}] = sync!(set).reports

    withdrawn = Repo.get_by!(Object, slug: "concepts/zeta-method")
    assert withdrawn.deleted_at != nil

    # Purge hard-deletes ordinary soft-deleted objects past the TTL but must
    # spare managed rows: the periphery on the slug survives withdrawal.
    old = DateTime.add(DateTime.utc_now(), -14, :day)

    Repo.update_all(from(o in Object, where: o.slug == "concepts/zeta-method"),
      set: [deleted_at: old]
    )

    assert %{status: :ok} = Dreaming.phase_purge()
    assert Repo.get_by(Object, slug: "concepts/zeta-method")

    write_page!(dir, "zeta-method")
    assert [%{projected: 1}] = sync!(set).reports
    assert Repo.get_by!(Object, slug: "concepts/zeta-method").deleted_at == nil
  end

  test "an archived library source withdraws the whole set", %{dir: dir, set: set} do
    write_page!(dir, "eta-method")
    sync!(set)

    source = Repo.get_by!(Source, kind: "library", upstream_id: set.set_id)

    {:ok, _archived} =
      source
      |> Source.changeset(%{archived_at: DateTime.utc_now(:microsecond)})
      |> Repo.update()

    assert [%{status: :archived, withdrawn: 1}] = sync!(set).reports
    assert Repo.get_by!(Object, slug: "concepts/eta-method").deleted_at != nil
  end

  test "a missing set withdraws through the source registry", %{dir: dir, set: set} do
    write_page!(dir, "theta-method")
    sync!(set)

    {:ok, report} = LibraryKnowledge.sync(sets: [])
    assert [%{withdrawn: 1}] = report.withdrawn_sets
    assert Repo.get_by!(Object, slug: "concepts/theta-method").deleted_at != nil
  end

  test "rejects an uninstalled type, an audience tag, and a duplicate slug", %{
    dir: dir,
    set: set
  } do
    File.write!(Path.join(dir, "concepts/bad-type.md"), """
    ---
    slug: concepts/bad-type
    type: starship
    title: Bad type
    ---

    Body.
    """)

    File.write!(Path.join(dir, "concepts/bad-scope.md"), """
    ---
    slug: concepts/bad-scope
    type: concept
    title: Bad scope
    ---

    {% audience scope="world" %}shipped pages are world-only{% /audience %}
    """)

    write_page!(dir, "dup-method")

    File.write!(Path.join(dir, "concepts/dup-method-second.md"), """
    ---
    slug: concepts/dup-method
    type: concept
    title: Duplicate
    ---

    Body.
    """)

    report = sync!(set)
    assert [%{projected: 1, rejected: 3}] = report.reports
    refute Repo.get_by(Object, slug: "concepts/bad-type")
    refute Repo.get_by(Object, slug: "concepts/bad-scope")
  end
end
