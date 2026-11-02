defmodule Ankole.Brain.KnowledgePagesTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.AIAgent.Library.Knowledge, as: Library
  alias Ankole.Brain.{Access, Claims, GetPage, Objects, Recall, SourceLearning}
  alias Ankole.Brain.Schemas.{Claim, Chunk, Link}
  alias Ankole.Files.Access, as: DriveAccess
  alias Ankole.Pod.{Knowledge, Pages}

  setup do
    %{principal: owner} = human_fixture()
    %{principal: reader} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    {:ok, root} =
      Repo.transact(fn ->
        {:ok, namespace} = Library.ensure_namespace_in_tx()

        {:ok, node} =
          Library.ensure_child_in_tx(namespace.root.id, "Boundary", :knowledge,
            inherit_permissions: false
          )

        :ok =
          DriveAccess.put_role(%{principal_uid: owner.uid}, "drive:**:#{node.id}:**", "manage")

        :ok = DriveAccess.put_role(%{principal_uid: agent.uid}, "drive:**:#{node.id}:**", "view")

        :ok =
          DriveAccess.put_role(%{principal_uid: reader.uid}, "drive:**:#{node.id}:node", "view")

        {:ok, _} = Library.put_markdown_in_tx(node, "# Boundary\n\nShared lunar alloy facts.")
        {:ok, node}
      end)

    context = %{
      querier_uid: agent.uid,
      disclosure: %{mode: :strict, asker_uid: reader.uid, present_uids: [reader.uid]}
    }

    %{owner: owner, reader: reader, agent: agent, root: root, context: context}
  end

  test "single-page sharing does not disclose descendants through recall or entity outlines",
       ctx do
    child = child(ctx.root, "Restricted", "Lunar alloy procurement floor is 18.")

    assert {:ok, _} =
             fact(ctx.root.id, ctx.root.id, "Lunar alloy public specification", ctx.agent.uid)

    assert {:ok, _} =
             fact(child.id, child.id, "Lunar alloy confidential procurement floor", ctx.agent.uid)

    assert {:ok, access} = Access.for_context(ctx.context)
    assert Access.visible?(access, ctx.root.id)
    refute Access.visible?(access, child.id)

    assert {:ok, page} =
             GetPage.get_page(ctx.agent.uid, ctx.root.id,
               disclosure: ctx.context.disclosure,
               level: :l1
             )

    assert page.children == []

    assert {:ok, results} =
             Recall.recall(ctx.agent.uid, %{query: "lunar alloy"},
               disclosure: ctx.context.disclosure
             )

    assert Enum.any?(results.claims, &(&1.subject_page_id == ctx.root.id))
    refute Enum.any?(results.claims, &(&1.subject_page_id == child.id))
    refute Enum.any?(results.chunks, &(&1.subject_page_id == child.id))
  end

  test "renaming same-path pages elsewhere cannot redirect historical Brain paths", ctx do
    actor = actor_fixture(ctx.owner)
    nested = child(ctx.root, "Nested", "Original shared knowledge.")
    assert {:ok, _} = Ankole.Files.Nodes.rename(actor, ctx.root.id, "Renamed boundary")

    {:ok, private_namespace} =
      Pages.create(actor, %{type: :folder, title: "AnkoleBrain", private_owner_uid: ctx.owner.uid})

    for attrs <- [%{}, %{private_owner_uid: ctx.owner.uid}, %{parent_id: private_namespace.id}] do
      {:ok, folder} = Pages.create(actor, Map.merge(attrs, %{type: :folder, title: "Boundary"}))

      {:ok, _other} =
        Pages.create(actor, %{
          type: :knowledge,
          parent_id: folder.id,
          title: "Nested",
          xml: "<page><p>Unrelated local knowledge.</p></page>"
        })

      assert {:ok, _} = Ankole.Files.Nodes.rename(actor, folder.id, "Other boundary")
      assert {:ok, %{id: root_id}} = Objects.resolve_slug("Boundary")
      assert root_id == ctx.root.id
      assert {:ok, %{id: nested_id}} = Objects.resolve_slug("Boundary/Nested")
      assert nested_id == nested.id
    end
  end

  test "semantic dedup is bounded by subject and source, including a nil subject", ctx do
    child = child(ctx.root, "Other source", "Other lunar alloy source.")
    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])
    attrs = attrs(nil, ctx.root.id, "Lunar alloy contract renewed")

    assert {:ok, %{claim: first, status: :inserted}} =
             Claims.write_fact(attrs, ctx.agent.uid, embedding: {vector, "knowledge-test"})

    assert {:ok, %{claim: second, status: :inserted}} =
             Claims.write_fact(%{attrs | source_node_id: child.id}, ctx.agent.uid,
               embedding: {vector, "knowledge-test"}
             )

    assert first.id != second.id

    assert {:ok, %{claim: duplicate, status: :duplicate}} =
             Claims.write_fact(attrs, ctx.agent.uid, embedding: {vector, "knowledge-test"})

    assert duplicate.id == first.id
    assert Repo.get!(Claim, second.id).expired_at == nil
  end

  test "events without a subject deduplicate only within the same source", ctx do
    other = child(ctx.root, "Event source", "Event source.")

    attrs = %{
      subject_page_id: nil,
      source_node_id: ctx.root.id,
      date: ~D[2026-11-02],
      summary: "Quarterly review completed",
      provenance: "meeting note"
    }

    assert {:ok, first} = Ankole.Brain.Timelines.write_timeline(attrs, ctx.agent.uid)
    assert {:ok, duplicate} = Ankole.Brain.Timelines.write_timeline(attrs, ctx.agent.uid)
    assert first.id == duplicate.id

    assert {:ok, separate} =
             Ankole.Brain.Timelines.write_timeline(
               %{attrs | source_node_id: other.id},
               ctx.agent.uid
             )

    assert first.id != separate.id
  end

  test "revocation and trash immediately remove claims and chunks from reads", ctx do
    assert {:ok, _} = fact(ctx.root.id, ctx.root.id, "Lunar alloy source fact", ctx.agent.uid)

    {:ok, :ok} =
      Repo.transact(fn ->
        DriveAccess.page_grants(ctx.root.id)
        |> Enum.filter(&(&1.principal_uid == ctx.reader.uid))
        |> DriveAccess.remove_grants()

        {:ok, :ok}
      end)

    assert {:error, :not_found} =
             GetPage.get_page(ctx.agent.uid, ctx.root.id, disclosure: ctx.context.disclosure)

    assert {:ok, results} =
             Recall.recall(ctx.agent.uid, %{query: "lunar alloy"},
               disclosure: ctx.context.disclosure
             )

    assert results.claims == []
    assert results.chunks == []
    assert {:ok, _} = Pages.delete(actor_fixture(ctx.owner), ctx.root.id)
    assert Repo.aggregate(from(c in Chunk, where: c.source_node_id == ^ctx.root.id), :count) == 0
    assert Repo.one!(from(c in Claim, where: c.source_node_id == ^ctx.root.id)).expired_at
  end

  test "self-healing rebuilds stale page and folder timeline chunks", ctx do
    {:ok, folder} =
      Repo.transact(fn -> Library.ensure_child_in_tx(ctx.root.id, "Meeting", :folder) end)

    assert {:ok, _} =
             Ankole.Brain.Timelines.write_timeline(
               %{
                 source_node_id: folder.id,
                 date: ~D[2026-11-02],
                 summary: "Zirconium review completed",
                 provenance: "meeting note"
               },
               :system
             )

    chunking = Map.put(Ankole.Brain.Config.chunking(), "max_chars", 5_000)
    assert {:ok, _} = Ankole.AppConfigure.put_global_by_key("brain.chunking", chunking)
    assert {:ok, %{rechunked: count}} = Ankole.Brain.SelfHealing.sweep()
    assert count >= 2

    chunks = Repo.all(from(c in Chunk, where: c.page_id in ^[ctx.root.id, folder.id]))
    assert MapSet.new(chunks, & &1.page_id) == MapSet.new([ctx.root.id, folder.id])
    assert Enum.all?(chunks, &(&1.chunking_signature == Ankole.Brain.Chunker.signature(chunking)))
  end

  test "timeline recall follows its source and supports folder sources without a subject", ctx do
    hidden = child(ctx.root, "Private timeline", "")

    {:ok, folder} =
      Repo.transact(fn -> Library.ensure_child_in_tx(ctx.root.id, "Meeting", :folder) end)

    event = %{
      date: ~D[2026-11-02],
      summary: "Zirconium review completed",
      provenance: "meeting note"
    }

    assert {:ok, _} =
             Ankole.Brain.Timelines.write_timeline(
               Map.merge(event, %{subject_page_id: ctx.root.id, source_node_id: hidden.id}),
               :system
             )

    assert {:ok, _} =
             Ankole.Brain.Timelines.write_timeline(
               Map.merge(event, %{source_node_id: folder.id}),
               :system
             )

    assert {:ok, visible} = Recall.recall(ctx.agent.uid, %{query: "Zirconium"})

    assert Enum.any?(
             visible.chunks,
             &(&1.content_kind == "timeline" and &1.source_node_id == hidden.id)
           )

    assert Enum.any?(
             visible.chunks,
             &(&1.content_kind == "timeline" and &1.source_node_id == folder.id and
                 is_nil(&1.subject_page_id))
           )

    assert {:ok, restricted} =
             Recall.recall(ctx.agent.uid, %{query: "Zirconium"},
               disclosure: ctx.context.disclosure
             )

    assert restricted.chunks == []
  end

  test "the skill tree is indexed but never becomes a fact source through ancestor opt-in" do
    {:ok, skill} =
      Repo.transact(fn ->
        {:ok, namespace} = Library.ensure_namespace_in_tx()
        {:ok, root} = Pages.fetch(namespace.root.id)

        {:ok, _} =
          Pages.update_properties_in_tx(root, :save_knowledge, %{
            metadata: %{"extract_facts" => true}
          })

        {:ok, skill} = Library.ensure_child_in_tx(namespace.skills.id, "research", :knowledge)

        {:ok, _} =
          Library.put_markdown_in_tx(
            skill,
            "---\nextract_facts: true\n---\n\nResearch instructions."
          )

        Objects.get_by_slug(skill.id)
      end)

    assert Ankole.Brain.Knowledge.indexable?(skill)
    refute Ankole.Brain.Knowledge.extractable?(skill)
  end

  test "a visible timeline does not disclose the title of its restricted subject", ctx do
    subject = child(ctx.root, "Private legal acquisition", "")

    assert {:ok, _} =
             Ankole.Brain.Timelines.write_timeline(
               %{
                 subject_page_id: subject.id,
                 source_node_id: ctx.root.id,
                 date: ~D[2026-11-02],
                 summary: "Zirconium public workshop completed",
                 provenance: "public meeting note"
               },
               :system
             )

    assert {:ok, results} =
             Recall.recall(ctx.agent.uid, %{query: "Zirconium"},
               disclosure: ctx.context.disclosure
             )

    assert [%{subject_page_id: nil, title: "Boundary", source_node_id: source}] = results.chunks
    assert source == ctx.root.id
  end

  test "moving an existing document into an opted-in directory schedules fact extraction", ctx do
    actor = actor_fixture(ctx.owner)

    assert {:ok, document} =
             Pages.create(actor, %{
               title: "Factory notes",
               type: :doc,
               xml: "<page><p>The factory has three lines.</p></page>"
             })

    assert {:ok, directory} =
             Pages.create(actor, %{
               title: "Business evidence",
               type: :folder,
               metadata: %{"extract_facts" => true}
             })

    {:ok, before} = Objects.get_by_slug(document.id)
    refute Ankole.Brain.Knowledge.extractable?(before)
    jobs = from(j in Oban.Job, where: fragment("?->>'page_id' = ?", j.args, ^document.id))
    refute Repo.exists?(jobs)

    assert {:ok, _} = Ankole.Files.Nodes.move(actor, document.id, %{parent_id: directory.id})
    {:ok, moved} = Objects.get_by_slug(document.id)
    assert moved.revision == before.revision
    assert Ankole.Brain.Knowledge.extractable?(moved)
    assert Repo.exists?(from(j in jobs, where: j.state == "available"))
  end

  test "a folder manager can start learning existing content and stop queued extraction", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, folder} = Pages.create(actor, %{type: :folder, metadata: %{"team" => "procurement"}})
    {:ok, nested} = Pages.create(actor, %{type: :folder, parent_id: folder.id})

    {:ok, document} =
      Pages.create(actor, %{
        type: :doc,
        parent_id: nested.id,
        xml: "<page><p>The factory has three lines.</p></page>"
      })

    jobs = from(j in Oban.Job, where: fragment("?->>'page_id' = ?", j.args, ^document.id))
    refute Repo.exists?(jobs)

    assert {:ok, %{fact_learning: %{enabled: false, inherited: false}}} =
             Pages.get(actor, folder.id)

    assert {:ok, enabled} = Pages.update(actor, folder.id, %{extract_facts: true})
    assert enabled.metadata == %{"team" => "procurement", "extract_facts" => true}
    assert Repo.exists?(from(j in jobs, where: j.state == "available"))

    assert {:ok, %{fact_learning: %{enabled: false, inherited: true}}} =
             Pages.get(actor, nested.id)

    assert {:ok, source} = Objects.get_by_slug(document.id)
    assert Ankole.Brain.Knowledge.extractable?(source)

    assert {:ok, _} = Pages.update(actor, folder.id, %{extract_facts: false})
    refute Ankole.Brain.Knowledge.extractable?(source)

    assert {:ok, %{fact_learning: %{enabled: false, inherited: false}}} =
             Pages.get(actor, nested.id)

    extraction = %{
      items: [%{"claim" => "The factory has three lines", "kind" => "fact"}],
      windows: 1
    }

    assert {:error, :stale_run} =
             Repo.transact(fn ->
               SourceLearning.commit_page_run_in_tx(document.id, document.revision, extraction)
             end)

    refute Repo.exists?(from(c in Claim, where: c.source_node_id == ^document.id))
    assert {:error, :invalid_request} = Pages.update(actor, document.id, %{extract_facts: true})
  end

  test "folder learning uses the folder's management permission", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, folder} = Pages.create(actor, %{type: :folder})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, folder.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.reader.uid, role: "edit"}]
      })

    assert {:error, _} =
             Pages.update(actor_fixture(ctx.reader), folder.id, %{extract_facts: true})

    assert {:ok, %{metadata: %{}}} = Pages.fetch(folder.id)
  end

  for destination <- [:skill, :contract] do
    @destination destination
    test "late extraction is rejected after moving a page into the #{destination} path", ctx do
      name = if @destination == :skill, do: "fact-extraction-example", else: "AGENTS.override.md"
      page = child(ctx.root, name, "Example company has three factories.")
      {:ok, captured} = Objects.get_by_slug(page.id)
      assert Ankole.Brain.Knowledge.extractable?(captured)
      {:ok, namespace} = Repo.transact(fn -> Library.ensure_namespace_in_tx() end)
      parent_id = if @destination == :skill, do: namespace.skills.id, else: namespace.root.id

      assert {:ok, :ok} =
               Repo.transact(fn ->
                 :ok =
                   DriveAccess.put_role(
                     %{principal_uid: ctx.owner.uid},
                     "drive:**:#{parent_id}:**",
                     "manage"
                   )

                 {:ok, :ok}
               end)

      assert {:ok, _} =
               Ankole.Files.Nodes.move(actor_fixture(ctx.owner), page.id, %{
                 parent_id: parent_id
               })

      {:ok, moved} = Objects.get_by_slug(page.id)
      assert moved.revision == captured.revision
      refute Ankole.Brain.Knowledge.extractable?(moved)

      extraction = %{
        items: [
          %{
            "claim" => "Example company has three factories",
            "kind" => "fact",
            "confidence" => 0.75
          }
        ],
        windows: 1
      }

      assert {:error, :stale_run} =
               Repo.transact(fn ->
                 SourceLearning.commit_page_run_in_tx(page.id, captured.revision, extraction)
               end)

      refute Repo.exists?(from(c in Claim, where: c.source_node_id == ^page.id))
    end
  end

  test "late extraction cannot commit after a page revision changes", ctx do
    page = child(ctx.root, "Facts", "The factory has three lines.")
    {:ok, current} = Pages.fetch(page.id)
    {:ok, parsed} = Ankole.Kernel.knowledge_parse("The factory has four lines.")

    assert {:ok, _} =
             Knowledge.write(actor_fixture(ctx.owner), page.id, current.revision, parsed.xml, %{
               "extract_facts" => true
             })

    extraction = %{
      items: [%{"claim" => "The factory has three lines", "kind" => "fact", "confidence" => 0.75}],
      windows: 1
    }

    assert {:error, :stale_run} =
             Repo.transact(fn ->
               SourceLearning.commit_page_run_in_tx(page.id, current.revision, extraction)
             end)

    assert Repo.aggregate(from(c in Claim, where: c.source_node_id == ^page.id), :count) == 0
  end

  test "an embedding cannot commit for an earlier page revision with identical text", ctx do
    chunk =
      Repo.one!(from(c in Chunk, where: c.page_id == ^ctx.root.id and c.content_kind == :body))

    {:ok, page} = Pages.fetch(ctx.root.id)
    {:ok, %{content: content}} = Knowledge.read_in_tx(page.id)

    assert {:ok, _} =
             Knowledge.write(actor_fixture(ctx.owner), page.id, page.revision, content.content, %{
               "tags" => ["revised"]
             })

    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

    assert {:ok, :stale} =
             Ankole.Brain.Chunks.record_embedding(chunk, {:ok, vector, "revision-test"})

    assert Repo.get!(Chunk, chunk.id).embedding == nil
  end

  test "property edits keep completed vectors and exclude old in-flight results", ctx do
    chunk = Repo.get_by!(Chunk, page_id: ctx.root.id, chunk_index: 0)
    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

    assert {:ok, :updated} =
             Ankole.Brain.Chunks.record_embedding(chunk, {:ok, vector, "current-model"})

    embedded = Repo.get!(Chunk, chunk.id)
    {:ok, %{page: page, content: content}} = Knowledge.read_in_tx(ctx.root.id)

    assert {:ok, %{page: saved}} =
             Knowledge.write(actor_fixture(ctx.owner), page.id, page.revision, content.content, %{
               "summary" => "Updated supplier summary",
               "tags" => ["approved"]
             })

    current = Repo.get!(Chunk, chunk.id)
    assert current.page_revision == saved.revision
    assert current.page_revision > embedded.page_revision
    assert current.embedding == embedded.embedding
    assert current.embedding_signature == embedded.embedding_signature
    assert current.embedded_at == embedded.embedded_at

    assert {:ok, :stale} =
             Ankole.Brain.Chunks.record_embedding(
               embedded,
               {:error, "late failure", "current-model"}
             )

    assert Repo.get!(Chunk, chunk.id).embedding == embedded.embedding
    assert {:ok, preview} = GetPage.get_page(ctx.owner.uid, page.id, level: :l0)
    assert preview.summary == "Updated supplier summary"
  end

  test "a body edit invalidates changed positions and keeps identical positions", ctx do
    stable = String.duplicate("unchanged supplier terms ", 99)
    delivery = String.duplicate("Delivery includes tracked packaging. ", 50)

    page =
      child(ctx.root, "Quotation", stable <> "\n\n" <> delivery <> "Freight costs 20 dollars.")

    chunks = Repo.all(from(c in Chunk, where: c.page_id == ^page.id, order_by: c.chunk_index))
    assert length(chunks) == 2
    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

    for chunk <- chunks do
      assert {:ok, :updated} =
               Ankole.Brain.Chunks.record_embedding(chunk, {:ok, vector, "current-model"})
    end

    {:ok, current} = Pages.fetch(page.id)

    {:ok, parsed} =
      Ankole.Kernel.knowledge_parse(stable <> "\n\n" <> delivery <> "Freight costs 30 dollars.")

    assert {:ok, %{page: saved}} =
             Knowledge.write(actor_fixture(ctx.owner), page.id, current.revision, parsed.xml, %{})

    [stable_before, changed_before] = chunks
    stable_after = Repo.get!(Chunk, stable_before.id)
    changed_after = Repo.get!(Chunk, changed_before.id)
    assert stable_after.embedding != nil
    assert stable_after.chunk_text == stable_before.chunk_text
    assert stable_after.page_revision == saved.revision
    assert changed_after.chunk_text =~ "30 dollars"
    assert changed_after.embedding == nil
    assert changed_after.page_revision == saved.revision
  end

  test "restoring a trashed subtree restores retrieval and queues fresh extraction", ctx do
    page = child(ctx.root, "Restored source", "Beryllium workshop instructions.")
    jobs = from(j in Oban.Job, where: fragment("?->>'page_id' = ?", j.args, ^page.id))
    Repo.update_all(jobs, set: [state: "completed", completed_at: DateTime.utc_now(:microsecond)])
    assert {:ok, _} = Pages.delete(actor_fixture(ctx.owner), ctx.root.id)
    assert {:ok, gone} = Recall.recall(ctx.agent.uid, %{query: "Beryllium"})
    assert gone.chunks == []
    assert {:ok, _} = Ankole.Files.Nodes.restore(actor_fixture(ctx.owner), ctx.root.id)
    assert {:ok, restored} = Recall.recall(ctx.agent.uid, %{query: "Beryllium"})
    assert Enum.any?(restored.chunks, &(&1.subject_page_id == page.id))
    assert Repo.exists?(from(j in jobs, where: j.state == "available"))
  end

  test "renaming keeps page and typed relation identities and resolves the old path", ctx do
    child = child(ctx.root, "Reference", "Source details.")

    {:ok, edge} =
      Ankole.Brain.Links.upsert_link(%{
        from_page_id: ctx.root.id,
        to_page_id: child.id,
        link_type: "supplies",
        link_source: "manual",
        context: "supplier evidence"
      })

    {:ok, before} = Objects.get_by_slug(child.id)

    assert {:ok, _} =
             Pages.update(actor_fixture(ctx.owner), child.id, %{
               title: "Renamed reference",
               expected_title: child.name
             })

    assert {:ok, resolved} = Objects.resolve_slug(before.slug)
    assert resolved.id == child.id
    assert Repo.get!(Link, edge.id).to_page_id == child.id
    assert Repo.get!(Link, edge.id).link_type == "supplies"
  end

  defp child(parent, name, body) do
    {:ok, node} =
      Repo.transact(fn ->
        {:ok, node} = Library.ensure_child_in_tx(parent.id, name, :knowledge)
        {:ok, _} = Library.put_markdown_in_tx(node, body)
        {:ok, node}
      end)

    node
  end

  defp fact(subject, source, text, uid),
    do: Claims.write_fact(attrs(subject, source, text), uid, embed: false)

  defp attrs(subject, source, text),
    do: %{
      subject_page_id: subject,
      source_node_id: source,
      claim: text,
      kind: "fact",
      holder: "world",
      notability: "medium",
      confidence: 0.75,
      valid_from: DateTime.utc_now(:microsecond),
      provenance: "knowledge page acceptance test"
    }
end
