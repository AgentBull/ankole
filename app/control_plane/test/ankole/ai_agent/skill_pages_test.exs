defmodule Ankole.AIAgent.SkillsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{Skills, SourceReader}

  setup do
    root = Path.join(System.tmp_dir!(), "ankole-skills-#{System.unique_integer([:positive])}")
    directory = Path.join([root, "skills", "demo"])
    File.mkdir_p!(Path.join(directory, "scripts"))
    previous = Application.get_env(:ankole, Library, [])

    Application.put_env(:ankole, Library,
      library_root: root,
      internal_skills_root: nil,
      source_cache_ttl_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:ankole, Library, previous)
      File.rm_rf!(root)
    end)

    write_skill(directory, "Version one")
    File.write!(Path.join(directory, "scripts/run.sh"), "echo one\n")
    File.chmod!(Path.join(directory, "scripts/run.sh"), 0o755)
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    for action <- ["update", "delete"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "tenant_console:**",
          action: action
        })
    end

    assert {:ok, _} = Library.sync_agent_skills(agent.uid)
    assert {:ok, skill} = Skills.get("demo")
    %{directory: directory, agent: agent, skill: skill, actor: actor_fixture(human)}
  end

  test "runtime catalog reuses the package without rewriting or uploading", %{
    agent: agent,
    skill: skill
  } do
    count = Repo.aggregate(Ankole.Files.Schemas.FileObject, :count)
    assert {:ok, first} = Library.runtime_catalog_for_agent(agent.uid)
    assert {:ok, ^first} = Library.runtime_catalog_for_agent(agent.uid)
    assert {:ok, current} = Skills.get("demo")
    assert current.revision == skill.revision
    assert current.upstream_state == skill.upstream_state
    assert Repo.aggregate(Ankole.Files.Schemas.FileObject, :count) == count
  end

  test "a locally edited official script preserves the entire package on upgrade", ctx do
    assert {:ok, _} =
             Skills.put_file(ctx.actor, "demo", "scripts/run.sh", "echo local\n", %{
               base_revision: ctx.skill.revision,
               mode: 0o555
             })

    write_skill(ctx.directory, "Version two")
    File.write!(Path.join(ctx.directory, "scripts/run.sh"), "echo two\n")
    assert {:ok, sources} = SourceReader.read_builtin_skill_sources()
    assert {:ok, _} = Skills.sync(sources)
    assert {:ok, current} = Skills.get("demo")
    assert current.manifest_markdown =~ "Version one"
    refute current.manifest_markdown =~ "Version two"
    assert {:ok, "echo local\n"} = Skills.read(current, "scripts/run.sh")
    assert is_binary(current.upstream_state["pending_upstream_hash"])
  end

  test "upstream additions and removals preserve local references without inlining them", ctx do
    assert {:ok, _} =
             Skills.put_file(ctx.actor, "demo", "references/team.md", "Local reference", %{
               base_revision: ctx.skill.revision
             })

    File.rm!(Path.join(ctx.directory, "scripts/run.sh"))
    File.write!(Path.join(ctx.directory, "scripts/new.sh"), "echo new\n")
    write_skill(ctx.directory, "Version two")
    assert {:ok, _} = Library.sync_agent_skills(ctx.agent.uid)
    assert {:ok, current} = Skills.get("demo")
    assert {:error, :not_found} = Skills.read(current, "scripts/run.sh")
    assert {:ok, "echo new\n"} = Skills.read(current, "scripts/new.sh")
    assert {:ok, view} = Library.skill_view(ctx.agent.uid, "demo")
    assert view["content"] =~ "Version two"
    refute view["content"] =~ "Local reference"
    assert {:ok, reference} = Library.skill_view(ctx.agent.uid, "demo", "references/team.md")
    assert reference["content"] == "Local reference"
  end

  test "Agent capabilities survive requester changes and expose a whole enabled package", ctx do
    assert {:ok, _} =
             Skills.put_file(ctx.actor, "demo", "references/guide.md", "Package reference", %{
               base_revision: ctx.skill.revision
             })

    for human <- [human_fixture().principal, human_fixture().principal] do
      context = %{
        Ankole.Brain.Tools.Context.for_subject(ctx.agent.uid)
        | disclosure: %{mode: :strict, asker_uid: human.uid, present_uids: [human.uid]}
      }

      assert {:ok, view} =
               Library.skill_view(ctx.agent.uid, "demo", "references/guide.md",
                 request_context: context
               )

      assert view["content"] == "Package reference"
      assert {:ok, files} = Library.skill_bundle(ctx.agent.uid, "demo", request_context: context)
      assert Enum.any?(files, &(&1["path"] == "references/guide.md"))
    end
  end

  test "custom packages start disabled and global enable preserves positive individual bindings",
       ctx do
    assert {:ok, custom} = create(ctx.actor)
    refute custom.enabled_for_all
    assert Skills.bound_agents(custom.id) == []
    assert {:error, :skill_not_enabled} = Library.skill_view(ctx.agent.uid, custom.slug)

    assert {:ok, custom} =
             Skills.set_binding(ctx.actor, custom.slug, ctx.agent.uid, true)

    assert {:ok, custom} = Skills.set_all(ctx.actor, custom.slug, true, custom.revision)

    assert {:error, :skill_enabled_for_all} =
             Skills.set_binding(ctx.actor, custom.slug, ctx.agent.uid, false)

    assert {:ok, custom} = Skills.set_all(ctx.actor, custom.slug, false, custom.revision)
    assert Skills.bound_agents(custom.id) == [ctx.agent.uid]
    assert {:ok, _} = Library.skill_view(ctx.agent.uid, custom.slug)

    assert {:ok, _} =
             Skills.set_binding(ctx.actor, custom.slug, ctx.agent.uid, false)

    assert {:error, :skill_not_enabled} = Library.skill_view(ctx.agent.uid, custom.slug)
  end

  test "only an active member owner can control their assistant binding", ctx do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(owner.uid)
    assert {:ok, custom} = create(ctx.actor)

    assert {:error, :forbidden} =
             Skills.set_binding(ctx.actor, custom.slug, assistant.uid, true)

    assert {:error, :forbidden} =
             Skills.set_binding(
               actor_fixture(assistant),
               custom.slug,
               assistant.uid,
               true
             )

    assert {:ok, _} =
             Skills.set_binding(
               actor_fixture(owner),
               custom.slug,
               assistant.uid,
               true
             )
  end

  test "independent bindings preserve an editor's package revision", ctx do
    assert {:ok, custom} = create(ctx.actor)
    other = agent_fixture().principal
    assert {:ok, _} = Skills.set_binding(ctx.actor, custom.slug, ctx.agent.uid, true)
    assert {:ok, _} = Skills.set_binding(ctx.actor, custom.slug, other.uid, true)
    assert {:ok, unchanged} = Skills.get(custom.slug)
    assert unchanged.revision == custom.revision

    assert Skills.binding_summaries(ctx.actor, [custom])[custom.id] == %{
             colleague_count: 2,
             assistant_enabled: false,
             agent_uids: Enum.sort([ctx.agent.uid, other.uid])
           }

    assert Enum.sort(Skills.bound_agents(custom.id)) == Enum.sort([ctx.agent.uid, other.uid])

    assert {:ok, saved} =
             Skills.save(ctx.actor, custom.slug, %{
               base_revision: custom.revision,
               manifest_xml: "<page><p>Edited while others enable the package.</p></page>",
               metadata: custom.metadata
             })

    assert saved.revision == custom.revision + 1
  end

  test "a newly shipped name preserves the custom package and its management entry", ctx do
    assert {:ok, custom} = create(ctx.actor)
    directory = Path.join(Path.dirname(ctx.directory), custom.slug)
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "SKILL.md"),
      "---\nname: custom-demo\ndescription: New upstream package\n---\nUpstream body\n"
    )

    assert {:ok, skills} = Skills.list(ctx.actor)
    assert Enum.any?(skills, &(&1.id == custom.id and &1.source_kind == :custom))
    assert {:ok, %{skill: current}} = Skills.detail(ctx.actor, custom.slug)
    assert current.manifest_xml == custom.manifest_xml
  end

  test "renaming a custom package preserves its lessons", ctx do
    assert {:ok, custom} = create(ctx.actor)
    assert {:ok, _} = Skills.set_binding(ctx.actor, custom.slug, ctx.agent.uid, true)

    assert {:ok, lesson} =
             Repo.transact(fn ->
               Ankole.Ash.create(Library.Schemas.AgentSkillLesson, :teach_human, %{
                 agent_uid: ctx.agent.uid,
                 skill_name: custom.slug,
                 content: "Check the source date."
               })
             end)

    assert {:ok, renamed} =
             Skills.save(ctx.actor, custom.slug, %{
               slug: "renamed-demo",
               base_revision: custom.revision,
               manifest_xml: custom.manifest_xml,
               metadata: custom.metadata
             })

    assert {:ok, lessons} = Library.SkillLessons.active_skill_lessons(ctx.agent.uid)
    assert Enum.any?(lessons, &(&1.id == lesson.id and &1.skill_name == renamed.slug))

    assert {:ok, _} = Skills.delete(ctx.actor, renamed.slug, renamed.revision)
    assert {:ok, []} = Library.SkillLessons.active_skill_lessons(ctx.agent.uid)

    assert %{retire_reason: :obsolete, retired_at: %DateTime{}} =
             Repo.get_by!(Library.Schemas.AgentSkillLesson, id: lesson.id)

    assert {:ok, _} =
             Skills.create(ctx.actor, %{
               slug: renamed.slug,
               manifest_xml: custom.manifest_xml,
               metadata: custom.metadata
             })

    assert {:ok, []} = Library.SkillLessons.active_skill_lessons(ctx.agent.uid)
  end

  test "every package edit uses one revision and the required manifest cannot become an attachment",
       ctx do
    assert {:ok, custom} = create(ctx.actor)

    assert {:ok, saved} =
             Skills.put_file(ctx.actor, custom.slug, "assets/data.bin", <<0, 1, 255>>, %{
               base_revision: custom.revision
             })

    assert saved.revision == custom.revision + 1

    assert {:error, :stale} =
             Skills.put_file(ctx.actor, custom.slug, "assets/data.bin", "lost", %{
               base_revision: custom.revision
             })
             |> Ankole.Errors.reason()

    assert {:ok, <<0, 1, 255>>} = Skills.read(saved, "assets/data.bin")

    assert {:error, :required_manifest} =
             Skills.change_file(ctx.actor, custom.slug, "SKILL.md", %{
               base_revision: saved.revision
             })

    assert {:ok, renamed} =
             Skills.change_file(ctx.actor, custom.slug, "assets/data.bin", %{
               base_revision: saved.revision,
               new_path: "assets/renamed.bin"
             })

    assert {:error, :not_found} = Skills.read(renamed, "assets/data.bin")
    assert {:ok, <<0, 1, 255>>} = Skills.read(renamed, "assets/renamed.bin")

    assert {:error, :stale} =
             Skills.delete(ctx.actor, custom.slug, saved.revision) |> Ankole.Errors.reason()

    assert {:ok, _} = Skills.delete(ctx.actor, custom.slug, renamed.revision)
    assert {:error, :not_found} = Skills.get(custom.slug)
  end

  test "official identifiers cannot be renamed or deleted", ctx do
    assert {:error, :official_skill} = Skills.delete(ctx.actor, "demo", ctx.skill.revision)

    assert {:error, :official_skill} =
             Skills.save(ctx.actor, "demo", %{slug: "changed", base_revision: ctx.skill.revision})
  end

  test "package edits keep every file reachable without file-directory collisions", ctx do
    assert {:ok, custom} = create(ctx.actor)

    assert {:ok, custom} =
             Skills.put_file(ctx.actor, custom.slug, "scripts/run.sh", "run", %{
               base_revision: custom.revision
             })

    assert {:ok, custom} =
             Skills.put_file(ctx.actor, custom.slug, "guide.md", "guide", %{
               base_revision: custom.revision
             })

    for path <- ["scripts", "scripts/run.sh/nested", "SKILL.md/nested"] do
      assert {:error, :skill_path_conflict} =
               Skills.put_file(ctx.actor, custom.slug, path, "collision", %{
                 base_revision: custom.revision
               })

      assert {:error, :skill_path_conflict} =
               Skills.change_file(ctx.actor, custom.slug, "guide.md", %{
                 base_revision: custom.revision,
                 new_path: path
               })

      assert {:ok, %{revision: revision}} = Skills.get(custom.slug)
      assert revision == custom.revision
    end

    assert {:ok, "guide"} = Skills.read(custom, "guide.md")
    assert {:ok, "run"} = Skills.read(custom, "scripts/run.sh")

    assert {:ok, custom} =
             Skills.change_file(ctx.actor, custom.slug, "scripts/run.sh", %{
               base_revision: custom.revision,
               new_path: "scripts"
             })

    assert {:ok, "run"} = Skills.read(custom, "scripts")

    assert {:error, :skill_path_conflict} =
             Skills.put_file(ctx.actor, custom.slug, "scripts/new.sh", "collision", %{
               base_revision: custom.revision
             })

    assert {:ok, custom} =
             Skills.put_file(ctx.actor, custom.slug, "scripts", "replacement", %{
               base_revision: custom.revision
             })

    assert {:ok, "replacement"} = Skills.read(custom, "scripts")
  end

  test "an upstream directory colliding with a local file freezes the entire package", ctx do
    assert {:ok, _} =
             Skills.put_file(ctx.actor, "demo", "references", "Local file", %{
               base_revision: ctx.skill.revision
             })

    File.mkdir!(Path.join(ctx.directory, "references"))
    File.write!(Path.join(ctx.directory, "references/new.md"), "Upstream reference")
    write_skill(ctx.directory, "Version two")

    assert {:ok, _} = Library.sync_agent_skills(ctx.agent.uid)
    assert {:ok, current} = Skills.get("demo")
    assert current.manifest_markdown =~ "Version one"
    assert {:ok, "Local file"} = Skills.read(current, "references")
    assert {:error, :not_found} = Skills.read(current, "references/new.md")
    assert is_binary(current.upstream_state["pending_upstream_hash"])
    assert {:ok, _} = Library.sync_agent_skills(ctx.agent.uid)
    assert {:ok, %{revision: revision}} = Skills.get("demo")
    assert revision == current.revision
  end

  test "upstream can replace an unmodified managed directory with a file and back", ctx do
    File.rm_rf!(Path.join(ctx.directory, "scripts"))
    File.write!(Path.join(ctx.directory, "scripts"), "Flat upstream file")
    assert {:ok, _} = Library.sync_agent_skills(ctx.agent.uid)
    assert {:ok, current} = Skills.get("demo")
    assert {:ok, "Flat upstream file"} = Skills.read(current, "scripts")
    assert {:error, :not_found} = Skills.read(current, "scripts/run.sh")

    File.rm!(Path.join(ctx.directory, "scripts"))
    File.mkdir!(Path.join(ctx.directory, "scripts"))
    File.write!(Path.join(ctx.directory, "scripts/run.sh"), "echo new")
    assert {:ok, _} = Library.sync_agent_skills(ctx.agent.uid)
    assert {:ok, current} = Skills.get("demo")
    assert {:ok, "echo new"} = Skills.read(current, "scripts/run.sh")
    assert {:error, :not_found} = Skills.read(current, "scripts")
  end

  test "ZIP import rejects an attachment over the object-store per-file ceiling", ctx do
    previous = Application.fetch_env!(:ankole, Ankole.ObjectStore)
    cached = :persistent_term.get({Ankole.ObjectStore, :store}, nil)

    Application.put_env(:ankole, Ankole.ObjectStore,
      spec: %{
        scheme: "d1",
        account_id: "account",
        database_id: "database",
        token: "token",
        table: "objects",
        key_field: "key",
        value_field: "value"
      }
    )

    :persistent_term.erase({Ankole.ObjectStore, :store})

    on_exit(fn ->
      Application.put_env(:ankole, Ankole.ObjectStore, previous)

      if cached,
        do: :persistent_term.put({Ankole.ObjectStore, :store}, cached),
        else: :persistent_term.erase({Ankole.ObjectStore, :store})
    end)

    assert {:ok, limit} = Ankole.Files.upload_limit()
    size = limit + 1
    object_count = Repo.aggregate(Ankole.Files.Schemas.FileObject, :count)

    {:ok, {_, archive}} =
      :zip.create(
        ~c"oversized.zip",
        [
          {~c"SKILL.md", "---\nname: Large\ndescription: Large attachment\n---\nInstructions"},
          {~c"references/data.txt", String.duplicate("x", size)}
        ],
        [:memory]
      )

    assert byte_size(archive) < limit

    assert {:error, {:file_too_large, ^size, ^limit}} =
             Skills.import(ctx.actor, "oversized", archive)

    assert {:error, :not_found} = Skills.get("oversized")
    assert Repo.aggregate(Ankole.Files.Schemas.FileObject, :count) == object_count
  end

  test "ZIP import rejects a file that would hide another package entry atomically", ctx do
    {:ok, {_, archive}} =
      :zip.create(
        ~c"conflict.zip",
        [
          {~c"SKILL.md", "---\nname: Conflict\ndescription: Collision\n---\nRead scripts/run.sh"},
          {~c"scripts", "file"},
          {~c"scripts/run.sh", "run"}
        ],
        [:memory]
      )

    assert {:error, :skill_path_conflict} = Skills.import(ctx.actor, "conflict", archive)
    assert {:error, :not_found} = Skills.get("conflict")
  end

  test "ZIP import preserves binary files independently of the VFS upload ceiling", ctx do
    key = "drive.vfs_max_upload_bytes"
    {:ok, previous} = Ankole.AppConfigure.get_by_key(key)
    on_exit(fn -> Ankole.AppConfigure.put_global_by_key(key, previous) end)
    assert {:ok, _} = Ankole.AppConfigure.put_global_by_key(key, 1024)

    binary = :binary.copy(<<0, 255, 1>>, 350)
    script = "#!/usr/bin/env node\nconsole.log('imported')\n"

    info =
      %{File.stat!(__ENV__.file) | size: byte_size(script), type: :regular, mode: 0o755}
      |> File.Stat.to_record()

    {:ok, {_, archive}} =
      :zip.create(
        ~c"skill.zip",
        [
          {~c"package/SKILL.md",
           "---\nname: Imported\ndescription: An imported package\n---\nRead assets/data.bin"},
          {~c"package/assets/data.bin", binary},
          {~c"package/scripts/run", script, info},
          {~c"package/templates/SKILL.md", "A template included as a package asset."},
          {~c"__MACOSX/package/._SKILL.md", "Finder metadata"},
          {~c"package/.DS_Store", "Finder metadata"}
        ],
        [:memory]
      )

    assert {:ok, custom} = Skills.import(ctx.actor, "imported", archive)
    assert custom.name == "Imported"
    refute custom.enabled_for_all
    assert {:ok, ^binary} = Skills.read(custom, "assets/data.bin")
    assert {:ok, %{mode: 0o555}} = Skills.file(custom.id, "scripts/run")
    assert {:ok, ^script} = Skills.read(custom, "scripts/run")

    assert {:ok, "A template included as a package asset."} =
             Skills.read(custom, "templates/SKILL.md")
  end

  defp create(actor),
    do:
      Skills.create(actor, %{
        slug: "custom-demo",
        manifest_xml: "<page><p>Custom instruction.</p></page>",
        metadata: %{"name" => "Custom demo", "description" => "Use the custom workflow."}
      })

  defp write_skill(directory, body),
    do:
      File.write!(
        Path.join(directory, "SKILL.md"),
        "---\nname: demo\ndescription: Demo work.\ndefault_enabled: true\n---\n#{body}\n"
      )
end
