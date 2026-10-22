defmodule Ankole.Pod.DatabaseReviewTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Config, Database, DbField, DbRecord, DbTable, Pages}

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    uid = human_fixture().principal.uid
    {:ok, page} = Pages.create(uid, %{type: "database", title: "Review"})
    {:ok, table} = Database.create_table(uid, page.id, %{name: "Sales"})
    %{uid: uid, page: page, table: table}
  end

  test "CAS is checked against earlier writes in the same atomic batch", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{creates: [%{data: %{amount.id => 1}}]})

    before = Repo.get!(DbTable, ctx.table.id).data_version
    update = %{id: record.id, data: %{amount.id => 2}, expected_versions: record.versions}

    assert {:error, {:field_conflict, _}} =
             Database.write_records(ctx.uid, ctx.table.id, %{updates: [update, update]})

    assert Repo.get_by!(DbRecord, id: record.id).data[amount.id] == 1

    assert {:error, {:record_conflict, _}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               updates: [update],
               deletes: [%{id: record.id, expected_versions: record.versions}]
             })

    assert Repo.get!(DbTable, ctx.table.id).data_version == before

    assert {:ok, %{records: [saved], data_version: version}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               updates: [
                 update,
                 %{update | data: %{amount.id => 3}, expected_versions: %{amount.id => 2}}
               ]
             })

    assert saved.data[amount.id] == 3
    assert saved.versions[amount.id] == 3
    assert version == before + 1
  end

  test "mutation responses include formulas; renamed references remain editable", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, formula} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    assert {:ok, %{records: [record]}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               creates: [%{data: %{amount.id => 2}}]
             })

    assert record.data[formula.id] == 4
    assert {:ok, _} = Database.update_field(ctx.uid, amount.id, %{version: 1, name: "Price"})
    reloaded = Repo.get!(DbField, formula.id)
    assert reloaded.config["source"] =~ "[Price]"

    assert {:ok, _} =
             Database.update_field(ctx.uid, formula.id, %{
               version: reloaded.version,
               config: reloaded.config
             })

    assert {:ok, %{records: [updated]}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               updates: [
                 %{id: record.id, data: %{amount.id => 3}, expected_versions: record.versions}
               ]
             })

    assert updated.data[formula.id] == 6
    refute Map.has_key?(Repo.get_by!(DbRecord, id: record.id).data, formula.id)
  end

  test "explicitly clearing an unwritten cell is still a write for CAS", ctx do
    primary = Enum.find(Database.fields(ctx.table.id), & &1.is_primary)

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{creates: [%{data: %{}}]})

    {:ok, %{records: [cleared]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        updates: [%{id: record.id, data: %{primary.id => ""}, expected_versions: %{}}]
      })

    refute Map.has_key?(cleared.data, primary.id)
    assert cleared.versions[primary.id] == 1

    assert {:error, {:field_conflict, _}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               updates: [%{id: record.id, data: %{primary.id => "stale"}, expected_versions: %{}}]
             })
  end

  test "single-link conversion validates existing cells and clears both sides only explicitly",
       ctx do
    {:ok, target} = Database.create_table(ctx.uid, ctx.page.id, %{name: "People"})

    {:ok, %{records: [a, b]}} =
      Database.write_records(ctx.uid, target.id, %{creates: [%{data: %{}}, %{data: %{}}]})

    {:ok, link} =
      field(ctx, "People", "link", %{
        "table_id" => target.id,
        "bidirectional" => true,
        "multiple" => true
      })

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [%{data: %{link.id => [a.id, b.id]}}]
      })

    config = Map.put(link.config, "multiple", false)

    assert {:error, {:conversion_failed, [id]}} =
             Database.update_field(ctx.uid, link.id, %{version: 1, config: config})

    assert id == record.id

    assert {:ok, _} =
             Database.update_field(ctx.uid, link.id, %{
               version: 1,
               config: config,
               clear_invalid: true
             })

    refute Map.has_key?(Repo.get_by!(DbRecord, id: record.id).data, link.id)

    for person <- [a, b],
        do:
          refute(
            Map.has_key?(
              Repo.get_by!(DbRecord, id: person.id).data,
              link.config["reverse_field_id"]
            )
          )
  end

  test "reverse writes observe the configured final-record byte limit", ctx do
    {:ok, target} = Database.create_table(ctx.uid, ctx.page.id, %{name: "People"})
    primary = Enum.find(Database.fields(target.id), & &1.is_primary)

    {:ok, %{records: [person]}} =
      Database.write_records(ctx.uid, target.id, %{
        creates: [%{data: %{primary.id => String.duplicate("x", 40)}}]
      })

    {:ok, link} = field(ctx, "Owner", "link", %{"table_id" => target.id, "bidirectional" => true})
    {:ok, limits} = Config.limits()

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", %{
        limits
        | "record_bytes" => 100
      })

    assert {:error, :record_size_limit} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               creates: [%{data: %{link.id => [person.id]}}]
             })

    assert Repo.aggregate(from(r in DbRecord, where: r.table_id == ^ctx.table.id), :count) == 0

    refute Map.has_key?(
             Repo.get_by!(DbRecord, id: person.id).data,
             link.config["reverse_field_id"]
           )
  end

  test "malformed nested values are errors rather than exceptions", ctx do
    {:ok, attachment} = field(ctx, "Files", "attachment")

    for attrs <- [
          %{creates: [1]},
          %{updates: [%{id: Ecto.UUID.generate(), data: false, expected_versions: %{}}]},
          %{creates: [%{data: %{attachment.id => [1]}}]}
        ] do
      assert {:error, _} = Database.write_records(ctx.uid, ctx.table.id, attrs)
    end

    for attrs <- [%{filter: %{conditions: [1]}}, %{sort: [1]}, %{group: false}] do
      assert {:error, _} = Database.query(ctx.uid, ctx.table.id, attrs)
    end

    for attrs <- [%{group_by: [1]}, %{metrics: [nil]}] do
      assert {:error, _} = Database.aggregate(ctx.uid, ctx.table.id, attrs)
    end

    assert {:error, _} =
             Database.create_view(ctx.uid, ctx.table.id, %{
               name: "Bad",
               type: "grid",
               config: %{"visible_fields" => 1}
             })
  end

  test "renamed formula references escape closing brackets and backslashes", ctx do
    slash = <<92>>
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, formula} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    assert {:ok, _} =
             Database.update_field(ctx.uid, amount.id, %{version: 1, name: "价]格" <> slash <> "税"})

    reloaded = Repo.get!(DbField, formula.id)
    assert reloaded.config["source"] == "([价" <> slash <> "]格" <> slash <> slash <> "税] * 2)"

    assert {:ok, _} =
             Database.update_field(ctx.uid, formula.id, %{
               version: reloaded.version,
               config: reloaded.config
             })

    assert {:ok, %{records: [record]}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               creates: [%{data: %{amount.id => 3}}]
             })

    assert record.data[formula.id] == 6

    assert {:ok, trailing} = field(ctx, "Trailing" <> slash, "number")

    assert {:ok, trailing_formula} =
             field(ctx, "Trailing total", "formula", %{
               "source" => "[Trailing" <> slash <> slash <> "] + 1"
             })

    assert {:ok, %{records: [saved]}} =
             Database.write_records(ctx.uid, ctx.table.id, %{
               creates: [%{data: %{trailing.id => 4}}]
             })

    assert saved.data[trailing_formula.id] == 5

    assert {:error, :invalid_formula} =
             Database.update_field(ctx.uid, formula.id, %{
               version: Repo.get!(DbField, formula.id).version,
               config: %{"source" => 1}
             })
  end

  test "a late invalid value rolls back every earlier conversion cursor chunk", ctx do
    {:ok, source} = field(ctx, "Source", "text")

    {:ok, _} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: List.duplicate(%{data: %{source.id => "12"}}, 200)
      })

    {:ok, %{records: [bad]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [%{data: %{source.id => "not a number"}}]
      })

    assert {:error, {:conversion_failed, [id]}} =
             Database.update_field(ctx.uid, source.id, %{version: 1, type: "number"})

    assert id == bad.id
    assert Repo.get!(DbField, source.id).type == :text

    for record <- Repo.all(from r in DbRecord, where: r.table_id == ^ctx.table.id) do
      assert is_binary(record.data[source.id])
      assert record.versions[source.id] == 1
    end

    assert {:ok, _} =
             Database.update_field(ctx.uid, source.id, %{
               version: 1,
               type: "number",
               clear_invalid: true
             })

    assert Repo.get!(DbField, source.id).type == :number
    refute Map.has_key?(Repo.get_by!(DbRecord, id: bad.id).data, source.id)
    assert Repo.get_by!(DbRecord, id: bad.id).versions[source.id] == 2
  end

  test "conversion validates compact JSON bytes of the entire final record", ctx do
    {:ok, source} = field(ctx, "Source", "number")

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{creates: [%{data: %{source.id => 1}}]})

    {:ok, limits} = Config.limits()
    bytes = byte_size(Torque.encode!(record.data))

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", %{
        limits
        | "record_bytes" => bytes
      })

    assert {:error, :record_size_limit} =
             Database.update_field(ctx.uid, source.id, %{version: 1, type: "text"})

    assert Repo.get!(DbField, source.id).type == :number
    assert Repo.get_by!(DbRecord, id: record.id).data[source.id] == 1
    assert Repo.get_by!(DbRecord, id: record.id).versions[source.id] == 1
  end

  test "datetime filters normalize equivalent ISO input for stored and formula fields", ctx do
    {:ok, date} = field(ctx, "When", "datetime")
    {:ok, formula} = field(ctx, "Same time", "formula", %{"source" => "[When]"})

    {:ok, %{records: [first, second]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{
        creates: [
          %{data: %{date.id => "2026-10-18T08:00:00+08:00"}},
          %{data: %{date.id => "2026-10-18T01:00:00Z"}}
        ]
      })

    for field <- [date, formula],
        input <- ["2026-10-18T00:00:00Z", "2026-10-18T08:00:00+08:00"] do
      assert {:ok, %{records: [matched]}} =
               Database.query(ctx.uid, ctx.table.id, %{
                 filter: %{conditions: [%{field_id: field.id, operator: "is", value: input}]}
               })

      assert matched["id"] == first.id
    end

    assert {:ok, %{records: [matched]}} =
             Database.query(ctx.uid, ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "lt", value: "2026-10-18T08:30:00+08:00"}
                 ]
               }
             })

    assert matched["id"] == first.id
    assert second.id != matched["id"]

    assert {:ok, %{records: [grouped]}} =
             Database.query(ctx.uid, ctx.table.id, %{
               group: %{
                 field_id: date.id,
                 value_json: Torque.encode!("2026-10-18T08:00:00+08:00")
               }
             })

    assert grouped["id"] == first.id

    assert {:error, :invalid_query} =
             Database.query(ctx.uid, ctx.table.id, %{
               filter: %{conditions: [%{field_id: date.id, operator: "is", value: "not a date"}]}
             })
  end

  test "upstream type changes persist downstream formula metadata and its CAS version", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, echo} = field(ctx, "Echo", "formula", %{"source" => "[Amount]"})

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.uid, ctx.table.id, %{creates: [%{data: %{amount.id => 2}}]})

    assert {:ok, _} = Database.update_field(ctx.uid, amount.id, %{version: 1, type: "text"})
    reloaded = Repo.get!(DbField, echo.id)
    assert reloaded.config["result_type"] == "text"
    assert reloaded.version == echo.version + 1

    assert {:error, {:schema_conflict, _}} =
             Database.update_field(ctx.uid, echo.id, %{version: echo.version, name: "Old draft"})

    assert {:ok, %{records: [queried]}} =
             Database.query(ctx.uid, ctx.table.id, %{ids: [record.id]})

    assert queried["data"][echo.id] == "2"
  end

  test "datetime equality with null follows SQL null comparison instead of selecting empty cells",
       ctx do
    {:ok, date} = field(ctx, "Date", "datetime")
    {:ok, _} = Database.write_records(ctx.uid, ctx.table.id, %{creates: [%{data: %{}}]})

    assert {:ok, %{records: []}} =
             Database.query(ctx.uid, ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "is", value: nil}
                 ]
               }
             })

    assert {:ok, %{records: [_]}} =
             Database.query(ctx.uid, ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "is_empty"}
                 ]
               }
             })
  end

  defp field(ctx, name, type, config \\ %{}),
    do: Database.create_field(ctx.uid, ctx.table.id, %{name: name, type: type, config: config})
end
