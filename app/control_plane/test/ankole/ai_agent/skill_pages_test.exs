defmodule Ankole.AIAgent.SkillPagesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{Knowledge, SkillPages, SourceReader}
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.{Files, Pod, Repo}

  setup do
    root =
      Path.join(System.tmp_dir!(), "ankole-shared-skills-#{System.unique_integer([:positive])}")

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
    %{principal: agent} = agent_fixture()
    assert {:ok, _} = Library.sync_agent_skills(agent.uid)
    {:ok, root_node} = Knowledge.system_node("ankole_brain_skills")
    {:ok, skill} = Knowledge.child(root_node.id, "demo")
    %{directory: directory, agent: agent, skill: skill}
  end

  test "repeated runtime catalogs reuse the package fingerprint without uploading or rewriting",
       %{
         agent: agent,
         skill: skill
       } do
    object_count = Repo.aggregate(Ankole.Files.Schemas.FileObject, :count)
    {:ok, before} = Ankole.Pod.Pages.fetch(skill.id)
    {:ok, first} = Library.runtime_catalog_for_agent(agent.uid)
    {:ok, second} = Library.runtime_catalog_for_agent(agent.uid)
    {:ok, after_read} = Ankole.Pod.Pages.fetch(skill.id)

    assert first == second
    assert Repo.aggregate(Ankole.Files.Schemas.FileObject, :count) == object_count
    assert after_read.revision == before.revision
    assert after_read.upstream_state == before.upstream_state
  end

  test "editing only an official script preserves the complete local package on upgrade", %{
    directory: directory,
    skill: skill
  } do
    {:ok, scripts} = Knowledge.child(skill.id, "scripts")
    {:ok, script} = Knowledge.child(scripts.id, "run.sh")
    {:ok, stored} = Files.store("echo local\n")

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, object} <- Files.complete_object_in_tx(stored),
             do: Nodes.update_in_tx(script, :content, %{object_id: object.id})
      end)

    write_skill(directory, "Version two")
    File.write!(Path.join(directory, "scripts/run.sh"), "echo two\n")
    assert {:ok, sources} = SourceReader.read_builtin_skill_sources()
    assert {:ok, _} = SkillPages.sync(sources)
    assert {:ok, markdown} = Ankole.Pod.Knowledge.export(skill.id)
    assert markdown =~ "Version one"
    refute markdown =~ "Version two"
    {:ok, current} = Nodes.fetch(script.id)
    assert {:ok, "echo local\n"} = Files.read_object(current.object_id)
    {:ok, %{page: page}} = Ankole.Pod.Knowledge.read_in_tx(skill.id)
    assert is_binary(page.upstream_state["pending_upstream_hash"])
  end

  @tag sandbox: false
  test "an in-flight script edit wins over an upstream package reconciliation", %{
    directory: directory,
    skill: skill
  } do
    {:ok, scripts} = Knowledge.child(skill.id, "scripts")
    {:ok, script} = Knowledge.child(scripts.id, "run.sh")
    {:ok, stored} = Files.store("echo concurrent local\n")
    {:ok, object} = Repo.transact_top_level(fn -> Files.complete_object_in_tx(stored) end)
    parent = self()

    writer =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact_top_level(fn ->
            {:ok, locked} = Nodes.lock(script.id)
            {:ok, _} = Nodes.update_in_tx(locked, :content, %{object_id: object.id})
            send(parent, {:script_edited, backend_pid()})

            receive do
              :commit -> {:ok, :written}
            after
              5_000 -> {:error, :commit_timeout}
            end
          end)
        end)
      )

    assert_receive {:script_edited, writer_pid}, 5_000
    write_skill(directory, "Version two")
    File.write!(Path.join(directory, "scripts/run.sh"), "echo upstream\n")
    {:ok, sources} = SourceReader.read_builtin_skill_sources()

    sync =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:sync_started, backend_pid()})
            SkillPages.sync(sources)
          end)
        end)
      )

    try do
      assert_receive {:sync_started, sync_pid}, 5_000
      await_blocker(sync_pid, writer_pid, System.monotonic_time(:millisecond) + 5_000)
      send(writer.pid, :commit)
      assert {:ok, :written} = Task.await(writer, 5_000)
      assert {:ok, _} = Task.await(sync, 5_000)
      {:ok, current} = Nodes.fetch(script.id)
      assert {:ok, "echo concurrent local\n"} = Files.read_object(current.object_id)
      assert {:ok, markdown} = Ankole.Pod.Knowledge.export(skill.id)
      assert markdown =~ "Version one"
    after
      send(writer.pid, :commit)
    end
  end

  test "upstream file additions and removals preserve tenant supplement pages", %{
    directory: directory,
    skill: skill,
    agent: agent
  } do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Knowledge.ensure_child_in_tx(skill.id, "Team rule", :knowledge),
             do: Knowledge.put_markdown_in_tx(page, "Always include a dated source.")
      end)

    File.rm!(Path.join(directory, "scripts/run.sh"))
    File.write!(Path.join(directory, "scripts/new.sh"), "echo new\n")
    write_skill(directory, "Version two")
    assert {:ok, _} = Library.sync_agent_skills(agent.uid)
    {:ok, scripts} = Knowledge.child(skill.id, "scripts")
    assert {:error, :not_found} = Knowledge.child(scripts.id, "run.sh")
    assert {:ok, _} = Knowledge.child(scripts.id, "new.sh")
    assert {:ok, view} = Library.skill_view(agent.uid, "demo")
    assert view["content"] =~ "Version two"
    assert view["content"] =~ "Always include a dated source."
  end

  test "skill reads and bundles use the same requester intersection for restricted supplements",
       %{skill: skill, agent: agent} do
    %{principal: allowed} = human_fixture()
    %{principal: other} = human_fixture()

    {:ok, secret} =
      Repo.transact_top_level(fn ->
        with {:ok, page} <-
               Knowledge.ensure_child_in_tx(skill.id, "Purchasing rules", :knowledge,
                 inherit_permissions: false
               ),
             :ok <-
               Access.put_role(%{principal_uid: allowed.uid}, "drive:**:#{page.id}:**", "view"),
             :ok <- Access.put_role(%{principal_uid: agent.uid}, "drive:**:#{page.id}:**", "view"),
             do: Knowledge.put_markdown_in_tx(page, "Minimum purchase price is 42.")
      end)

    for {human, visible} <- [{allowed, true}, {other, false}] do
      context = %{
        Ankole.Brain.Tools.Context.for_subject(agent.uid)
        | disclosure: %{mode: :relaxed, asker_uid: human.uid, present_uids: []}
      }

      assert {:ok, view} = Library.skill_view(agent.uid, "demo", nil, request_context: context)
      assert String.contains?(view["content"], "Minimum purchase price") == visible
      assert {:ok, files} = Library.skill_bundle(agent.uid, "demo", request_context: context)

      assert Enum.any?(
               files,
               &String.contains?(Base.decode64!(&1["content"]), "Minimum purchase price")
             ) == visible
    end

    assert secret.type == :knowledge
  end

  test "reference pages remain available by subpath without inflating inline instructions", %{
    skill: skill,
    agent: agent
  } do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, page} <-
               Knowledge.ensure_child_in_tx(skill.id, "Detailed reference", :knowledge),
             do:
               Knowledge.put_markdown_in_tx(page, "---\nrole: reference\n---\nLarge lookup table")
      end)

    assert {:ok, view} = Library.skill_view(agent.uid, "demo")
    refute view["content"] =~ "Large lookup table"
    assert {:ok, reference} = Library.skill_view(agent.uid, "demo", "Detailed reference.md")
    assert reference["content"] =~ "Large lookup table"
    assert {:ok, files} = Library.skill_bundle(agent.uid, "demo")
    assert Enum.any?(files, &(&1["path"] == "Detailed reference.md"))
  end

  test "a human's Pod correction is used by another member's next Skill read and job bundle", %{
    skill: skill
  } do
    %{principal: editor} = human_fixture()
    %{principal: newcomer} = human_fixture()
    %{principal: colleague} = agent_fixture()

    {:ok, :ok} =
      Repo.transact_top_level(fn ->
        :ok = Access.put_role(%{principal_uid: editor.uid}, "drive:**:#{skill.id}:**", "edit")
        {:ok, :ok}
      end)

    actor = actor_fixture(editor)

    {:ok, page} =
      Pod.Pages.create(actor, %{
        type: :knowledge,
        title: "Team quotation practice",
        parent_id: skill.id
      })

    context = %{
      Ankole.Brain.Tools.Context.for_subject(colleague.uid)
      | disclosure: %{mode: :relaxed, asker_uid: newcomer.uid, present_uids: []}
    }

    for {revision, practice} <- [
          {0, "Include the exchange rate."},
          {1, "Include the dated exchange rate."}
        ] do
      assert {:ok, _} =
               Pod.Knowledge.write(actor, page.id, revision, "<page><p>#{practice}</p></page>", %{
                 "summary" => "Lesson from the November quotation review"
               })

      assert {:ok, view} =
               Library.skill_view(colleague.uid, "demo", nil, request_context: context)

      assert view["content"] =~ practice

      assert {:ok, bundle} = Library.skill_bundle(colleague.uid, "demo", request_context: context)
      manifest = Enum.find(bundle, &(&1["path"] == "SKILL.md"))
      assert Base.decode64!(manifest["content"]) =~ practice
    end
  end

  defp write_skill(directory, body),
    do:
      File.write!(
        Path.join(directory, "SKILL.md"),
        "---\nname: demo\ndescription: Demo work.\ndefault_enabled: true\n---\n#{body}\n"
      )

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp await_blocker(waiter, blocker, deadline) do
    [[blocked]] =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter]).rows

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("package reconciliation did not wait for the script edit")

      true ->
        Process.sleep(5)
        await_blocker(waiter, blocker, deadline)
    end
  end
end
