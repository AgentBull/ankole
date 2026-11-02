defmodule Ankole.Pod.SpreadsheetsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.Files, as: Drive
  alias Ankole.Files.Schemas.FileObject
  alias Ankole.Kernel
  alias Ankole.Pod.{FileCache, Files, Pages, PageSnapshot, Spreadsheets, SpreadsheetOp}
  alias Ankole.Pod.Jobs.CompactSpreadsheet

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
    {:ok, page} = Spreadsheets.create_blank(actor, %{private_owner_uid: owner.uid})

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
        "pod.spreadsheet.limits",
        Map.merge(@limits, overrides)
      )

  defp file_text(actor, page_id, digest \\ nil) do
    {:ok, _entry, bytes} = Files.read(actor, page_id, "Untitled.xlsx", digest)
    object_text(bytes)
  end

  defp object_text(bytes) do
    {:ok, %{plain_text: text}} = Kernel.spreadsheet_open(bytes, [])
    text
  end

  defp workbook(text) do
    {:ok, %{doc_ref: doc}} = Kernel.spreadsheet_create_blank("Upload")
    {:ok, %{doc_ref: doc}} = Kernel.spreadsheet_apply(doc, set("A1", text), [])
    {:ok, %{xlsx_bytes: bytes}} = Kernel.spreadsheet_export_xlsx(doc)
    bytes
  end

  defp entries(page_id),
    do:
      SpreadsheetOp
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
    {:ok, node} = Drive.fetch_node(page_id)
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

  test "a blank spreadsheet commits its file, cache, created version, and reset entry together",
       ctx do
    page = ctx.page
    assert page.type == :file
    assert page.name == "Untitled.xlsx"
    assert page.revision == 1
    assert Spreadsheets.spreadsheet?(page)
    assert Spreadsheets.spreadsheet?("Budget.XLSM")
    assert Spreadsheets.spreadsheet?("Budget.xlsx (2)")
    refute Spreadsheets.spreadsheet?("Budget.xls")
    refute Spreadsheets.spreadsheet?("Budget.xlsx.pdf")

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

    assert %FileCache{subtype: :spreadsheet, object_id: ^object, plain_text: "Sheet1\n"} =
             Repo.get_by!(FileCache, page_id: page.id)

    assert {:ok,
            %{
              page_id: page_id,
              revision: 1,
              file: %{path: "Untitled.xlsx", object_id: ^object, sha256: hex},
              ops: [],
              metadata: %{"sheets" => [%{"sheet_id" => 1, "name" => "Sheet1"}]}
            }} = Spreadsheets.bootstrap(ctx.actor, page.id)

    assert page_id == page.id
    {:ok, stored} = Drive.fetch_object(object)
    assert hex == Base.encode16(stored.sha256, case: :lower)

    {:ok, named} =
      Spreadsheets.create_blank(ctx.actor, %{title: "Q4 预算", private_owner_uid: ctx.owner.uid})

    assert named.name == "Q4 预算.xlsx"
    assert {:ok, [%{path: "Q4 预算.xlsx"}]} = Files.list_files(named.id)

    # A second blank workbook in the same folder takes Drive's duplicate name and stays editable.
    {:ok, second} = Spreadsheets.create_blank(ctx.actor, %{private_owner_uid: ctx.owner.uid})
    assert second.name == "Untitled.xlsx (1)"
    assert {:ok, %{revision: 1}} = Spreadsheets.bootstrap(ctx.actor, second.id)
  end

  test "the operation log rejects malformed entries and snapshots name content or an object",
       ctx do
    now = DateTime.utc_now(:microsecond)
    author = to_string(Ankole.ActorRef.from_actor(ctx.actor))

    assert {:error, %Postgrex.Error{postgres: %{constraint: "pod_spreadsheet_ops_entry_shape"}}} =
             Repo.query(
               "INSERT INTO pod_spreadsheet_ops (tenant_id, page_id, revision, kind, client_id, client_seq, op, author, created_at) VALUES ($1::text::uuid, $2::text::uuid, 9, 'op', 'c', 1, '{}'::jsonb, $3, $4)",
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
             Spreadsheets.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "季度预算"))
             )

    assert %{revision: 2, kind: :op, op: %{"cell" => "A1"}, compacted: false} = first

    assert {:ok, %{revision: 2, acknowledged_revision: 2}} =
             Spreadsheets.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "季度预算"))
             )

    assert {:error, :client_sequence_conflict} =
             Spreadsheets.apply_op(
               ctx.actor,
               page.id,
               request(1, "owner-tab", 1, set("A1", "other"))
             )

    assert {:ok, %{revision: 3, acknowledged_revision: 3, changes: [missed, own]}} =
             Spreadsheets.apply_op(editor, page.id, request(1, "editor-tab", 1, set("B1", "2")))

    assert missed.revision == 2
    assert %{revision: 3, client_id: "editor-tab", op: %{"cell" => "B1"}} = own
    assert length(entries(page.id)) == 3

    assert {:error, :invalid_request} =
             Spreadsheets.apply_op(editor, page.id, request(1, "editor-tab", 0, set("B1", "2")))

    assert {:error, {:invalid_operation, message}} =
             Spreadsheets.apply_op(editor, page.id, request(3, "editor-tab", 2, set("ZZZ0", "x")))

    assert message =~ "cell"

    assert {:ok, %{revision: 4, changes: [%{op: %{"author" => "Editor Name"}}]}} =
             Spreadsheets.apply_op(
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
             Spreadsheets.since(editor, page.id, 2)

    assert {:ok, %{reset_required: true}} = Spreadsheets.since(editor, page.id, 9)

    assert {:ok, %{ops: ops}} = Spreadsheets.bootstrap(editor, page.id)
    assert Enum.map(ops, & &1.revision) == [2, 3, 4]

    reader = actor_fixture(human_fixture().principal)

    assert {:error, _denied} =
             Spreadsheets.apply_op(reader, page.id, request(4, "reader-tab", 1, set("C1", "x")))
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
             Spreadsheets.apply_op(ctx.actor, page.id, request(1, "owner-tab", 1, insert))

    assert {:ok, %{revision: 3, changes: [%{op: %{"type" => "line.insert"}}, %{op: committed}]}} =
             Spreadsheets.apply_op(
               editor,
               page.id,
               request(1, "editor-tab", 1, set("C5", "=SUM(B1:B5)"))
             )

    assert %{"cell" => "C8", "input" => "=SUM(B1:B8)"} = committed

    assert {:ok, %{ops: [%{op: %{"type" => "line.insert"}}, %{op: %{"cell" => "C8"}}]}} =
             Spreadsheets.bootstrap(editor, page.id)
  end

  test "a conflicting rebase is rejected with the changes the author missed", ctx do
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
             Spreadsheets.apply_op(ctx.actor, page.id, request(1, "owner-tab", 1, delete))

    assert {:error,
            {:spreadsheet_conflict,
             %{
               reason: :target_deleted,
               revision: 2,
               changes: [%{"revision" => 2, "op" => %{"type" => "line.delete"}}]
             }}} =
             Spreadsheets.apply_op(
               editor,
               page.id,
               request(1, "editor-tab", 1, set("A2", "lost"))
             )

    assert {:ok, %{revision: 2}} = Pages.fetch(page.id)

    assert %{
             code: "spreadsheet_conflict",
             details: %{"reason" => "target_deleted", "revision" => 2, "changes" => []}
           } =
             Ankole.Pod.Serialization.error(
               {:spreadsheet_conflict, %{reason: :target_deleted, revision: 2, changes: []}}
             )

    assert Ankole.Pod.Serialization.status("spreadsheet_conflict") == 409
  end

  test "commits keep one compaction wakeup that thresholds move to now", ctx do
    {:ok, _} = limits(%{"compaction_idle_seconds" => 600, "compaction_op_threshold" => 3})

    page = ctx.page
    args = %{"page_id" => page.id, "tenant_id" => Repo.tenant_id!()}

    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "1")))
    [job] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 500

    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("A2", "2")))
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("A3", "3")))
    [job] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1

    assert :ok = perform_job(CompactSpreadsheet, args)

    refute Repo.exists?(
             from entry in SpreadsheetOp, where: entry.page_id == ^page.id and not entry.compacted
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

    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(4, "tab", 4, insert))
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(5, "tab", 5, set("A1", "x")))
    [job] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 500
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(6, "tab", 6, insert))
    [job] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1
  end

  test "a picture wakes compaction now and must leave the workbook within the editing limit",
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
             Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, insert.(41)))

    [job] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1

    {:ok, _} = limits(%{"max_file_bytes" => size + byte_size(png) - 1})

    assert {:error, :spreadsheet_full} =
             Spreadsheets.apply_op(ctx.actor, page.id, request(2, "tab", 2, insert.(42)))

    # Compaction moves the picture from the log into the file.
    assert :ok = perform_job(CompactSpreadsheet, args)

    refute Repo.exists?(
             from entry in SpreadsheetOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    {:ok, _entry, bytes} = Files.read(ctx.actor, page.id, "Untitled.xlsx")
    assert Map.has_key?(package_parts(bytes), "xl/media/image1.png")
  end

  test "compaction writes the log into a new object, cache, history checkpoint, and pruned log",
       ctx do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 1)

    page = ctx.page
    created = object_id(page.id)
    assert :ok = Spreadsheets.flush_if_dirty(page.id)
    assert object_id(page.id) == created

    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "季度预算")))
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("A2", "华东区")))

    # Within the checkpoint interval of the created version, compaction keeps no checkpoint.
    assert :ok = Spreadsheets.flush_if_dirty(page.id)
    first = object_id(page.id)
    refute first == created
    assert {:ok, %{revision: 3}} = Pages.fetch(page.id)
    assert %{object_id: ^first, plain_text: text} = Repo.get_by!(FileCache, page_id: page.id)
    assert text =~ "季度预算"
    assert text =~ "华东区"
    assert [%{reason: :created, object_id: ^created}] = versions(page.id)

    # The replay window keeps one revision, so compaction prunes every older entry.
    assert [%{revision: 3, compacted: true}] = entries(page.id)

    # Once the newest snapshot is older than the interval, compaction keeps a checkpoint.
    age_history(page.id)
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("A3", "x")))
    assert :ok = Spreadsheets.flush_if_dirty(page.id)
    second = object_id(page.id)

    assert [%{reason: :created}, %{reason: :checkpoint, revision: 4, object_id: ^second}] =
             versions(page.id)

    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(4, "tab", 4, set("A4", "y")))
    assert :ok = Spreadsheets.flush_if_dirty(page.id)
    refute object_id(page.id) == second
    assert length(versions(page.id)) == 2
    assert file_text(ctx.actor, page.id) =~ "y"
  end

  test "file reads write pending edits first, while a pinned digest keeps its bytes", ctx do
    page = ctx.page
    {:ok, created} = Drive.fetch_object(object_id(page.id))
    created = Base.encode16(created.sha256, case: :lower)

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "pinned")))

    # A pinned read pairs the bootstrapped file with its operations.
    refute file_text(ctx.actor, page.id, created) =~ "pinned"

    assert Repo.exists?(
             from entry in SpreadsheetOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    assert file_text(ctx.actor, page.id) =~ "pinned"

    refute Repo.exists?(
             from entry in SpreadsheetOp, where: entry.page_id == ^page.id and not entry.compacted
           )

    assert {:error, :manifest_changed} = Files.read(ctx.actor, page.id, "Untitled.xlsx", created)

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(2, "tab", 2, set("B1", "to file")))

    local = Drive.temp_path()
    on_exit(fn -> File.rm(local) end)
    assert {:ok, %{sha256: sha}} = Files.read_to_file(ctx.actor, page.id, "Untitled.xlsx", local)
    assert object_text(File.read!(local)) =~ "to file"

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(3, "tab", 3, set("C1", "manifest")))

    assert {:ok, %{files: [%{sha256: listed}]}} = Files.manifest(ctx.actor, page.id)
    refute listed == sha
    assert file_text(ctx.actor, page.id, listed) =~ "manifest"

    # Drive readers, such as the Agent files.get RPC, flush through the content owner.
    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(4, "tab", 4, set("D1", "drive")))

    assert :ok = Ankole.Files.ContentOwner.flush_node(page.id)
    assert {:ok, bytes} = Drive.read_object(object_id(page.id))
    assert object_text(bytes) =~ "drive"
  end

  test "an uploaded replacement resets the log, keeps versions, and follows the new file", ctx do
    page = ctx.page

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "before upload")))

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
    assert Repo.get_by!(FileCache, page_id: page.id).plain_text =~ "uploaded 华北"

    assert {:ok, %{revision: 3, changes: [%{kind: :reset}], reset_required: true}} =
             Spreadsheets.since(ctx.actor, page.id, 2)

    assert {:ok, %{revision: 4, acknowledged_revision: 4}} =
             Spreadsheets.apply_op(ctx.actor, page.id, request(3, "tab", 2, set("B1", "after")))

    base = manifest_object(ctx.actor, page.id)

    assert {:ok, _upload} =
             Files.upload(ctx.actor, page.id, "file", base, "notes.pdf", "%PDF not a workbook")

    {:ok, page} = Pages.fetch(page.id)
    assert page.revision == 5
    refute Spreadsheets.spreadsheet?(page)
    refute Repo.get_by(FileCache, page_id: page.id)

    assert [_created, _checkpoint, _uploaded, %{reason: :checkpoint, object_id: ^base}] =
             versions(page.id)

    assert {:error, :invalid_page_type} = Spreadsheets.bootstrap(ctx.actor, page.id)
  end

  test "an Agent Drive write replaces the workbook through the same reset", ctx do
    page = ctx.page
    created = object_id(page.id)

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "pending")))

    assert {:ok, _file} = Drive.write_node(ctx.actor, page.id, workbook("from the Agent"))
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
    assert Repo.get_by!(FileCache, page_id: page.id).plain_text =~ "from the Agent"
    assert {:ok, %{revision: 3, ops: []}} = Spreadsheets.bootstrap(ctx.actor, page.id)
  end

  test "restoring a version names its object again through a reset with before and after versions",
       ctx do
    page = ctx.page
    [%{id: created_id, object_id: created}] = versions(page.id)

    {:ok, _} =
      Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "edited")))

    assert {:ok, %{revision: 3, file: %{path: "Untitled.xlsx", object_id: ^created}}} =
             Spreadsheets.restore(ctx.actor, page.id, created_id)

    assert object_id(page.id) == created

    # The flush before the restore kept the edit in the before_restore version.
    assert [
             %{reason: :created},
             %{reason: :before_restore, revision: 2, object_id: edited},
             %{reason: :restored, revision: 3, object_id: ^created}
           ] = versions(page.id)

    refute edited == created
    assert %{kind: :reset, revision: 3} = List.last(entries(page.id))
    assert Repo.get_by!(FileCache, page_id: page.id).object_id == created
    refute file_text(ctx.actor, page.id) =~ "edited"

    assert {:ok, listed} = Spreadsheets.versions(ctx.actor, page.id)
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

    assert {:error, :forbidden} = Spreadsheets.versions(actor_fixture(reader.uid), page.id)

    assert {:error, :forbidden} =
             Spreadsheets.restore(actor_fixture(reader.uid), page.id, created_id)

    assert {:error, :not_found} = Spreadsheets.restore(ctx.actor, page.id, Ecto.UUID.generate())
  end

  test "search finds spreadsheet text through the file cache in live and trash lists", ctx do
    page = ctx.page
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "独角兽指标")))
    assert :ok = Spreadsheets.flush_if_dirty(page.id)

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
    {:ok, _} = Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "next")))
    assert :ok = Spreadsheets.flush_if_dirty(page.id)
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
             Ankole.Files.Jobs.PurgeNode.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "node_id" => page.id}
             })

    for resource <- [SpreadsheetOp, FileCache, PageSnapshot] do
      refute Repo.exists?(from row in resource, where: row.page_id == ^page.id)
    end

    assert {:ok, 2} = Drive.collect_objects()
    assert {:error, :not_found} = Drive.fetch_object(created)
  end

  test "an editor cannot open a workbook above the configured size", ctx do
    {:ok, _} = limits(%{"max_file_bytes" => 10})

    {:ok, page} = Spreadsheets.create_blank(ctx.actor, %{private_owner_uid: ctx.owner.uid})
    assert {:error, :file_too_large} = Spreadsheets.bootstrap(ctx.actor, page.id)

    assert {:error, :file_too_large} =
             Spreadsheets.apply_op(ctx.actor, page.id, request(1, "tab", 1, set("A1", "x")))

    # A workbook above the limit keeps its version but gets no search cache.
    refute Repo.get_by(FileCache, page_id: page.id)
    assert [%{reason: :created}] = versions(page.id)

    assert {:error, _invalid} =
             Ankole.AppConfigure.put_tenant_by_key("pod.spreadsheet.limits", %{
               "max_file_bytes" => 1
             })
  end
end
