defmodule Ankole.Pod.CopyRegressionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Database, DbRecord, Pages}

  setup do
    allow_cache_database_access()
    uid = human_fixture().principal.uid
    {:ok, page} = Pages.create(uid, %{type: "database", title: "Copy source"})
    {:ok, table} = Database.create_table(uid, page.id, %{name: "Source"})
    primary = Enum.find(Database.fields(table.id), & &1.is_primary)
    %{uid: uid, page: page, table: table, primary: primary}
  end

  test "copy changes only typed field references, preserving UUID-valued business text", ctx do
    {:ok, echo} = field(ctx, "Echo", "formula", %{"source" => "[Name] & \"#{ctx.primary.id}\""})

    {:ok, _} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [%{data: %{ctx.primary.id => ctx.primary.id}}]
      })

    config = %{
      "visible_fields" => [ctx.primary.id, echo.id],
      "group_field_id" => ctx.primary.id,
      "filter" => %{
        "conditions" => [
          %{"field_id" => ctx.primary.id, "operator" => "is", "value" => ctx.primary.id}
        ]
      },
      "sort" => [%{"field_id" => ctx.primary.id, "direction" => "asc"}],
      "custom" => %{ctx.primary.id => ctx.primary.id}
    }

    {:ok, _} =
      Database.create_view(ctx.uid, ctx.table.id, %{name: "Exact", type: "grid", config: config})

    assert {:ok, copied} = Database.copy_table(ctx.uid, ctx.table.id, %{})
    assert {:ok, schema} = Database.get_table(ctx.uid, copied.table.id)
    fields = Map.new(schema.fields, &{&1.name, &1})
    view = Enum.find(schema.views, &(&1.name == "Exact"))
    new_id = fields["Name"].id
    assert view.config["visible_fields"] == [new_id, fields["Echo"].id]
    assert view.config["group_field_id"] == new_id
    assert view.config["custom"] == config["custom"]
    assert view.config["sort"] == [%{"field_id" => new_id, "direction" => "asc"}]

    assert view.config["filter"]["conditions"] == [
             %{"field_id" => new_id, "operator" => "is", "value" => ctx.primary.id}
           ]

    assert {:ok, %{records: [row]}} =
             Database.query(ctx.uid, copied.table.id, %{filter: view.config["filter"]})

    assert row["data"][fields["Echo"].id] == ctx.primary.id <> ctx.primary.id
    refute Map.has_key?(Repo.get_by!(DbRecord, id: row["id"]).data, fields["Echo"].id)
  end

  test "mixed array formulas recompute only from copied users, attachments, and select values",
       ctx do
    {:ok, flag} = field(ctx, "Flag", "checkbox")
    {:ok, owners} = field(ctx, "Owners", "user")
    {:ok, files} = field(ctx, "Files", "attachment")

    {:ok, tags} =
      field(ctx, "Tags", "select", %{
        "multiple" => true,
        "options" => [%{"id" => "tag", "name" => "Tag"}]
      })

    {:ok, _} = field(ctx, "Mixed", "formula", %{"source" => "IF([Flag], [Owners], [Files])"})
    {:ok, _} = field(ctx, "Selected", "formula", %{"source" => "[Tags]"})

    {:ok, uploaded} =
      Ankole.Pod.Files.upload(
        ctx.uid,
        ctx.page.id,
        "attachment",
        nil,
        "a.txt",
        "bytes",
        "text/plain"
      )

    value = [
      %{
        "path" => "pages/#{ctx.page.id}/#{uploaded.file.path}",
        "name" => "a.txt",
        "mime" => "text/plain",
        "size" => uploaded.file.size
      }
    ]

    {:ok, %{records: [original]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [
          %{
            data: %{
              flag.id => true,
              owners.id => [ctx.uid],
              files.id => value,
              tags.id => ["tag"]
            }
          }
        ]
      })

    assert {:ok, copied} = Database.copy_table(ctx.uid, ctx.table.id, %{})
    fields = Map.new(Database.fields(copied.table.id), &{&1.name, &1})
    assert {:ok, %{records: [row]}} = Database.query(ctx.uid, copied.table.id, %{})
    assert row["data"][fields["Mixed"].id] == [ctx.uid]
    assert row["data"][fields["Selected"].id] == ["tag"]

    assert {:ok, _} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               updates: [
                 %{
                   id: original.id,
                   data: %{owners.id => nil},
                   expected_versions: %{owners.id => 1}
                 }
               ]
             })

    assert {:ok, %{records: [row]}} = Database.query(ctx.uid, copied.table.id, %{})
    assert row["data"][fields["Mixed"].id] == [ctx.uid]

    assert {:ok, _} =
             Database.write_records(ctx.uid, copied.table.id, %{
               updates: [
                 %{
                   id: row["id"],
                   data: %{fields["Flag"].id => false},
                   expected_versions: %{fields["Flag"].id => 1}
                 }
               ]
             })

    assert {:ok, %{records: [row]}} = Database.query(ctx.uid, copied.table.id, %{})
    assert row["data"][fields["Mixed"].id] == row["data"][fields["Files"].id]
    path = hd(row["data"][fields["Mixed"].id])["path"]
    assert String.starts_with?(path, "pages/#{copied.page.id}/attachments/")
    assert {:ok, _} = Ankole.Files.fetch(:pod, path)
  end

  test "links become independent multi-select snapshots without changing array formula values",
       ctx do
    {:ok, related} = Database.create_table(ctx.uid, ctx.page.id, %{name: "Related"})
    related_name = Enum.find(Database.fields(related.id), & &1.is_primary)

    {:ok, %{records: [a, b]}} =
      Database.write_records(ctx.uid, related.id, %{
        creates: [%{data: %{related_name.id => "Alpha"}}, %{data: %{}}]
      })

    {:ok, one} = field(ctx, "One", "link", %{"table_id" => related.id, "multiple" => false})

    {:ok, many} =
      field(ctx, "Many", "link", %{
        "table_id" => related.id,
        "multiple" => true,
        "bidirectional" => true
      })

    {:ok, empty} = Database.create_table(ctx.uid, ctx.page.id, %{name: "Empty"})
    {:ok, _} = field(ctx, "Empty", "link", %{"table_id" => empty.id})
    {:ok, _} = field(ctx, "Selected", "formula", %{"source" => "[Many]"})

    {:ok, _} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [%{data: %{one.id => [a.id], many.id => [a.id, b.id]}}, %{data: %{}}]
      })

    assert {:ok, copied} = Database.copy_table(ctx.uid, ctx.table.id, %{})
    fields = Map.new(Database.fields(copied.table.id), &{&1.name, &1})
    assert fields["Empty"].type == :select
    assert fields["Empty"].config == %{"multiple" => true, "options" => []}

    for name <- ["One", "Many"] do
      assert fields[name].type == :select

      assert fields[name].config == %{
               "multiple" => true,
               "options" => [%{"id" => a.id, "name" => "Alpha"}, %{"id" => b.id, "name" => ""}]
             }
    end

    b = Repo.get_by!(DbRecord, id: b.id)

    assert {:ok, _} =
             Database.write_records(ctx.uid, related.id, %{
               updates: [
                 %{
                   id: a.id,
                   data: %{related_name.id => "Changed"},
                   expected_versions: %{related_name.id => 1}
                 }
               ],
               deletes: [%{id: b.id, expected_versions: b.versions}]
             })

    assert {:ok, %{records: rows}} = Database.query(ctx.uid, copied.table.id, %{})
    full = Enum.find(rows, & &1["data"][fields["One"].id])
    assert full["data"][fields["One"].id] == [a.id]
    assert full["data"][fields["Many"].id] == [a.id, b.id]
    assert full["data"][fields["Selected"].id] == [a.id, b.id]
    assert Enum.any?(rows, &is_nil(&1["data"][fields["Many"].id]))

    assert {:ok, _} =
             Database.write_records(ctx.uid, copied.table.id, %{
               updates: [
                 %{
                   id: full["id"],
                   data: %{fields["Many"].id => [b.id]},
                   expected_versions: %{fields["Many"].id => 1}
                 }
               ]
             })
  end

  defp field(ctx, name, type, config \\ %{}),
    do: Database.create_field(ctx.uid, ctx.table.id, %{name: name, type: type, config: config})
end
