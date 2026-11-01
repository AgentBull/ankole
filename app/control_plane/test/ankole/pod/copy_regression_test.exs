defmodule Ankole.Pod.CopyRegressionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Bases, BaseRecord, Formula, Pages}

  setup do
    uid = human_fixture().principal.uid

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        type: "base",
        title: "Copy source"
      })

    {:ok, table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, %{
        name: "Source"
      })

    primary = Enum.find(Bases.fields(table.id), & &1.is_primary)
    %{uid: uid, page: page, table: table, primary: primary}
  end

  test "a filtered copy snapshots only referenced labels as independent text", ctx do
    actor = actor_fixture(ctx.uid)
    {:ok, target} = Bases.create_table(actor, ctx.page.id, %{name: "Customers"})
    title = Enum.find(Bases.fields(target.id), & &1.is_primary)

    {:ok, %{records: [used, second, excluded, _unused]}} =
      Bases.write_records(actor, target.id, %{
        creates: Enum.map(["Used", "Second", "Excluded", "Unused"], &%{data: %{title.id => &1}})
      })

    {:ok, link} = field(ctx, "Customer", "link", %{"table_id" => target.id})

    {:ok, _} =
      Bases.write_records(actor, ctx.table.id, %{
        creates: [
          %{data: %{ctx.primary.id => "Copy full", link.id => [second.id, used.id]}},
          %{data: %{ctx.primary.id => "Copy empty"}},
          %{data: %{ctx.primary.id => "Skip", link.id => [excluded.id]}}
        ]
      })

    assert {:ok, copied} =
             Bases.copy_table(actor, ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: ctx.primary.id, operator: "text_contains", value: "Copy"}
                 ]
               }
             })

    copied_link = Enum.find(Bases.fields(copied.table.id), &(&1.name == "Customer"))
    assert copied_link.type == :text
    assert copied_link.config == %{}

    assert copied.table.record_count == 2
    assert copied.table.storage_mode == :inline
    assert {:ok, %{tables: [only_table]}} = Bases.list_tables(actor, copied.page.id)
    assert only_table.id == copied.table.id
    assert {:ok, %{records: rows}} = Bases.query(actor, copied.table.id, %{})
    assert Enum.map(rows, & &1["data"][copied_link.id]) |> Enum.sort() == [nil, "Second, Used"]

    assert {:ok, _} =
             Bases.write_records(actor, target.id, %{
               updates: [
                 %{
                   id: used.id,
                   data: %{title.id => "Changed"},
                   expected_versions: %{title.id => 1}
                 }
               ]
             })

    assert {:ok, %{records: rows}} = Bases.query(actor, copied.table.id, %{})
    assert Enum.any?(rows, &(&1["data"][copied_link.id] == "Second, Used"))
  end

  test "copy changes only typed field references, preserving UUID-valued business text", ctx do
    {:ok, echo} = field(ctx, "Echo", "formula", %{"source" => "[Name] & \"#{ctx.primary.id}\""})

    {:ok, _} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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
      Bases.create_view(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Exact",
        type: "grid",
        config: config
      })

    assert {:ok, copied} =
             Bases.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{}
             )

    assert {:ok, schema} =
             Bases.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), copied.table.id)

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
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), copied.table.id, %{
               filter: view.config["filter"]
             })

    assert row["data"][fields["Echo"].id] == ctx.primary.id <> ctx.primary.id
    refute Map.has_key?(Repo.get_by!(BaseRecord, id: row["id"]).data, fields["Echo"].id)
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
        Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
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
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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

    assert {:ok, copied} =
             Bases.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{}
             )

    fields = Map.new(Bases.fields(copied.table.id), &{&1.name, &1})

    assert {:ok, %{records: [row]}} =
             Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert row["data"][fields["Mixed"].id] == [ctx.uid]
    assert row["data"][fields["Selected"].id] == ["tag"]

    assert {:ok, _} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{
                     id: original.id,
                     data: %{owners.id => nil},
                     expected_versions: %{owners.id => 1}
                   }
                 ]
               }
             )

    assert {:ok, %{records: [row]}} =
             Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert row["data"][fields["Mixed"].id] == [ctx.uid]

    assert {:ok, _} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{
                 updates: [
                   %{
                     id: row["id"],
                     data: %{fields["Flag"].id => false},
                     expected_versions: %{fields["Flag"].id => 1}
                   }
                 ]
               }
             )

    assert {:ok, %{records: [row]}} =
             Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert row["data"][fields["Mixed"].id] == row["data"][fields["Files"].id]
    path = hd(row["data"][fields["Mixed"].id])["path"]
    assert String.starts_with?(path, "pages/#{copied.page.id}/attachments/")

    assert {:ok, copied_file} =
             Ankole.Pod.Files.fetch_file(
               copied.page.id,
               String.replace_prefix(path, "pages/#{copied.page.id}/", "")
             )

    assert {:ok, original_file} = Ankole.Pod.Files.fetch_file(ctx.page.id, uploaded.file.path)
    assert copied_file.object_id == original_file.object_id
    assert {:ok, "bytes"} = Ankole.Files.read_object(copied_file.object_id)
  end

  test "links become independent text and their formulas adopt the copied value type",
       ctx do
    {:ok, related} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "Related"
      })

    related_name = Enum.find(Bases.fields(related.id), & &1.is_primary)

    {:ok, %{records: [a, b]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), related.id, %{
        creates: [%{data: %{related_name.id => "Alpha"}}, %{data: %{}}]
      })

    {:ok, one} = field(ctx, "One", "link", %{"table_id" => related.id, "multiple" => false})

    {:ok, many} =
      field(ctx, "Many", "link", %{
        "table_id" => related.id,
        "multiple" => true,
        "bidirectional" => true
      })

    {:ok, empty} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "Empty"
      })

    {:ok, _} = field(ctx, "Empty", "link", %{"table_id" => empty.id})
    {:ok, _} = field(ctx, "Selected", "formula", %{"source" => "[Many]"})

    {:ok, _} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{one.id => [a.id], many.id => [a.id, b.id]}}, %{data: %{}}]
      })

    assert {:ok, copied} =
             Bases.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{}
             )

    fields = Map.new(Bases.fields(copied.table.id), &{&1.name, &1})

    for name <- ["Empty", "One", "Many"] do
      assert fields[name].type == :text
      assert fields[name].config == %{}
    end

    assert fields["Selected"].type == :formula
    assert fields["Selected"].config["result_type"] == "text"
    assert {:ok, _} = Formula.validate_all(Map.values(fields))

    {:ok, %{records: [b]}} =
      Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), related.id, %{ids: [b.id]})

    b = %{id: b["id"], versions: b["versions"]}

    assert {:ok, _} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               related.id,
               %{
                 updates: [
                   %{
                     id: a.id,
                     data: %{related_name.id => "Changed"},
                     expected_versions: %{related_name.id => 1}
                   }
                 ],
                 deletes: [%{id: b.id, expected_versions: b.versions}]
               }
             )

    assert {:ok, %{records: rows}} =
             Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    full = Enum.find(rows, & &1["data"][fields["One"].id])
    assert full["data"][fields["One"].id] == "Alpha"
    assert full["data"][fields["Many"].id] == "Alpha, "
    assert full["data"][fields["Selected"].id] == "Alpha, "
    assert Enum.any?(rows, &is_nil(&1["data"][fields["Many"].id]))

    assert {:ok, _} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{
                 updates: [
                   %{
                     id: full["id"],
                     data: %{fields["Many"].id => "Local title"},
                     expected_versions: %{fields["Many"].id => 1}
                   }
                 ]
               }
             )

    assert {:ok, %{records: [updated]}} =
             Bases.query(actor_fixture(ctx.uid), copied.table.id, %{ids: [full["id"]]})

    assert updated["data"][fields["Selected"].id] == "Local title"
  end

  test "mixed link formulas materialize their source values and revalidate downstream formulas",
       ctx do
    actor = actor_fixture(ctx.uid)
    {:ok, related} = Bases.create_table(actor, ctx.page.id, %{name: "Related"})
    related_name = Enum.find(Bases.fields(related.id), & &1.is_primary)

    {:ok, %{records: [target]}} =
      Bases.write_records(actor, related.id, %{
        creates: [%{data: %{related_name.id => "Target"}}]
      })

    {:ok, link} = field(ctx, "Related", "link", %{"table_id" => related.id})
    {:ok, flag} = field(ctx, "Flag", "checkbox")
    {:ok, owners} = field(ctx, "Owners", "user")
    {:ok, files} = field(ctx, "Files", "attachment")

    {:ok, tags} =
      field(ctx, "Tags", "select", %{
        "multiple" => true,
        "options" => [%{"id" => "tag", "name" => "Tag"}]
      })

    for name <- ["Owners", "Files", "Tags"] do
      {:ok, _} =
        field(ctx, "Mixed #{name}", "formula", %{"source" => "IF([Flag], [Related], [#{name}])"})
    end

    {:ok, _} = field(ctx, "Alias", "formula", %{"source" => "[Mixed Owners]"})
    {:ok, _} = field(ctx, "Same Owners", "formula", %{"source" => "[Mixed Owners] = [Owners]"})

    {:ok, uploaded} =
      Ankole.Pod.Files.upload(
        actor,
        ctx.page.id,
        "attachment",
        nil,
        "a.txt",
        "bytes",
        "text/plain"
      )

    attachments = [
      %{
        "path" => "pages/#{ctx.page.id}/#{uploaded.file.path}",
        "name" => "a.txt",
        "mime" => "text/plain",
        "size" => uploaded.file.size
      }
    ]

    {:ok, _} =
      Bases.write_records(actor, ctx.table.id, %{
        creates:
          Enum.map([true, false], fn enabled ->
            %{
              data: %{
                ctx.primary.id => to_string(enabled),
                flag.id => enabled,
                link.id => [target.id],
                owners.id => [ctx.uid],
                files.id => attachments,
                tags.id => ["tag"]
              }
            }
          end)
      })

    source_fields = Map.new(Bases.fields(ctx.table.id), &{&1.name, &1})
    {:ok, %{records: originals}} = Bases.query(actor, ctx.table.id, %{})
    originals = Map.new(originals, &{&1["data"][ctx.primary.id], &1["data"]})

    assert {:ok, copy} = Bases.copy_table(actor, ctx.table.id, %{})
    fields = Map.new(Bases.fields(copy.table.id), &{&1.name, &1})
    assert {:ok, checked} = Formula.validate_all(Map.values(fields))
    assert Enum.all?(checked, fn field -> field.config == fields[field.name].config end)
    assert fields["Alias"].type == :formula
    assert fields["Alias"].config["result_type"] == "text"
    assert fields["Same Owners"].type == :checkbox
    assert fields["Same Owners"].config == %{}
    assert {:ok, %{records: rows}} = Bases.query(actor, copy.table.id, %{})

    for row <- rows do
      original = originals[row["data"][fields["Name"].id]]

      for name <- ["Mixed Owners", "Mixed Files", "Mixed Tags"] do
        assert fields[name].type == :text
        assert fields[name].config == %{}

        assert Ankole.JSON.decode!(row["data"][fields[name].id]) ==
                 original[source_fields[name].id]

        assert Repo.get_by!(BaseRecord, id: row["id"]).data[fields[name].id] ==
                 row["data"][fields[name].id]
      end

      assert row["data"][fields["Alias"].id] == row["data"][fields["Mixed Owners"].id]
      assert row["data"][fields["Same Owners"].id] == original[source_fields["Same Owners"].id]
    end

    row = Enum.find(rows, &(&1["data"][fields["Name"].id] == "true"))

    assert {:ok, _} =
             Bases.write_records(actor, copy.table.id, %{
               updates: [
                 %{
                   id: row["id"],
                   data: %{fields["Flag"].id => false},
                   expected_versions: %{fields["Flag"].id => 1}
                 }
               ]
             })

    assert {:ok, %{records: [updated]}} = Bases.query(actor, copy.table.id, %{ids: [row["id"]]})
    assert updated["data"][fields["Mixed Owners"].id] == row["data"][fields["Mixed Owners"].id]
  end

  test "copied views retain empty link tests and discard predicates on source record IDs", ctx do
    actor = actor_fixture(ctx.uid)
    {:ok, related} = Bases.create_table(actor, ctx.page.id, %{name: "Related"})
    name = Enum.find(Bases.fields(related.id), & &1.is_primary)

    {:ok, %{records: [target]}} =
      Bases.write_records(actor, related.id, %{creates: [%{data: %{name.id => "Target"}}]})

    {:ok, link} = field(ctx, "Related", "link", %{"table_id" => related.id})
    {:ok, formula} = field(ctx, "Related formula", "formula", %{"source" => "[Related]"})

    {:ok, _} =
      Bases.write_records(actor, ctx.table.id, %{
        creates: [
          %{data: %{ctx.primary.id => "Full", link.id => [target.id]}},
          %{data: %{ctx.primary.id => "Empty"}}
        ]
      })

    for {label, conditions} <- [
          {"Source IDs",
           [
             %{"field_id" => link.id, "operator" => "contains", "value" => target.id},
             %{"field_id" => formula.id, "operator" => "is", "value" => [target.id]},
             %{"field_id" => ctx.primary.id, "operator" => "is", "value" => "Full"}
           ]},
          {"Empty", [%{"field_id" => link.id, "operator" => "is_empty"}]},
          {"Full", [%{"field_id" => link.id, "operator" => "is_not_empty"}]}
        ] do
      assert {:ok, _} =
               Bases.create_view(actor, ctx.table.id, %{
                 name: label,
                 type: "grid",
                 config: %{
                   "filter" => %{"conditions" => conditions},
                   "sort" => [%{"field_id" => link.id, "direction" => "asc"}]
                 }
               })
    end

    assert {:ok, copy} = Bases.copy_table(actor, ctx.table.id, %{})
    assert {:ok, schema} = Bases.get_table(actor, copy.table.id)
    fields = Map.new(schema.fields, &{&1.name, &1})

    for view <- Enum.filter(schema.views, &(&1.name in ["Source IDs", "Empty", "Full"])) do
      assert length(view.config["filter"]["conditions"]) == 1

      assert {:ok, %{records: [row]}} =
               Bases.query(actor, copy.table.id, %{
                 filter: view.config["filter"],
                 sort: view.config["sort"]
               })

      assert row["data"][fields["Name"].id] == if(view.name == "Empty", do: "Empty", else: "Full")
    end
  end

  defp field(ctx, name, type, config \\ %{}),
    do:
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: name,
        type: type,
        config: config
      })
end
