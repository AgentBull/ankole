defmodule Ankole.Pod.OfficeFilesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.Files, as: Drive
  alias Ankole.Files.Schemas.FileObject
  alias Ankole.Kernel

  alias Ankole.Pod.{
    FileCache,
    Files,
    OfficeCheckpoint,
    OfficeFiles,
    OfficeOp,
    Pages,
    PageSearchDocument,
    PageSnapshot
  }

  alias Ankole.Pod.Jobs.{CompactOfficeFile, SyncFileCache}

  # A 1×1 PNG.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  @limits %{
    "max_file_bytes" => 20_971_520,
    "compaction_idle_seconds" => 30,
    "compaction_op_threshold" => 100,
    "compaction_structural_threshold" => 10
  }

  setup do
    owner = human_fixture(%{display_name: "Owner Name"}).principal
    editor = human_fixture(%{display_name: "Editor Name"}).principal
    actor = actor_fixture(owner.uid)

    {:ok, page} =
      OfficeFiles.create_blank(actor, %{format: :spreadsheet, private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [%{principal_uid: editor.uid, role: "edit"}]
      })

    %{owner: owner, editor: editor, actor: actor, page: page}
  end

  defp set(cell, input),
    do: %{"type" => "cell.set", "sheet_id" => 1, "cell" => cell, "input" => input}

  defp request(base, client, seq, op),
    do: %{base_revision: base, client_id: client, client_seq: seq, op: op}

  defp limits(overrides),
    do:
      Ankole.AppConfigure.put_tenant_by_key(
        "pod.office.limits",
        Map.merge(@limits, overrides)
      )

  defp file_text(actor, page_id, digest \\ nil) do
    {:ok, _entry, bytes} = Files.read(actor, page_id, "Untitled.xlsx", digest)
    object_text(bytes)
  end

  defp object_text(bytes) do
    {:ok, %{plain_text: text}} = Kernel.office_open(:spreadsheet, bytes, [])
    text
  end

  defp workbook(text) do
    {:ok, %{doc_ref: doc}} = Kernel.office_create_blank(:spreadsheet, "Upload")
    {:ok, %{doc_ref: doc}} = Kernel.office_apply(doc, set("A1", text), [], nil)
    {:ok, %{bytes: bytes}} = Kernel.office_export(doc)
    bytes
  end

  defp entries(page_id),
    do:
      OfficeOp
      |> where([entry], entry.page_id == ^page_id)
      |> order_by([entry], entry.revision)
      |> Repo.all()

  defp versions(page_id),
    do:
      PageSnapshot
      |> where([snapshot], snapshot.page_id == ^page_id)
      |> order_by([snapshot], [snapshot.created_at, snapshot.id])
      |> Repo.all()

  defp package_parts(bytes) do
    {:ok, files} = :zip.unzip(bytes, [:memory])
    Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
  end

  defp object_id(page_id) do
    {:ok, node} = Ankole.Pod.fetch_node(page_id)
    node.object_id
  end

  defp manifest_object(actor, page_id) do
    {:ok, %{files: [%{object_id: id}]}} = Files.manifest(actor, page_id)
    id
  end

  # Makes the next periodic checkpoint due without waiting for the interval.
  defp age_history(page_id),
    do:
      Repo.update_all(from(snapshot in PageSnapshot, where: snapshot.page_id == ^page_id),
        set: [created_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

  test "blank spreadsheet, word, and presentation pages commit their file, cache, created version, and reset entry",
       ctx do
    page = ctx.page
    assert page.type == :file
    assert page.name == "Untitled.xlsx"
    assert page.revision == 1
    assert OfficeFiles.office_file?(page)
    assert OfficeFiles.spreadsheet?(page)
    assert OfficeFiles.kind("Budget.XLSM") == :spreadsheet
    assert OfficeFiles.kind("Budget.xlsx (2)") == :spreadsheet
    assert OfficeFiles.kind("Spec.DOCX") == :word
    assert OfficeFiles.kind("Spec.docm (1)") == :word
    assert OfficeFiles.kind("Deck.PPTX") == :presentation
    assert OfficeFiles.kind("Deck.pptx (3)") == :presentation
    refute OfficeFiles.office_file?("Budget.xls")
    refute OfficeFiles.office_file?("Legacy.doc")
    refute OfficeFiles.office_file?("Legacy.ppt")
    refute OfficeFiles.office_file?("Budget.xlsx.pdf")

    assert [%{revision: 1, kind: :reset, compacted: true, op: nil}] = entries(page.id)
    object = object_id(page.id)

    assert [
             %{
               reason: :created,
               revision: 1,
               object_id: ^object,
               title: "Untitled.xlsx",
               content: nil
             }
           ] = versions(page.id)

    assert %FileCache{subtype: :spreadsheet, object_id: ^object, extract_status: :ok} =
             Repo.get_by!(FileCache, page_id: page.id)

    assert Repo.get_by!(PageSearchDocument, page_id: page.id).body_text == "[Sheet: Sheet1]\n"

    assert {:ok,
            %{
              page_id: page_id,
              revision: 1,
              format: :spreadsheet,
              file: %{path: "Untitled.xlsx", object_id: ^object, sha256: hex},
              ops: [],
              metadata: %{"sheets" => [%{"sheet_id" => 1, "name" => "Sheet1"}]}
            }} = OfficeFiles.bootstrap(ctx.actor, page.id)

    assert page_id == page.id
    {:ok, stored} = Drive.fetch_object(object)
    assert hex == Base.encode16(stored.sha256, case: :lower)

    {:ok, named} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :spreadsheet,
        title: "Q4 预算",
        private_owner_uid: ctx.owner.uid
      })

    assert named.name == "Q4 预算.xlsx"
    assert {:ok, [%{path: "Q4 预算.xlsx"}]} = Files.list_files(named.id)

    # A second blank workbook in the same folder takes Drive's duplicate name and stays editable.
    {:ok, second} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :spreadsheet,
        private_owner_uid: ctx.owner.uid
      })

    assert second.name == "Untitled (1).xlsx"

    assert {:ok, %{revision: 1, format: :spreadsheet}} =
             OfficeFiles.bootstrap(ctx.actor, second.id)

    # Blank Word and Presentation pages bootstrap cleanly with their formats.
    {:ok, word_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "季度方案",
        private_owner_uid: ctx.owner.uid
      })

    assert word_page.name == "季度方案.docx"

    assert {:ok, %{revision: 1, format: :word, ops: []}} =
             OfficeFiles.bootstrap(ctx.actor, word_page.id)

    {:ok, pres_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :presentation,
        title: "路演汇报",
        private_owner_uid: ctx.owner.uid
      })

    assert pres_page.name == "路演汇报.pptx"

    assert {:ok, %{revision: 1, format: :presentation, ops: []}} =
             OfficeFiles.bootstrap(ctx.actor, pres_page.id)
  end

  test "the operation log rejects malformed entries and snapshots name content or an object",
       ctx do
    now = DateTime.utc_now(:microsecond)
    author = to_string(Ankole.ActorRef.from_actor(ctx.actor))

    assert {:error, %Postgrex.Error{postgres: %{constraint: "pod_office_ops_entry_shape"}}} =
             Repo.query(
               "INSERT INTO pod_office_ops (tenant_id, page_id, revision, kind, client_id, client_seq, op, author, created_at) VALUES ($1::text::uuid, $2::text::uuid, 9, 'op', 'c', 1, '{}'::jsonb, $3, $4)",
               [Repo.tenant_id!(), ctx.page.id, author, now]
             )

    snapshot =
      "INSERT INTO page_snapshots (id, tenant_id, page_id, revision, title, content, object_id, author, document_updated_at, created_at, reason) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 1, 'x.xlsx', $4, $5::text::uuid, $6, $7, $7, 'checkpoint')"

    assert {:error, %Postgrex.Error{postgres: %{constraint: "page_snapshots_content_shape"}}} =
             Repo.query(snapshot, [
               Ecto.UUID.generate(),
               Repo.tenant_id!(),
               ctx.page.id,
               "<page />",
               object_id(ctx.page.id),
               author,
               now
             ])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "page_snapshots_object_fkey"}}} =
             Repo.query(snapshot, [
               Ecto.UUID.generate(),
               Repo.tenant_id!(),
               ctx.page.id,
               nil,
               Ecto.UUID.generate(),
               author,
               now
             ])
  end

  test "operations commit once per client sequence and a stale base replays the missing changes",
       ctx do
    editor = actor_fixture(ctx.editor.uid)
    page = ctx.page

    assert {:ok,
            %{revision: 2, acknowledged_revision: 2, reset_required: false, changes: [first]}} =
             OfficeFiles.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "季度预算"))
             )

    assert %{revision: 2, kind: :op, op: %{"cell" => "A1"}, compacted: false} = first

    assert {:ok, %{revision: 2, acknowledged_revision: 2}} =
             OfficeFiles.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "季度预算"))
             )

    assert {:error, :client_sequence_conflict} =
             OfficeFiles.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "other"))
             )

    assert {:ok, %{revision: 3, acknowledged_revision: 3, changes: [missed, own]}} =
             OfficeFiles.apply_op(editor, page.id, request(1, "editor-tab", 1, set("B1", "2")))

    assert missed.revision == 2
    assert %{revision: 3, client_id: "editor-tab", op: %{"cell" => "B1"}} = own
    assert length(entries(page.id)) == 3

    assert {:error, :invalid_request} =
             OfficeFiles.apply_op(editor, page.id, request(1, "editor-tab", 0, set("B1", "2")))

    assert {:error, {:invalid_operation, message}} =
             OfficeFiles.apply_op(editor, page.id, request(3, "editor-tab", 2, set("ZZZ0", "x")))

    assert message =~ "cell"

    assert {:ok, %{revision: 4, changes: [%{op: %{"author" => "Editor Name"}}]}} =
             OfficeFiles.apply_op(
               editor,
               page.id,
               request(3, "editor-tab", 3, %{
                 "type" => "comment.set",
                 "sheet_id" => 1,
                 "cell" => "A1",
                 "text" => "check",
                 "author" => "Someone Else"
               })
             )

    assert {:ok, %{revision: 4, changes: [%{revision: 3}, %{revision: 4}], reset_required: false}} =
             OfficeFiles.since(editor, page.id, 2)

    assert {:ok, %{reset_required: true}} = OfficeFiles.since(editor, page.id, 9)

    assert {:ok, %{ops: ops}} = OfficeFiles.bootstrap(editor, page.id)
    assert Enum.map(ops, & &1.revision) == [2, 3, 4]

    reader = actor_fixture(human_fixture().principal)

    assert {:error, _denied} =
             OfficeFiles.apply_op(reader, page.id, request(4, "reader-tab", 1, set("C1", "x")))
  end

  test "a cell edit crossing a row insert lands on the moved cell with its formula rebased",
       ctx do
    editor = actor_fixture(ctx.editor.uid)
    page = ctx.page

    insert = %{
      "type" => "line.insert",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 2,
      "count" => 3
    }

    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(1, "owner-tab", 1, insert))

    assert {:ok, %{revision: 3, changes: [%{op: %{"type" => "line.insert"}}, %{op: committed}]}} =
             OfficeFiles.apply_op(
               editor,
               page.id,
               request(1, "editor-tab", 1, set("C5", "=SUM(B1:B5)"))
             )

    assert %{"cell" => "C8", "input" => "=SUM(B1:B8)"} = committed

    assert {:ok, %{ops: [%{op: %{"type" => "line.insert"}}, %{op: %{"cell" => "C8"}}]}} =
             OfficeFiles.bootstrap(editor, page.id)
  end

  test "a conflicting rebase is rejected with office_conflict and the changes the author missed",
       ctx do
    editor = actor_fixture(ctx.editor.uid)
    page = ctx.page

    delete = %{
      "type" => "line.delete",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 0,
      "count" => 4
    }

    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(1, "owner-tab", 1, delete))

    assert {:error,
            {:office_conflict,
             %{
               reason: :target_deleted,
               revision: 2,
               changes: [%{"revision" => 2, "op" => %{"type" => "line.delete"}}]
             }}} =
             OfficeFiles.apply_op(
               editor,
               page.id,
               request(1, "editor-tab", 1, set("A2", "lost"))
             )

    assert {:ok, %{revision: 2}} = Pages.fetch(page.id)

    assert %{
             code: "office_conflict",
             details: %{"reason" => "target_deleted", "revision" => 2, "changes" => []}
           } =
             Ankole.Pod.Serialization.error(
               {:office_conflict, %{reason: :target_deleted, revision: 2, changes: []}}
             )

    assert Ankole.Pod.Serialization.status("office_conflict") == 409
  end

  test "word block unit edits rebase non-overlapping splices, reject overlapping block conflicts, and preserve search across compaction",
       ctx do
    editor = actor_fixture(ctx.editor.uid)

    {:ok, word_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "Word Collab",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, word_page.id, %{
        grants: [%{principal_uid: ctx.editor.uid, role: "edit"}]
      })

    # Seed two paragraphs via Agent commands so two collaborators can edit distinct blocks.
    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_agent(ctx.actor, word_page.id, %{
               commands: [
                 %{
                   "command" => "text.insert",
                   "params" => %{
                     "text" => "First paragraph\nSecond paragraph",
                     "paragraphs" => true
                   }
                 }
               ]
             })

    assert {:ok, %{"blocks" => [%{"text" => "First paragraph"}, %{"text" => "Second paragraph"}]}} =
             OfficeFiles.inspect_doc(ctx.actor, word_page.id, %{})

    # Compact to write initial text and run SyncFileCache so PageSearchDocument is populated.
    assert :ok = OfficeFiles.flush_if_dirty(word_page.id)

    assert :ok =
             perform_job(SyncFileCache, %{
               "tenant_id" => Repo.tenant_id!(),
               "page_id" => word_page.id,
               "object_id" => object_id(word_page.id)
             })

    assert Repo.get_by!(PageSearchDocument, page_id: word_page.id).body_text =~ "First paragraph"

    # Build two block splices against revision 2: owner inserts a paragraph before block 0,
    # editor updates block 1; editor's block index shifts cleanly to block 2!
    {:ok, %{bytes: current_bytes}} =
      with {:ok, _, raw} <- Files.read(ctx.actor, word_page.id, "Word Collab.docx") do
        {:ok, %{bytes: raw}}
      end

    {:ok, %{doc_ref: base_doc}} = Kernel.office_open(:word, current_bytes, [])

    {:ok, %{change_set: insert_before}} =
      Kernel.office_apply_commands(
        base_doc,
        [
          %{
            "command" => "text.insert",
            "params" => %{"text" => "Prepended\n", "paragraphs" => true}
          }
        ],
        "Owner Name"
      )

    # Pure insertion at block 0 (`delete: 0`) shifts block 1 without overlapping it.
    pure_insert_at_0 = %{
      "model_version" => 1,
      "edits" => [
        %{
          "kind" => "blocks.splice",
          "story" => "body",
          "at" => 0,
          "delete" => 0,
          "insert" => insert_before["edits"] |> hd() |> Map.fetch!("insert") |> Enum.take(1)
        }
      ]
    }

    block_1_edit = %{
      "model_version" => 1,
      "edits" => [
        %{
          "kind" => "blocks.splice",
          "story" => "body",
          "at" => 1,
          "delete" => 1,
          "insert" => insert_before["edits"] |> hd() |> Map.fetch!("insert") |> Enum.take(1)
        }
      ]
    }

    assert {:ok, %{revision: 3}} =
             OfficeFiles.apply_op(
               ctx.actor,
               word_page.id,
               request(2, "owner-word", 1, pure_insert_at_0)
             )

    assert {:ok, %{revision: 4, changes: [_, %{op: shifted}]}} =
             OfficeFiles.apply_op(
               editor,
               word_page.id,
               request(2, "editor-word", 1, block_1_edit)
             )

    assert [%{"kind" => "blocks.splice", "at" => 2, "delete" => 1}] = shifted["edits"]

    # Overlapping edit on the same block from stale base_revision 3 is rejected with office_conflict.
    same_block_conflict = %{
      "model_version" => 1,
      "edits" => [
        %{
          "kind" => "blocks.splice",
          "story" => "body",
          "at" => 2,
          "delete" => 1,
          "insert" => insert_before["edits"] |> hd() |> Map.fetch!("insert") |> Enum.take(1)
        }
      ]
    }

    assert {:error, {:office_conflict, %{reason: :block_changed, revision: 4}}} =
             OfficeFiles.apply_op(
               ctx.actor,
               word_page.id,
               request(3, "owner-word", 2, same_block_conflict)
             )

    # Non-purging compaction keeps existing search text live before SyncFileCache runs!
    assert :ok = OfficeFiles.flush_if_dirty(word_page.id)
    assert Repo.get_by!(PageSearchDocument, page_id: word_page.id).body_text =~ "First paragraph"
  end

  test "a presentation editor can save a slide operation after compaction replaces the object",
       ctx do
    editor = actor_fixture(ctx.editor.uid)

    {:ok, pres_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :presentation,
        title: "Pitch Deck",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, pres_page.id, %{
        grants: [%{principal_uid: ctx.editor.uid, role: "edit"}]
      })

    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_agent(ctx.actor, pres_page.id, %{
               commands: [
                 %{"command" => "insert.textBox", "params" => %{"text" => "Before compaction"}},
                 %{"command" => "slide.new", "params" => %{"title" => "Second slide"}}
               ]
             })

    assert {:ok, %{revision: 2, file: previous, ops: [%{op: tail}]}} =
             OfficeFiles.bootstrap(editor, pres_page.id)

    {:ok, _, raw} = Files.read(editor, pres_page.id, previous.path, previous.sha256)
    {:ok, %{doc_ref: editor_doc}} = Kernel.office_open(:presentation, raw, [tail])

    {:ok, %{change_set: edit}} =
      Kernel.office_apply_commands(
        editor_doc,
        [%{"command" => "insert.textBox", "params" => %{"text" => "After compaction"}}],
        "Editor Name"
      )

    assert :ok = OfficeFiles.flush_if_dirty(pres_page.id)

    assert {:ok, %{revision: 2, file: compacted, ops: [], checkpoint: checkpoint}} =
             OfficeFiles.bootstrap(editor, pres_page.id)

    assert is_binary(checkpoint)
    refute previous.object_id == compacted.object_id

    {:ok, _, compacted_bytes} = Files.read(editor, pres_page.id, compacted.path, compacted.sha256)
    parts = package_parts(compacted_bytes)
    refute Enum.any?(Map.keys(parts), &String.contains?(&1, "ankole"))

    refute Enum.any?(parts, fn {name, content} ->
             String.ends_with?(name, [".xml", ".rels"]) and
               (String.contains?(content, "xmlns:ankole") or
                  String.contains?(content, "ankole:partId"))
           end)

    # Evict NodeCache so the control plane cold-loads the compacted file with its checkpoint.
    :ets.delete(Ankole.Pod.OfficeFiles.NodeCache, {Repo.tenant_id!(), pres_page.id})

    assert {:ok, %{acknowledged_revision: 3}} =
             OfficeFiles.apply_op(editor, pres_page.id, request(2, "tab", 1, edit))

    assert {:ok, %{ops: [%{op: committed}], checkpoint: ^checkpoint}} =
             OfficeFiles.bootstrap(editor, pres_page.id)

    {:ok, _, raw} = Files.read(editor, pres_page.id, compacted.path, compacted.sha256)

    assert {:ok, %{doc_ref: reopened}} =
             Kernel.office_open(:presentation, raw, [committed], checkpoint)

    assert {:ok, inspected} = Kernel.office_inspect(reopened, %{})
    assert Torque.encode!(inspected) =~ "After compaction"

    # External replacement clears the stale compaction checkpoint.
    {:ok, %{bytes: external_pptx}} = Kernel.office_create_blank(:presentation, "External Deck")
    assert {:ok, _} = Ankole.Pod.write_node(ctx.actor, pres_page.id, external_pptx)
    refute Repo.get_by(OfficeCheckpoint, page_id: pres_page.id)
    assert {:ok, %{checkpoint: nil}} = OfficeFiles.bootstrap(editor, pres_page.id)
  end

  test "word compaction writes pure OOXML, keeps cold-reopen IDs via OfficeCheckpoint, and clears on external upload",
       ctx do
    editor = actor_fixture(ctx.editor.uid)

    {:ok, word_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "Pure OOXML Contract",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, word_page.id, %{
        grants: [%{principal_uid: ctx.editor.uid, role: "edit"}]
      })

    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_agent(ctx.actor, word_page.id, %{
               commands: [
                 %{
                   "command" => "text.insert",
                   "params" => %{"text" => "Clause 1\nClause 2", "paragraphs" => true}
                 },
                 %{
                   "command" => "insert.picture",
                   "params" => %{"data" => @png, "alt" => "seal.png"}
                 }
               ]
             })

    assert {:ok, %{revision: 2, file: before_compact, ops: [%{op: tail}]}} =
             OfficeFiles.bootstrap(editor, word_page.id)

    {:ok, _, raw_before} =
      Files.read(editor, word_page.id, before_compact.path, before_compact.sha256)

    {:ok, %{doc_ref: stale_editor_doc}} = Kernel.office_open(:word, raw_before, [tail])

    {:ok, %{change_set: in_flight_edit}} =
      Kernel.office_apply_commands(
        stale_editor_doc,
        [%{"command" => "text.insert", "params" => %{"text" => " Amended"}}],
        "Editor Name"
      )

    assert :ok = OfficeFiles.flush_if_dirty(word_page.id)

    assert {:ok, %{revision: 2, file: compacted, ops: [], checkpoint: checkpoint}} =
             OfficeFiles.bootstrap(editor, word_page.id)

    {:ok, _, compacted_docx} = Files.read(editor, word_page.id, compacted.path, compacted.sha256)
    assert {:ok, %{doc_ref: _}} = Kernel.office_open(:word, compacted_docx, [], checkpoint)
    parts = package_parts(compacted_docx)
    refute Enum.any?(Map.keys(parts), &String.contains?(&1, "ankole"))

    refute Enum.any?(parts, fn {name, content} ->
             String.ends_with?(name, [".xml", ".rels"]) and String.contains?(content, "ankole")
           end)

    :ets.delete(Ankole.Pod.OfficeFiles.NodeCache, {Repo.tenant_id!(), word_page.id})

    assert {:ok, %{acknowledged_revision: 3}} =
             OfficeFiles.apply_op(editor, word_page.id, request(2, "word-tab", 1, in_flight_edit))

    assert {:ok, %{"blocks" => [%{"text" => first_text} | _]}} =
             OfficeFiles.inspect_doc(editor, word_page.id)

    assert first_text =~ "Amended"

    {:ok, %{bytes: external_docx}} = Kernel.office_create_blank(:word, "External Word")
    assert {:ok, _} = Ankole.Pod.write_node(ctx.actor, word_page.id, external_docx)
    refute Repo.get_by(OfficeCheckpoint, page_id: word_page.id)
  end

  test "agent spreadsheet batches commit atomically and reject oversized operations with invalid_request",
       ctx do
    page = ctx.page

    assert {:ok, %{revision: 4, results: [%{"ok" => true}, %{"ok" => true}, %{"ok" => true}]}} =
             OfficeFiles.apply_agent(ctx.actor, page.id, %{
               expected_revision: 1,
               ops: [
                 set("A1", "10"),
                 set("A2", "=A1*3"),
                 %{
                   "type" => "comment.set",
                   "sheet_id" => 1,
                   "cell" => "A2",
                   "text" => "Reviewed",
                   "author" => "Spoofed"
                 }
               ]
             })

    assert [
             %{revision: 1, kind: :reset},
             %{revision: 2, kind: :op, client_seq: 1},
             %{revision: 3, kind: :op, client_seq: 2},
             %{revision: 4, kind: :op, client_seq: 3, op: %{"author" => "Owner Name"}}
           ] = entries(page.id)

    assert file_text(ctx.actor, page.id) =~ "30"

    huge = String.duplicate("x", 4 * 1024 * 1024 + 64)

    assert {:error, :invalid_request} =
             OfficeFiles.apply_agent(ctx.actor, page.id, %{ops: [set("B1", huge)]})

    {:ok, word_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "Oversized Batch",
        private_owner_uid: ctx.owner.uid
      })

    assert {:error, :invalid_request} =
             OfficeFiles.apply_agent(ctx.actor, word_page.id, %{
               commands: [%{"command" => "text.insert", "params" => %{"text" => huge}}]
             })
  end

  test "word-to-document conversion creates a sibling or Private doc page with extracted media and feature report",
       ctx do
    {:ok, space_parent} = Pages.create(ctx.actor, %{title: "Specs"})

    {:ok, word_page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "Product Spec",
        parent_id: space_parent.id
      })

    # Populate heading, paragraph text, and an inline PNG picture via headless commands.
    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_agent(ctx.actor, word_page.id, %{
               commands: [
                 %{
                   "command" => "text.insert",
                   "params" => %{
                     "text" => "Architecture Overview\nCore body text for conversion.",
                     "paragraphs" => true
                   }
                 },
                 %{
                   "command" => "insert.picture",
                   "params" => %{"data" => @png, "alt" => "diagram.png"}
                 }
               ]
             })

    # Convert as owner: permitted under `space_parent`, so lands as next sibling (`parent_id == space_parent.id`).
    assert {:ok, %{page: converted_doc, omitted: omitted, downgraded: downgraded}} =
             OfficeFiles.convert_to_document(ctx.actor, word_page.id)

    assert converted_doc.type == :doc
    assert converted_doc.title == "Product Spec"
    assert converted_doc.parent_id == space_parent.id
    assert is_map(omitted)
    assert is_map(downgraded)

    assert {:ok, %{content: %{content: xml}}} = Pages.get(ctx.actor, converted_doc.id)
    assert xml =~ "Architecture Overview"
    assert xml =~ "Core body text for conversion."
    assert xml =~ "ankole:asset/"

    assert {:ok, [%{path: "assets/" <> _}]} = Files.list_files(converted_doc.id)

    # Source Word page remains intact.
    assert {:ok, %{id: source_id, type: :file, name: "Product Spec.docx"}} =
             Pages.fetch(word_page.id)

    assert source_id == word_page.id

    # A viewer who can read a shared Private Word Page cannot create siblings in the owner's Private space,
    # so conversion lands in the viewer's own Private space.
    {:ok, owner_private_word} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :word,
        title: "Private Memo",
        private_owner_uid: ctx.owner.uid
      })

    viewer = human_fixture(%{display_name: "Spec Reader"}).principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, owner_private_word.id, %{
        grants: [%{principal_uid: viewer.uid, role: "view"}]
      })

    viewer_actor = actor_fixture(viewer.uid)

    assert {:ok, %{page: private_doc}} =
             OfficeFiles.convert_to_document(viewer_actor, owner_private_word.id)

    assert private_doc.type == :doc
    assert private_doc.parent_id != owner_private_word.parent_id
    assert Ankole.Pod.private_owners([private_doc.id])[private_doc.id] == viewer.uid
  end

  test "commits keep one compaction wakeup that thresholds move to now", ctx do
    {:ok, _} = limits(%{"compaction_idle_seconds" => 600, "compaction_op_threshold" => 3})

    page = ctx.page
    args = %{"page_id" => page.id, "tenant_id" => Repo.tenant_id!()}

    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "1")))
    [job] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 500

    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("A2", "2")))
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("A3", "3")))
    [job] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1

    assert :ok = perform_job(CompactOfficeFile, args)

    refute Repo.exists?(
             from entry in OfficeOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    # Structural operations count against their own, lower threshold.
    {:ok, _} =
      limits(%{"compaction_idle_seconds" => 600, "compaction_structural_threshold" => 2})

    insert = %{
      "type" => "line.insert",
      "sheet_id" => 1,
      "axis" => "cols",
      "at" => 0,
      "count" => 1
    }

    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(4, "tab", 4, insert))
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(5, "tab", 5, set("A1", "x")))
    [job] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 500
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(6, "tab", 6, insert))
    [job] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1
  end

  test "a picture wakes compaction now and must leave the office file within the editing limit",
       ctx do
    {:ok, _} = limits(%{"compaction_idle_seconds" => 600})
    page = ctx.page
    args = %{"page_id" => page.id, "tenant_id" => Repo.tenant_id!()}
    {:ok, %{files: [%{size: size}]}} = Files.manifest(ctx.actor, page.id)
    png = Base.decode64!(@png)

    insert = fn image_id ->
      %{
        "type" => "image.insert",
        "sheet_id" => 1,
        "image_id" => image_id,
        "anchor" => %{"cell" => "B2", "width" => 64, "height" => 64},
        "picture" => %{"mime" => "image/png", "data" => @png}
      }
    end

    assert {:ok, %{revision: 2}} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, insert.(41)))

    [job] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1

    {:ok, _} = limits(%{"max_file_bytes" => size + byte_size(png) - 1})

    assert {:error, :office_full} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(2, "tab", 2, insert.(42)))

    # Compaction moves the picture from the log into the file.
    assert :ok = perform_job(CompactOfficeFile, args)

    refute Repo.exists?(
             from entry in OfficeOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    {:ok, _entry, bytes} = Files.read(ctx.actor, page.id, "Untitled.xlsx")
    assert Map.has_key?(package_parts(bytes), "xl/media/image1.png")
  end

  test "compaction writes the log into a new object, cache, history checkpoint, and pruned log",
       ctx do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 1)

    page = ctx.page
    created = object_id(page.id)
    assert :ok = OfficeFiles.flush_if_dirty(page.id)
    assert object_id(page.id) == created

    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "季度预算")))
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("A2", "华东区")))

    # Within the checkpoint interval of the created version, compaction keeps no checkpoint.
    assert :ok = OfficeFiles.flush_if_dirty(page.id)
    first = object_id(page.id)
    refute first == created
    assert {:ok, %{revision: 3}} = Pages.fetch(page.id)
    assert %{object_id: ^first, extract_status: :ok} = Repo.get_by!(FileCache, page_id: page.id)
    text = Repo.get_by!(PageSearchDocument, page_id: page.id).body_text
    assert text =~ "季度预算"
    assert text =~ "华东区"
    assert [%{reason: :created, object_id: ^created}] = versions(page.id)

    # The replay window keeps one revision, so compaction prunes every older entry.
    assert [%{revision: 3, compacted: true}] = entries(page.id)

    # Once the newest snapshot is older than the interval, compaction keeps a checkpoint.
    age_history(page.id)
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("A3", "x")))
    assert :ok = OfficeFiles.flush_if_dirty(page.id)
    second = object_id(page.id)

    assert [%{reason: :created}, %{reason: :checkpoint, revision: 4, object_id: ^second}] =
             versions(page.id)

    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(4, "tab", 4, set("A4", "y")))
    assert :ok = OfficeFiles.flush_if_dirty(page.id)
    refute object_id(page.id) == second
    assert length(versions(page.id)) == 2
    assert file_text(ctx.actor, page.id) =~ "y"
  end

  test "file reads write pending edits first, while a pinned digest keeps its bytes", ctx do
    page = ctx.page
    {:ok, created} = Drive.fetch_object(object_id(page.id))
    created = Base.encode16(created.sha256, case: :lower)

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "pinned")))

    # A pinned read pairs the bootstrapped file with its operations.
    refute file_text(ctx.actor, page.id, created) =~ "pinned"

    assert Repo.exists?(
             from entry in OfficeOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    assert file_text(ctx.actor, page.id) =~ "pinned"

    refute Repo.exists?(
             from entry in OfficeOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    assert {:error, :manifest_changed} = Files.read(ctx.actor, page.id, "Untitled.xlsx", created)

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("B1", "to file")))

    local = Drive.temp_path()
    on_exit(fn -> File.rm(local) end)
    assert {:ok, %{sha256: sha}} = Files.read_to_file(ctx.actor, page.id, "Untitled.xlsx", local)
    assert object_text(File.read!(local)) =~ "to file"

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("C1", "manifest")))

    assert {:ok, %{files: [%{sha256: listed}]}} = Files.manifest(ctx.actor, page.id)
    refute listed == sha
    assert file_text(ctx.actor, page.id, listed) =~ "manifest"

    # Drive readers, such as the Agent files.get RPC, flush through the content owner.
    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(4, "tab", 4, set("D1", "drive")))

    assert :ok = Ankole.Pod.flush_node(page.id)
    assert {:ok, bytes} = Drive.read_object(object_id(page.id))
    assert object_text(bytes) =~ "drive"
  end

  test "an uploaded replacement resets the log, keeps versions, and follows the new file", ctx do
    page = ctx.page

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "before upload")))

    # A replacement compares the object that the manifest listed after writing pending edits.
    base = manifest_object(ctx.actor, page.id)

    assert {:ok, %{file: %{path: "budget.xlsx"}}} =
             Files.upload(
               ctx.actor,
               page.id,
               "file",
               base,
               "budget.xlsx",
               workbook("uploaded 华北")
             )

    assert {:ok, %{revision: 3, name: "budget.xlsx"}} = Pages.fetch(page.id)

    assert [
             %{revision: 1, kind: :reset},
             %{revision: 2, kind: :op, compacted: true},
             %{revision: 3, kind: :reset, compacted: true}
           ] = entries(page.id)

    # The flush before the upload kept the edit in the replaced file's checkpoint.
    uploaded = object_id(page.id)

    assert [
             %{reason: :created},
             %{reason: :checkpoint, revision: 2, object_id: ^base, title: "Untitled.xlsx"},
             %{reason: :uploaded, revision: 3, object_id: ^uploaded, title: "budget.xlsx"}
           ] = versions(page.id)

    assert {:ok, edited_bytes} = Drive.read_object(base)
    assert object_text(edited_bytes) =~ "before upload"
    assert Repo.get_by!(PageSearchDocument, page_id: page.id).body_text =~ "uploaded 华北"

    assert {:ok, %{revision: 3, changes: [%{kind: :reset}], reset_required: true}} =
             OfficeFiles.since(ctx.actor, page.id, 2)

    assert {:ok, %{revision: 4, acknowledged_revision: 4}} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(3, "tab", 2, set("B1", "after")))

    base = manifest_object(ctx.actor, page.id)

    assert {:ok, _upload} =
             Files.upload(ctx.actor, page.id, "file", base, "notes.pdf", "%PDF not a workbook")

    {:ok, page} = Pages.fetch(page.id)
    assert page.revision == 5
    refute OfficeFiles.office_file?(page)
    refute Repo.get_by(FileCache, page_id: page.id)

    assert [_created, _checkpoint, _uploaded, %{reason: :checkpoint, object_id: ^base}] =
             versions(page.id)

    assert {:error, :invalid_page_type} = OfficeFiles.bootstrap(ctx.actor, page.id)
  end

  test "an Agent Drive write replaces the workbook through the same reset", ctx do
    page = ctx.page
    created = object_id(page.id)

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "pending")))

    assert {:ok, _file} = Ankole.Pod.write_node(ctx.actor, page.id, workbook("from the Agent"))
    replaced = object_id(page.id)

    assert [
             %{revision: 1, kind: :reset},
             %{revision: 2, kind: :op, compacted: true},
             %{revision: 3, kind: :reset}
           ] = entries(page.id)

    assert [
             %{reason: :created, object_id: ^created},
             %{reason: :uploaded, object_id: ^replaced}
           ] = versions(page.id)

    assert file_text(ctx.actor, page.id) =~ "from the Agent"
    assert Repo.get_by!(PageSearchDocument, page_id: page.id).body_text =~ "from the Agent"
    assert {:ok, %{revision: 3, ops: []}} = OfficeFiles.bootstrap(ctx.actor, page.id)
  end

  test "restoring a version names its object again through a reset with before and after versions",
       ctx do
    page = ctx.page
    [%{id: created_id, object_id: created}] = versions(page.id)

    {:ok, _} =
      OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "edited")))

    # An edit can commit after the restore's preflight flush and before it locks the page.
    assert {:error, :office_busy} =
             Ankole.Pod.Access.write_tree(
               nil,
               fn -> OfficeFiles.restore_in_tx(ctx.actor, page.id, created_id) end,
               root_ids: fn -> Ankole.Pod.root_ids([page.id]) end
             )

    assert [%{id: ^created_id}] = versions(page.id)
    assert %{revision: 2, compacted: false} = List.last(entries(page.id))

    assert {:ok,
            %{
              revision: 3,
              format: :spreadsheet,
              file: %{path: "Untitled.xlsx", object_id: ^created}
            }} =
             OfficeFiles.restore(ctx.actor, page.id, created_id)

    assert object_id(page.id) == created

    # The flush before the restore kept the edit in the before_restore version.
    assert [
             %{reason: :created},
             %{reason: :before_restore, revision: 2, object_id: edited},
             %{reason: :restored, revision: 3, object_id: ^created}
           ] = versions(page.id)

    refute edited == created
    assert {:ok, edited_bytes} = Drive.read_object(edited)
    assert object_text(edited_bytes) =~ "edited"
    assert %{kind: :reset, revision: 3} = List.last(entries(page.id))
    assert Repo.get_by!(FileCache, page_id: page.id).object_id == created
    refute file_text(ctx.actor, page.id) =~ "edited"

    assert {:ok, listed} = OfficeFiles.versions(ctx.actor, page.id)
    assert Enum.map(listed, & &1.reason) == [:restored, :before_restore, :created]
    assert Enum.all?(listed, &(is_binary(&1.sha256) and is_integer(&1.size)))
    reader = human_fixture().principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [
          %{principal_uid: ctx.editor.uid, role: "edit"},
          %{principal_uid: reader.uid, role: "view"}
        ]
      })

    assert {:error, :forbidden} = OfficeFiles.versions(actor_fixture(reader.uid), page.id)

    assert {:error, :forbidden} =
             OfficeFiles.restore(actor_fixture(reader.uid), page.id, created_id)

    assert {:error, :not_found} = OfficeFiles.restore(ctx.actor, page.id, Ecto.UUID.generate())
  end

  test "search finds spreadsheet text through the file cache in live and trash lists", ctx do
    page = ctx.page
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "独角兽指标")))
    assert :ok = OfficeFiles.flush_if_dirty(page.id)

    assert {:ok, %{pages: [%{id: id}]}} = Pages.search(ctx.actor, "独角兽")
    assert id == page.id
    assert {:ok, [%{id: ^id}]} = Pages.list(ctx.actor, %{query: "独角兽"})

    {:ok, _} = Pages.delete(ctx.actor, page.id)
    assert {:ok, [%{id: ^id}]} = Pages.list(ctx.actor, %{scope: "trash", query: "独角兽"})
    assert {:ok, []} = Pages.list(ctx.actor, %{scope: "trash", query: "不存在的文字"})
  end

  test "versions keep their objects through collection and purge removes every row", ctx do
    page = ctx.page
    [%{object_id: created}] = versions(page.id)
    {:ok, _} = OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "next")))
    assert :ok = OfficeFiles.flush_if_dirty(page.id)
    current = object_id(page.id)
    refute current == created

    old = DateTime.add(DateTime.utc_now(:microsecond), -2, :day)
    objects = from object in FileObject, where: object.id in ^[created, current]
    Repo.update_all(objects, set: [created_at: old])
    assert {:ok, 0} = Drive.collect_objects()
    assert {:ok, _bytes} = Drive.read_object(created)

    {:ok, _} = Pages.delete(ctx.actor, page.id)
    assert {:ok, _} = Pages.purge(ctx.actor, page.id)

    assert :ok =
             Ankole.Pod.Jobs.PurgeTree.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "node_id" => page.id}
             })

    for resource <- [OfficeOp, OfficeCheckpoint, FileCache, PageSearchDocument, PageSnapshot] do
      refute Repo.exists?(from row in resource, where: row.page_id == ^page.id)
    end

    assert {:ok, 2} = Drive.collect_objects()
    assert {:error, :not_found} = Drive.fetch_object(created)
  end

  test "an editor cannot open an office file above the configured size", ctx do
    {:ok, _} = limits(%{"max_file_bytes" => 10})

    {:ok, page} =
      OfficeFiles.create_blank(ctx.actor, %{
        format: :spreadsheet,
        private_owner_uid: ctx.owner.uid
      })

    assert {:error, :file_too_large} = OfficeFiles.bootstrap(ctx.actor, page.id)

    assert {:error, :file_too_large} =
             OfficeFiles.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "x")))

    # A workbook above the limit records a skipped extraction row so reconciliation never loops.
    assert %FileCache{
             subtype: :spreadsheet,
             extract_status: :skipped,
             extract_error: "file_too_large"
           } = Repo.get_by!(FileCache, page_id: page.id)

    assert Repo.get_by!(PageSearchDocument, page_id: page.id).body_text == ""
    assert [%{reason: :created}] = versions(page.id)

    assert {:error, _invalid} =
             Ankole.AppConfigure.put_tenant_by_key("pod.office.limits", %{
               "max_file_bytes" => 1
             })
  end
end
