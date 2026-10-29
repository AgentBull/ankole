defmodule Ankole.Pod.BasesReviewTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Config, Bases, BaseField, BaseRecord, BaseTable, Pages}

  setup do
    uid = human_fixture().principal.uid

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        type: "base",
        title: "Review"
      })

    {:ok, table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, %{
        name: "Sales"
      })

    %{uid: uid, page: page, table: table}
  end

  test "CAS is checked against earlier writes in the same atomic batch", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 1}}]
      })

    before = Repo.get!(BaseTable, ctx.table.id).data_version
    update = %{id: record.id, data: %{amount.id => 2}, expected_versions: record.versions}

    assert {:error, {:field_conflict, _}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{updates: [update, update]}
             )

    assert read_record(ctx.uid, ctx.table.id, record.id)["data"][amount.id] == 1

    assert {:error, {:record_conflict, _}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [update],
                 deletes: [%{id: record.id, expected_versions: record.versions}]
               }
             )

    assert Repo.get!(BaseTable, ctx.table.id).data_version == before

    assert {:ok, %{records: [saved], data_version: version}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   update,
                   %{update | data: %{amount.id => 3}, expected_versions: %{amount.id => 2}}
                 ]
               }
             )

    assert saved.data[amount.id] == 3
    assert saved.versions[amount.id] == 3
    assert version == before + 1
  end

  test "mutation responses include formulas; renamed references remain editable", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, formula} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    assert {:ok, %{records: [record]}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{amount.id => 2}}]
               }
             )

    assert record.data[formula.id] == 4

    assert {:ok, _} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), amount.id, %{
               version: 1,
               name: "Price"
             })

    reloaded = Repo.get!(BaseField, formula.id)
    assert reloaded.config["source"] =~ "[Price]"

    assert {:ok, _} =
             Bases.update_field(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               formula.id,
               %{
                 version: reloaded.version,
                 config: reloaded.config
               }
             )

    assert {:ok, %{records: [updated]}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: record.id, data: %{amount.id => 3}, expected_versions: record.versions}
                 ]
               }
             )

    assert updated.data[formula.id] == 6
    refute Map.has_key?(Repo.get_by!(BaseRecord, id: record.id).data, formula.id)
  end

  test "explicitly clearing an unwritten cell is still a write for CAS", ctx do
    primary = Enum.find(Bases.fields(ctx.table.id), & &1.is_primary)

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{}}]
      })

    {:ok, %{records: [cleared]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        updates: [%{id: record.id, data: %{primary.id => ""}, expected_versions: %{}}]
      })

    refute Map.has_key?(cleared.data, primary.id)
    assert cleared.versions[primary.id] == 1

    assert {:error, {:field_conflict, _}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 updates: [
                   %{id: record.id, data: %{primary.id => "stale"}, expected_versions: %{}}
                 ]
               }
             )
  end

  test "single-link conversion validates existing cells and clears both sides only explicitly",
       ctx do
    {:ok, target} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "People"
      })

    {:ok, %{records: [a, b]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), target.id, %{
        creates: [%{data: %{}}, %{data: %{}}]
      })

    {:ok, link} =
      field(ctx, "People", "link", %{
        "table_id" => target.id,
        "bidirectional" => true,
        "multiple" => true
      })

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{link.id => [a.id, b.id]}}]
      })

    config = Map.put(link.config, "multiple", false)

    assert {:error, {:conversion_failed, [id]}} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), link.id, %{
               version: 1,
               config: config
             })

    assert id == record.id

    assert {:ok, _} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), link.id, %{
               version: 1,
               config: config,
               clear_invalid: true
             })

    refute Map.has_key?(read_record(ctx.uid, ctx.table.id, record.id)["data"], link.id)

    for person <- [a, b],
        do:
          refute(
            Map.has_key?(
              read_record(ctx.uid, target.id, person.id)["data"],
              link.config["reverse_field_id"]
            )
          )
  end

  test "reverse writes observe the configured final-record byte limit", ctx do
    {:ok, target} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.page.id, %{
        name: "People"
      })

    primary = Enum.find(Bases.fields(target.id), & &1.is_primary)

    {:ok, %{records: [person]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), target.id, %{
        creates: [%{data: %{primary.id => String.duplicate("x", 40)}}]
      })

    {:ok, link} = field(ctx, "Owner", "link", %{"table_id" => target.id, "bidirectional" => true})
    {:ok, limits} = Config.limits()

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", %{
        limits
        | "record_bytes" => 100
      })

    assert {:error, :record_size_limit} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{link.id => [person.id]}}]
               }
             )

    assert {:ok, %{records: []}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{})

    refute Map.has_key?(
             read_record(ctx.uid, target.id, person.id)["data"],
             link.config["reverse_field_id"]
           )
  end

  test "new reverse fields and reverse writes use the compact final-record byte limit", ctx do
    actor = actor_fixture(ctx.uid)
    {:ok, target} = Bases.create_table(actor, ctx.page.id, %{name: "People"})
    primary = Enum.find(Bases.fields(target.id), & &1.is_primary)
    data = %{primary.id => String.duplicate("x", 40)}

    {:ok, %{records: [person]}} =
      Bases.write_records(actor, target.id, %{creates: [%{data: data}]})

    {:ok, link} =
      field(ctx, "Owner", "link", %{"table_id" => target.id, "bidirectional" => false})

    {:ok, %{records: [source]}} =
      Bases.write_records(actor, ctx.table.id, %{creates: [%{data: %{link.id => [person.id]}}]})

    {:ok, limits} = Config.limits()
    bytes = byte_size(Torque.encode!(Map.put(data, Ecto.UUID.generate(), [source.id])))

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", %{
        limits
        | "record_bytes" => bytes - 1
      })

    attrs = %{version: link.version, config: Map.put(link.config, "bidirectional", true)}
    assert {:error, :record_size_limit} = Bases.update_field(actor, link.id, attrs)
    assert Enum.count(Bases.fields(target.id)) == 1

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", %{limits | "record_bytes" => bytes})

    assert {:ok, link} = Bases.update_field(actor, link.id, attrs)
    reverse_id = link.config["reverse_field_id"]
    assert read_record(ctx.uid, target.id, person.id)["data"][reverse_id] == [source.id]
    source = read_record(ctx.uid, ctx.table.id, source.id)

    {:ok, %{records: [other]}} =
      Bases.write_records(actor, target.id, %{creates: [%{data: data}]})

    assert {:ok, %{records: [saved]}} =
             Bases.write_records(actor, ctx.table.id, %{
               updates: [
                 %{
                   id: source["id"],
                   data: %{link.id => [other.id]},
                   expected_versions: %{link.id => source["versions"][link.id]}
                 }
               ]
             })

    assert read_record(ctx.uid, target.id, other.id)["data"][reverse_id] == [source["id"]]

    assert {:ok, _} =
             Bases.write_records(actor, ctx.table.id, %{
               deletes: [%{id: saved.id, expected_versions: saved.versions}]
             })

    refute Map.has_key?(read_record(ctx.uid, target.id, other.id)["data"], reverse_id)
  end

  test "malformed nested values are errors rather than exceptions", ctx do
    {:ok, attachment} = field(ctx, "Files", "attachment")

    for attrs <- [
          %{creates: [1]},
          %{updates: [%{id: Ecto.UUID.generate(), data: false, expected_versions: %{}}]},
          %{creates: [%{data: %{attachment.id => [1]}}]}
        ] do
      assert {:error, _} =
               Bases.write_records(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 attrs
               )
    end

    for attrs <- [%{filter: %{conditions: [1]}}, %{sort: [1]}, %{group: false}] do
      assert {:error, _} =
               Bases.query(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 attrs
               )
    end

    for attrs <- [%{group_by: [1]}, %{metrics: [nil]}] do
      assert {:error, _} =
               Bases.aggregate(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                 ctx.table.id,
                 attrs
               )
    end

    assert {:error, _} =
             Bases.create_view(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 name: "Bad",
                 type: "grid",
                 config: %{"visible_fields" => 1}
               }
             )
  end

  test "renamed formula references escape closing brackets and backslashes", ctx do
    slash = <<92>>
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, formula} = field(ctx, "Total", "formula", %{"source" => "[Amount] * 2"})

    assert {:ok, _} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), amount.id, %{
               version: 1,
               name: "价]格" <> slash <> "税"
             })

    reloaded = Repo.get!(BaseField, formula.id)
    assert reloaded.config["source"] == "([价" <> slash <> "]格" <> slash <> slash <> "税] * 2)"

    assert {:ok, _} =
             Bases.update_field(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               formula.id,
               %{
                 version: reloaded.version,
                 config: reloaded.config
               }
             )

    assert {:ok, %{records: [record]}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{amount.id => 3}}]
               }
             )

    assert record.data[formula.id] == 6

    assert {:ok, trailing} = field(ctx, "Trailing" <> slash, "number")

    assert {:ok, trailing_formula} =
             field(ctx, "Trailing total", "formula", %{
               "source" => "[Trailing" <> slash <> slash <> "] + 1"
             })

    assert {:ok, %{records: [saved]}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{trailing.id => 4}}]
               }
             )

    assert saved.data[trailing_formula.id] == 5

    assert {:error, :invalid_formula} =
             Bases.update_field(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               formula.id,
               %{
                 version: Repo.get!(BaseField, formula.id).version,
                 config: %{"source" => 1}
               }
             )
  end

  test "a failed conversion preserves every record and its cell versions", ctx do
    {:ok, source} = field(ctx, "Source", "text")

    {:ok, _} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: List.duplicate(%{data: %{source.id => "12"}}, 200)
      })

    {:ok, %{records: [bad]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{source.id => "not a number"}}]
      })

    assert {:error, {:conversion_failed, [id]}} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), source.id, %{
               version: 1,
               type: "number"
             })

    assert id == bad.id
    assert Repo.get!(BaseField, source.id).type == :text

    for record <- Repo.all(from r in BaseRecord, where: r.table_id == ^ctx.table.id) do
      assert is_binary(record.data[source.id])
      assert record.versions[source.id] == 1
    end

    assert {:ok, _} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), source.id, %{
               version: 1,
               type: "number",
               clear_invalid: true
             })

    assert Repo.get!(BaseField, source.id).type == :number
    refute Map.has_key?(Repo.get_by!(BaseRecord, id: bad.id).data, source.id)
    assert Repo.get_by!(BaseRecord, id: bad.id).versions[source.id] == 2
  end

  test "conversion validates compact JSON bytes of the entire final record", ctx do
    {:ok, source} = field(ctx, "Source", "number")

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{source.id => 1}}]
      })

    {:ok, limits} = Config.limits()
    bytes = byte_size(Torque.encode!(record.data))

    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", %{
        limits
        | "record_bytes" => bytes
      })

    assert {:error, :record_size_limit} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), source.id, %{
               version: 1,
               type: "text"
             })

    assert Repo.get!(BaseField, source.id).type == :number
    assert read_record(ctx.uid, ctx.table.id, record.id)["data"][source.id] == 1
    assert Repo.get_by!(BaseRecord, id: record.id).versions[source.id] == 1
  end

  test "datetime filters normalize equivalent ISO input for stored and formula fields", ctx do
    {:ok, date} = field(ctx, "When", "datetime")
    {:ok, formula} = field(ctx, "Same time", "formula", %{"source" => "[When]"})

    {:ok, %{records: [first, second]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [
          %{data: %{date.id => "2026-10-18T08:00:00+08:00"}},
          %{data: %{date.id => "2026-10-18T01:00:00Z"}}
        ]
      })

    for field <- [date, formula],
        input <- ["2026-10-18T00:00:00Z", "2026-10-18T08:00:00+08:00"] do
      assert {:ok, %{records: [matched]}} =
               Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
                 filter: %{conditions: [%{field_id: field.id, operator: "is", value: input}]}
               })

      assert matched["id"] == first.id
    end

    assert {:ok, %{records: [matched]}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "lt", value: "2026-10-18T08:30:00+08:00"}
                 ]
               }
             })

    assert matched["id"] == first.id
    assert second.id != matched["id"]

    assert {:ok, %{records: [grouped]}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               group: %{
                 field_id: date.id,
                 value_json: Torque.encode!("2026-10-18T08:00:00+08:00")
               }
             })

    assert grouped["id"] == first.id

    assert {:error, :invalid_query} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{conditions: [%{field_id: date.id, operator: "is", value: "not a date"}]}
             })
  end

  test "upstream type changes persist downstream formula metadata and its CAS version", ctx do
    {:ok, amount} = field(ctx, "Amount", "number")
    {:ok, echo} = field(ctx, "Echo", "formula", %{"source" => "[Amount]"})

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 2}}]
      })

    assert {:ok, _} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), amount.id, %{
               version: 1,
               type: "text"
             })

    reloaded = Repo.get!(BaseField, echo.id)
    assert reloaded.config["result_type"] == "text"
    assert reloaded.version == echo.version + 1

    assert {:error, {:schema_conflict, _}} =
             Bases.update_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), echo.id, %{
               version: echo.version,
               name: "Old draft"
             })

    assert {:ok, %{records: [queried]}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               ids: [record.id]
             })

    assert queried["data"][echo.id] == "2"
  end

  test "datetime equality with null follows SQL null comparison instead of selecting empty cells",
       ctx do
    {:ok, date} = field(ctx, "Date", "datetime")

    {:ok, _} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{}}]
      })

    assert {:ok, %{records: []}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "is", value: nil}
                 ]
               }
             })

    assert {:ok, %{records: [_]}} =
             Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
               filter: %{
                 conditions: [
                   %{field_id: date.id, operator: "is_empty"}
                 ]
               }
             })
  end

  defp field(ctx, name, type, config \\ %{}),
    do:
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: name,
        type: type,
        config: config
      })

  defp read_record(uid, table, id) do
    {:ok, %{records: [record]}} =
      Bases.query(Ankole.PrincipalsFixtures.actor_fixture(uid), table, %{ids: [id]})

    record
  end
end
