defmodule Ankole.Pod.DatabaseTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Database, DbField, DbRecord, DbTable, Pages}

  @limits %{
    "local_rows" => 5000,
    "local_bytes" => 5_000_000,
    "query_rows" => 10_000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }
  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", @limits)
    human = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
        type: "database",
        title: "Sales"
      })

    {:ok, table} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(human.uid), page.id, %{
        name: "Sales"
      })

    primary = Database.fields(table.id) |> Enum.find(& &1.is_primary)
    %{uid: human.uid, page: page, table: table, primary: primary}
  end

  test "reference values persist canonical IDs and clear when their target is deleted", ctx do
    {:ok, user} = field(ctx, "User", "user")
    {:ok, link} = field(ctx, "Single", "link", %{"table_id" => ctx.table.id, "multiple" => false})

    {:ok, %{records: [target]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{}}]
      })

    assert {:ok, %{records: [record]}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [
                   %{
                     data: %{
                       user.id => ["  " <> String.upcase(ctx.uid) <> "  ", ctx.uid],
                       link.id => [String.upcase(target.id), target.id]
                     }
                   }
                 ]
               }
             )

    assert record.data[user.id] == [ctx.uid]
    assert record.data[link.id] == [target.id]

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 deletes: [%{id: target.id, expected_versions: target.versions}]
               }
             )

    saved = Repo.get_by!(DbRecord, id: record.id)
    refute Map.has_key?(saved.data, link.id)
    assert saved.versions[link.id] == record.versions[link.id] + 1
  end

  test "new fields and views append in creation order while explicit positions remain authoritative",
       ctx do
    assert {:ok, first} = field(ctx, "First", "text")
    assert {:ok, second} = field(ctx, "Second", "number")

    assert Enum.map(Database.fields(ctx.table.id), & &1.id) ==
             [ctx.primary.id, first.id, second.id]

    assert {:ok, before_name} =
             Database.create_field(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 "name" => "Before name",
                 "type" => "text",
                 "position" => "0"
               }
             )

    assert before_name.position == "0"
    assert {:ok, last} = field(ctx, "Last", "text")

    assert Enum.map(Database.fields(ctx.table.id), & &1.id) ==
             [before_name.id, ctx.primary.id, first.id, second.id, last.id]

    assert {:ok, first_view} =
             Database.create_view(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{name: "Board", type: "kanban"}
             )

    assert {:ok, second_view} =
             Database.create_view(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{name: "Gallery", type: "gallery"}
             )

    assert {:ok, %{views: [grid | _] = views}} =
             Database.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id)

    assert Enum.map(views, & &1.name) == ["Grid", "Board", "Gallery"]

    assert {:ok, before_grid} =
             Database.create_view(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 name: "Before grid",
                 type: "grid",
                 position: "0"
               }
             )

    assert before_grid.position == "0"

    assert {:ok, last_view} =
             Database.create_view(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{name: "Last", type: "grid"}
             )

    assert {:ok, %{views: views}} =
             Database.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id)

    assert Enum.map(views, & &1.id) ==
             [before_grid.id, grid.id, first_view.id, second_view.id, last_view.id]
  end

  test "different cells merge while stale same-cell writes and stale deletes reject atomically",
       ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, note} = field(ctx, "Note", "text")

    {:ok, %{records: [record]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 2, note.id => "old"}}]
      })

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: record.id, data: %{amount.id => 3}, expected_versions: %{amount.id => 1}}
                 ]
               }
             )

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: record.id, data: %{note.id => "new"}, expected_versions: %{note.id => 1}}
                 ]
               }
             )

    assert {:error, {:field_conflict, conflict}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: record.id, data: %{amount.id => 9}, expected_versions: %{amount.id => 1}}
                 ]
               }
             )

    assert conflict.fields == [amount.id]
    assert conflict.data[amount.id] == 3

    assert {:error, {:record_conflict, _}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 deletes: [%{id: record.id, expected_versions: record.versions}]
               }
             )

    assert Repo.get_by!(DbRecord, table_id: ctx.table.id, id: record.id).data == %{
             amount.id => 3,
             note.id => "new"
           }

    before = Repo.get!(DbTable, ctx.table.id).data_version

    assert {:error, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{note.id => "rollback"}}],
                 updates: [
                   %{id: record.id, data: %{amount.id => 8}, expected_versions: %{amount.id => 1}}
                 ]
               }
             )

    assert Repo.aggregate(DbRecord, :count) == 1
    assert Repo.get!(DbTable, ctx.table.id).data_version == before
  end

  test "formulas are dynamic SQL values and transitive changes, types, cycles, and deletion are checked",
       ctx do
    {:ok, price} = field(ctx, "Price", "number")
    {:ok, quantity} = field(ctx, "Quantity", "number")
    {:ok, total} = field(ctx, "Total", "formula", %{"source" => "[Price] * [Quantity]"})
    {:ok, doubled} = field(ctx, "Doubled", "formula", %{"source" => "[Total] * 2"})
    {:ok, ratio} = field(ctx, "Ratio", "formula", %{"source" => "[Price] / ([Quantity] - 3)"})

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{price.id => 4, quantity.id => 3}}]
      })

    assert {:ok, %{records: [record]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    assert record["data"][total.id] == 12
    assert record["data"][doubled.id] == 24
    assert is_nil(record["data"][ratio.id])

    assert {:ok, _} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), total.id, %{
               version: 1,
               config: %{"source" => "[Price] + [Quantity]"}
             })

    assert {:ok, %{records: [record]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    assert record["data"][doubled.id] == 14

    assert {:error, :field_referenced} =
             Database.delete_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), price.id, 1)

    assert {:error, :formula_cycle} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), total.id, %{
               version: 2,
               config: %{"source" => "[Doubled]"}
             })

    assert {:error, :formula_type} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), price.id, %{
               version: 1,
               type: "text"
             })

    assert {:error, {:readonly_field, _}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{creates: [%{data: %{total.id => 9}}]}
             )
  end

  test "failed conversions retain data; successful conversion advances cell versions", ctx do
    {:ok, source} = field(ctx, "Number text", "text")

    {:ok, %{records: [a, b]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{source.id => "12"}}, %{data: %{source.id => "bad"}}]
      })

    assert {:error, {:conversion_failed, [id]}} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), source.id, %{
               version: 1,
               type: "number"
             })

    assert id == b.id
    assert Repo.get!(DbField, source.id).type == :text

    assert {:ok, converted} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), source.id, %{
               version: 1,
               type: "number",
               clear_invalid: true
             })

    assert converted.version == 2
    assert Repo.get_by!(DbRecord, table_id: ctx.table.id, id: a.id).data[source.id] == 12.0

    assert {:error, {:field_conflict, _}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: a.id, data: %{source.id => 9}, expected_versions: %{source.id => 1}}
                 ]
               }
             )

    refute Map.has_key?(Repo.get_by!(DbRecord, table_id: ctx.table.id, id: b.id).data, source.id)
  end

  test "mixed-direction keyset pagination includes every row once with nulls last", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")

    data = [
      %{amount.id => 1, ctx.primary.id => "a"},
      %{amount.id => 1, ctx.primary.id => "b"},
      %{ctx.primary.id => "c"},
      %{amount.id => 2, ctx.primary.id => "d"},
      %{}
    ]

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: Enum.map(data, &%{data: &1})
      })

    for direction <- ["asc", "desc"] do
      attrs = %{
        sort: [
          %{field_id: amount.id, direction: direction},
          %{field_id: ctx.primary.id, direction: "desc"}
        ],
        page_size: 2
      }

      ids = all_pages(ctx, attrs, [])
      assert length(ids) == 5
      assert length(Enum.uniq(ids)) == 5

      {:ok, all} =
        Database.query(
          Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
          ctx.table.id,
          Map.put(attrs, :page_size, 100)
        )

      assert ids == Enum.map(all.records, & &1["id"])
    end
  end

  test "shared TypeScript query cases match SQL including formulas, empty normalization, and literal wildcards",
       ctx do
    fixture =
      File.read!(Path.expand("../../../../webapps/pod/state/table-query-cases.json", __DIR__))
      |> Torque.decode!()

    {:ok, amount} = field(ctx, "Amount", "number")

    {:ok, tags} =
      field(ctx, "Tags", "select", %{
        "multiple" => true,
        "options" => [%{"id" => "red", "name" => "Red"}, %{"id" => "blue", "name" => "Blue"}]
      })

    {:ok, total} =
      field(ctx, "Total", "formula", %{
        "source" => "IF([Name] = \"Alpha\", [Amount]*2, VALUE(\"\"))"
      })

    {:ok, empty_text} =
      field(ctx, "Empty text", "formula", %{"source" => "IF([Name]=\"Alpha\",\"\",\"x\")"})

    {:ok, blank} = field(ctx, "Blank", "formula", %{"source" => "ISBLANK([Empty text])"})

    {:ok, files} = field(ctx, "Files", "attachment")

    {:ok, uploaded} =
      Ankole.Pod.Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
        ctx.page.id,
        "attachment",
        nil,
        "report.pdf",
        "fixture data",
        "application/pdf"
      )

    attachment_path = "pages/#{ctx.page.id}/#{uploaded.file.path}"

    mapping = %{
      "name" => ctx.primary.id,
      "amount" => amount.id,
      "tags" => tags.id,
      "total" => total.id,
      "empty_text" => empty_text.id,
      "files" => files.id
    }

    record_ids =
      Map.new(Enum.with_index(fixture["records"], 1), fn {record, index} ->
        {record["id"],
         "019a2b00-0000-7000-8000-" <> String.pad_leading(to_string(index), 12, "0")}
      end)

    creates =
      Enum.map(fixture["records"], fn record ->
        %{
          id: record_ids[record["id"]],
          data:
            record["data"]
            |> Map.drop(["total", "empty_text"])
            |> Map.update("files", nil, fn value ->
              Enum.map(value, &Map.put(&1, "path", attachment_path))
            end)
            |> Map.new(fn {key, value} -> {mapping[key], value} end)
        }
      end)

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: creates
      })

    Enum.each(fixture["queries"], fn testcase ->
      query = remap(testcase["query"], mapping)

      assert {:ok, result} =
               Database.query(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 query
               )

      assert Enum.map(result.records, & &1["id"]) == Enum.map(testcase["ids"], &record_ids[&1]),
             testcase["name"]
    end)

    Enum.each(fixture["aggregates"], fn testcase ->
      assert {:ok, result} =
               Database.aggregate(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 remap(testcase["query"], mapping)
               )

      assert Enum.map(result.groups, &%{"values" => &1.values, "metrics" => &1.metrics}) ==
               testcase["groups"],
             testcase["name"]
    end)

    assert {:ok, %{records: projected}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    alpha = Enum.find(projected, &(&1["id"] == record_ids["a"]))
    assert alpha["data"][empty_text.id] == nil
    assert alpha["data"][blank.id] == true

    assert {:ok, %{records: [selected]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{
                 conjunction: "or",
                 conditions: [
                   %{field_id: ctx.primary.id, operator: "is", value: "Alpha"},
                   %{field_id: amount.id, operator: "gt", value: 3}
                 ]
               },
               group: %{field_id: tags.id, value_json: "\"red\""}
             })

    assert selected["id"] == record_ids["a"]

    assert {:ok, %{records: empty_group}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               group: %{field_id: tags.id, value_json: "null"}
             })

    assert Enum.map(empty_group, & &1["id"]) == [record_ids["c"], record_ids["d"]]
  end

  test "bidirectional links commit both cells and reject cross-Database references", ctx do
    {:ok, target} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "People"
      })

    {:ok, %{records: [person]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), target.id, %{
        creates: [%{data: %{}}]
      })

    {:ok, link} = field(ctx, "Owner", "link", %{"table_id" => target.id, "bidirectional" => true})

    {:ok, %{records: [sale]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{link.id => [person.id]}}]
      })

    reverse = link.config["reverse_field_id"]
    assert Enum.map(Database.fields(target.id), & &1.name) == ["Name", "Sales Owner"]
    assert Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data[reverse] == [sale.id]

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: sale.id, data: %{link.id => []}, expected_versions: %{link.id => 1}}
                 ]
               }
             )

    refute Map.has_key?(Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data, reverse)

    {:ok, foreign_page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), %{type: "database"})

    {:ok, foreign} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), foreign_page.id, %{
        name: "Other"
      })

    assert {:error, :cross_database_link} =
             field(ctx, "Wrong", "link", %{"table_id" => foreign.id})
  end

  test "built-in view types use version CAS", ctx do
    for type <- ~w(grid kanban gallery) do
      assert {:ok, view} =
               Database.create_view(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 %{name: type, type: type, config: %{}}
               )

      assert {:ok, saved} =
               Database.update_view(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), view.id, %{
                 version: 1,
                 name: type <> " 2"
               })

      assert saved.version == 2

      assert {:error, {:schema_conflict, _}} =
               Database.update_view(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), view.id, %{
                 version: 1,
                 name: "stale"
               })
    end
  end

  test "self-table reciprocal changes return current cell versions and notify every changed row",
       ctx do
    {:ok, link} =
      field(ctx, "Related", "link", %{"table_id" => ctx.table.id, "bidirectional" => true})

    reverse = link.config["reverse_field_id"]

    assert Enum.map(Database.fields(ctx.table.id), & &1.id) ==
             [ctx.primary.id, link.id, reverse]

    {:ok, %{records: [first, second]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{}}, %{data: %{}}]
      })

    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-room:table:#{ctx.table.id}")

    assert {:ok, %{records: [written_first, written_second]}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: first.id, data: %{link.id => [second.id]}, expected_versions: %{}},
                   %{id: second.id, data: %{link.id => [first.id]}, expected_versions: %{}}
                 ]
               }
             )

    assert written_first.data[reverse] == [second.id]

    assert written_first.versions ==
             Repo.get_by!(DbRecord, table_id: ctx.table.id, id: first.id).versions

    assert written_second.data[reverse] == [first.id]
    assert_receive {:room_event, "changed", %{changed_ids: ids}}
    assert MapSet.new(ids) == MapSet.new([first.id, second.id])

    assert {:ok, %{changed_ids: indirect}} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{
                     id: first.id,
                     data: %{link.id => []},
                     expected_versions: %{link.id => written_first.versions[link.id]}
                   }
                 ]
               }
             )

    assert MapSet.new(indirect) == MapSet.new([first.id, second.id])
  end

  test "copy accepts the same exact record byte boundary as an ordinary write", ctx do
    empty_size = byte_size(Torque.encode!(%{ctx.primary.id => ""}))
    value = String.duplicate("a", @limits["record_bytes"] - empty_size)
    data = %{ctx.primary.id => value}
    assert byte_size(Torque.encode!(data)) == @limits["record_bytes"]

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{creates: [%{data: data}]}
             )

    {:ok, report} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), %{title: "Boundary report"})

    assert {:ok, copied} =
             Database.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{parent_id: report.id}
             )

    assert {:ok, %{records: [record]}} =
             Database.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    copied_primary = Database.fields(copied.table.id) |> Enum.find(& &1.is_primary)
    assert record["data"][copied_primary.id] == value
    assert byte_size(Torque.encode!(record["data"])) == @limits["record_bytes"]
  end

  test "copy preserves formulas against independent copied inputs", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, _formula} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    {:ok, %{records: [original]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 5}}]
      })

    {:ok, report} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), %{title: "Report"})

    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-access:" <> Repo.tenant_id!())

    assert {:ok, copied} =
             Database.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 parent_id: report.id,
                 title: "Frozen sales"
               }
             )

    assert_receive :recheck_access
    assert copied.page.parent_id == report.id
    assert copied.table.id != ctx.table.id
    copied_fields = Database.fields(copied.table.id)
    frozen = Enum.find(copied_fields, &(&1.name == "Total"))
    assert frozen.type == :formula
    copied_amount = Enum.find(copied_fields, &(&1.name == "Amount"))

    assert {:ok, %{records: [record]}} =
             Database.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert record["data"][frozen.id] == 10

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{
                     id: original.id,
                     data: %{amount.id => 20},
                     expected_versions: %{amount.id => 1}
                   }
                 ]
               }
             )

    assert {:ok, %{records: [record]}} =
             Database.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert record["data"][frozen.id] == 10

    assert {:ok, _} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{
                 updates: [
                   %{
                     id: record["id"],
                     data: %{copied_amount.id => 7},
                     expected_versions: %{copied_amount.id => 1}
                   }
                 ]
               }
             )

    assert {:ok, %{records: [record]}} =
             Database.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    assert record["data"][frozen.id] == 14
  end

  test "multi-value groups count each membership and aggregates compute current formulas", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")

    {:ok, tags} =
      field(ctx, "Tags", "select", %{
        "multiple" => true,
        "options" => [%{"id" => "a", "name" => "A"}, %{"id" => "b", "name" => "B"}]
      })

    {:ok, total} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [
          %{data: %{amount.id => 3, tags.id => ["a", "b"]}},
          %{data: %{amount.id => 4, tags.id => ["a"]}},
          %{data: %{amount.id => 5}}
        ]
      })

    assert {:ok, result} =
             Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               group_by: [%{field_id: tags.id}],
               metrics: [
                 %{operation: "count", alias: "count"},
                 %{operation: "sum", field_id: total.id, alias: "total"}
               ]
             })

    groups = Map.new(result.groups, fn group -> {hd(group.values), group.metrics} end)
    assert groups["a"] == %{"count" => 2, "total" => 14}
    assert groups["b"] == %{"count" => 1, "total" => 6}
    assert groups[nil] == %{"count" => 1, "total" => 10}
  end

  test "copy attachment rows reference the same durable content without copying bytes", ctx do
    {:ok, attachment} = field(ctx, "Files", "attachment")

    {:ok, uploaded} =
      Ankole.Pod.Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
        ctx.page.id,
        "attachment",
        nil,
        "report.txt",
        "same bytes",
        "text/plain"
      )

    path = "pages/#{ctx.page.id}/#{uploaded.file.path}"

    value = [
      %{
        "path" => path,
        "name" => "report.txt",
        "mime" => "text/plain",
        "size" => uploaded.file.size
      }
    ]

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{attachment.id => value}}]
      })

    {:ok, report} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), %{title: "Report"})

    assert {:ok, copied} =
             Database.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{parent_id: report.id}
             )

    copied_field = Enum.find(Database.fields(copied.table.id), &(&1.type == :attachment))

    assert {:ok, %{records: [record]}} =
             Database.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               copied.table.id,
               %{}
             )

    new_path = hd(record["data"][copied_field.id])["path"]
    assert String.starts_with?(new_path, "pages/#{copied.page.id}/attachments/")
    assert {:ok, before} = Ankole.Files.fetch(:pod, path)
    assert {:ok, after_file} = Ankole.Files.fetch(:pod, new_path)
    assert before.sha256 == after_file.sha256
  end

  test "local mode returns the whole small table and enforces the actual response byte threshold",
       ctx do
    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: Enum.map(1..200, &%{data: %{ctx.primary.id => to_string(&1)}})
      })

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: Enum.map(201..220, &%{data: %{ctx.primary.id => to_string(&1)}})
      })

    assert {:ok, %{mode: "local", timezone: _}} =
             Database.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id)

    assert {:ok, %{records: records, complete: true}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               local: true
             })

    assert length(records) == 220

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key(
        "pod.database.limits",
        Map.put(@limits, "local_bytes", 100)
      )

    # Schema is a cheap row-count hint. Only the snapshot owner computes exact
    # serialized bytes; its rejection leaves the ordinary remote query usable.
    assert {:ok, %{mode: "local", limits: %{"local_bytes" => 100}}} =
             Database.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id)

    assert {:error, :local_table_changed} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               local: true
             })

    assert {:ok, %{records: remote, complete: false, page_token: token}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    assert length(remote) == 200
    assert is_binary(token)
  end

  test "renaming select options keeps stored ids and cell versions", ctx do
    {:ok, select} =
      field(ctx, "Status", "select", %{"options" => [%{"id" => "stable", "name" => "Before"}]})

    {:ok, %{records: [record]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{select.id => "stable"}}]
      })

    assert {:ok, _} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), select.id, %{
               version: 1,
               config: %{"options" => [%{"id" => "stable", "name" => "After"}]}
             })

    saved = Repo.get_by!(DbRecord, table_id: ctx.table.id, id: record.id)
    assert saved.versions == record.versions
    assert saved.data == record.data
  end

  test "deleting one side of a two-way link preserves the opposite field and its values", ctx do
    {:ok, target} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "People"
      })

    {:ok, %{records: [person]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), target.id, %{
        creates: [%{data: %{}}]
      })

    {:ok, link} = field(ctx, "Owner", "link", %{"table_id" => target.id, "bidirectional" => true})

    {:ok, %{records: [sale]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{link.id => [person.id]}}]
      })

    reverse_id = link.config["reverse_field_id"]

    assert {:ok, _} =
             Database.delete_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), link.id, 1)

    assert is_nil(Repo.get(DbField, link.id))
    reverse = Repo.get!(DbField, reverse_id)
    refute Map.has_key?(reverse.config, "reverse_field_id")

    assert Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data[reverse_id] == [
             sale.id
           ]

    {:ok, one_way} = field(ctx, "One-way owner", "link", %{"table_id" => target.id})

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        updates: [%{id: sale.id, data: %{one_way.id => [person.id]}, expected_versions: %{}}]
      })

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        updates: [
          %{id: sale.id, data: %{one_way.id => []}, expected_versions: %{one_way.id => 1}}
        ]
      })

    assert Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data[reverse_id] == [
             sale.id
           ]
  end

  test "turning a link into a two-way link fills the reverse cells and disabling it stops propagation",
       ctx do
    {:ok, target} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "People"
      })

    {:ok, %{records: [person]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), target.id, %{
        creates: [%{data: %{}}]
      })

    {:ok, link} = field(ctx, "Owner", "link", %{"table_id" => target.id})

    {:ok, %{records: [sale]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{link.id => [person.id]}}]
      })

    assert {:ok, two_way} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), link.id, %{
               version: 1,
               config: %{"table_id" => target.id, "bidirectional" => true}
             })

    reverse_id = two_way.config["reverse_field_id"]

    assert Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data[reverse_id] == [
             sale.id
           ]

    assert {:ok, _} =
             Database.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), link.id, %{
               version: 2,
               config: %{"table_id" => target.id, "bidirectional" => false}
             })

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        updates: [%{id: sale.id, data: %{link.id => []}, expected_versions: %{link.id => 1}}]
      })

    assert Repo.get_by!(DbRecord, table_id: target.id, id: person.id).data[reverse_id] == [
             sale.id
           ]
  end

  test "formula numeric comparisons and sums preserve PostgreSQL truth across JSON rounding",
       ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, ratio} = field(ctx, "Third", "formula", %{"source" => "1 / 3"})

    {:ok, exact} =
      field(ctx, "Exact literal", "formula", %{
        "source" => "0.123456789123456789 = VALUE(\"0.123456789123456789\")"
      })

    {:ok, invalid} =
      field(ctx, "Invalid number", "formula", %{
        "source" => "ISBLANK(1e9999999999999999999999)"
      })

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 0.1}}, %{data: %{amount.id => 0.2}}]
      })

    assert {:ok, %{records: [record | _]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    rounded = record["data"][ratio.id]
    assert rounded == 0.3333333333333333
    assert record["data"][exact.id] == true
    assert record["data"][invalid.id] == true

    assert {:ok, %{records: []}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{conditions: [%{field_id: ratio.id, operator: "is", value: rounded}]}
             })

    assert {:ok, %{groups: [%{metrics: %{"sum" => sum}}]}} =
             Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               metrics: [%{operation: "sum", field_id: amount.id, alias: "sum"}]
             })

    assert sum == 0.3
    refute sum == 0.1 + 0.2

    for direction <- ["asc", "desc"] do
      attrs = %{sort: [%{field_id: ratio.id, direction: direction}], page_size: 1}

      {:ok, first} =
        Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, attrs)

      {:ok, second} =
        Database.query(
          Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
          ctx.table.id,
          Map.put(attrs, :page_token, first.page_token)
        )

      assert hd(first.records)["id"] != hd(second.records)["id"]
      assert second.complete
    end

    assert {:ok, %{groups: [group]}} =
             Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               group_by: [%{field_id: ratio.id}]
             })

    assert group.values == [rounded]

    assert {:ok, %{records: exact_group}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               group: %{field_id: ratio.id, value_json: hd(group.value_json)}
             })

    assert length(exact_group) == 2
  end

  test "system timestamps remain canonical UTC when the tenant timezone changes", ctx do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("system.timezone", "Asia/Shanghai")
    {:ok, created_at} = field(ctx, "Created", "created_at")

    {:ok, %{records: [record]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{}}]
      })

    stored = Repo.get_by!(DbRecord, table_id: ctx.table.id, id: record.id)
    expected = DateTime.to_iso8601(stored.created_at)
    assert record.created_at == expected

    assert {:ok, %{records: [queried]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    assert queried["created_at"] == expected

    assert {:ok, %{records: [_]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{
                 conditions: [%{field_id: created_at.id, operator: "is", value: expected}]
               }
             })
  end

  test "text search treats backslashes and wildcards as literal characters", ctx do
    {:ok, %{records: [path, _]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [
          %{data: %{ctx.primary.id => "C:\\reports\\100%_sales"}},
          %{data: %{ctx.primary.id => "literal%"}}
        ]
      })

    for value <- ["\\", "100%_"] do
      assert {:ok, %{records: [found]}} =
               Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
                 filter: %{
                   conditions: [
                     %{field_id: ctx.primary.id, operator: "text_contains", value: value}
                   ]
                 }
               })

      assert found["id"] == path.id
    end
  end

  test "current PostgreSQL locale capabilities agree with the operations executed in the browser",
       ctx do
    assert {:ok, schema} =
             Database.get_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id)

    [[collation, ctype, provider]] =
      Repo.query!(
        "SELECT datcollate,datctype,datlocprovider::text FROM pg_database WHERE datname=current_database()",
        []
      ).rows

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{ctx.primary.id => "ASCII"}}, %{data: %{ctx.primary.id => "Ö"}}]
      })

    if schema.local_query.text_contains_ascii do
      assert {:ok, %{records: [_]}} =
               Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
                 filter: %{
                   conditions: [
                     %{field_id: ctx.primary.id, operator: "text_contains", value: "ascii"}
                   ]
                 }
               })

      assert {:ok, %{records: []}} =
               Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
                 filter: %{
                   conditions: [
                     %{field_id: ctx.primary.id, operator: "text_contains", value: "ö"}
                   ]
                 }
               })
    end

    if schema.local_query.jsonb_compare do
      values = Torque.encode!([["ä"], ["z"], ["Ö"]])

      assert Repo.query!(
               "SELECT value FROM jsonb_array_elements($1::text::jsonb) ORDER BY value",
               [values]
             ).rows == [[["z"]], [["Ö"]], [["ä"]]]
    end

    IO.puts(
      "Pod SQL locale fixture: " <>
        Torque.encode!(%{
          collation: collation,
          ctype: ctype,
          provider: provider,
          local_query: schema.local_query
        })
    )
  end

  defp field(ctx, name, type, config \\ %{}),
    do:
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: name,
        type: type,
        config: config
      })

  defp all_pages(ctx, attrs, ids) do
    {:ok, result} =
      Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, attrs)

    ids = ids ++ Enum.map(result.records, & &1["id"])

    if result.page_token,
      do: all_pages(ctx, Map.put(attrs, :page_token, result.page_token), ids),
      else: ids
  end

  defp remap(value, mapping) when is_binary(value), do: Map.get(mapping, value, value)
  defp remap(value, mapping) when is_list(value), do: Enum.map(value, &remap(&1, mapping))

  defp remap(value, mapping) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, remap(v, mapping)} end)

  defp remap(value, _mapping), do: value
end
