defmodule Ankole.Pod.FormulaPlanTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Database, Formula, Pages}

  test "conditional formulas do not evaluate an unused dependency" do
    base = [
      %{id: "gate", name: "Gate", type: :checkbox, config: %{}},
      %{id: "digits", name: "Digits", type: :number, config: %{}},
      %{id: "n", name: "N", type: :number, config: %{}}
    ]

    for {source, gate, n, digits, expected} <- [
          {"IF([Gate], [Bad], 1)", false, 1, 1_000_000_000_000, Decimal.new(1)},
          {"IF([Gate], 1, [Bad])", true, 1, 1_000_000_000_000, Decimal.new(1)},
          {"AND([Gate], [Bad] > 0)", false, 1, 1_000_000_000_000, false},
          {"OR([Gate], [Bad] > 0)", true, 1, 1_000_000_000_000, true},
          {"IF([Gate], [Bad], 1)", nil, 1, 1_000_000_000_000, Decimal.new(1)},
          {"AND([Gate], [Bad] > 0)", nil, 1, 0, nil},
          {"AND([Gate], [Bad] > 0)", nil, 0, 0, false},
          {"OR([Gate], [Bad] > 0)", nil, 1, 0, true},
          {"OR([Gate], [Bad] > 0)", nil, 0, 0, nil},
          {"IF([Gate], [Bad], 1)", true, nil, 0, nil}
        ] do
      fields =
        Enum.reduce(
          [{"bad", "Bad", "ROUND([N], [Digits])"}, {"safe", "Safe", source}],
          base,
          fn {id, name, source}, fields ->
            {:ok, field} =
              Formula.prepare(
                %{id: id, name: name, type: :formula, config: %{"source" => source}},
                fields
              )

            fields ++ [field]
          end
        )

      safe = Enum.find(fields, &(&1.id == "safe"))
      assert {:ok, sql, _type, params} = Formula.expression(safe, fields, [])
      data = [%{"gate" => gate, "n" => n, "digits" => digits}]

      assert {:ok, %{rows: [[^expected]]}} =
               Repo.query(
                 "SELECT #{sql} FROM jsonb_array_elements($#{length(params) + 1}::jsonb) AS r(data)",
                 params ++ [data]
               )
    end
  end

  test "aggregate and copy filters evaluate only the formulas they need" do
    uid = human_fixture().principal.uid

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        type: "database",
        title: "Conditional formulas"
      })

    {:ok, table} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, %{
        name: "Numbers"
      })

    {:ok, n} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "N",
        type: "number"
      })

    {:ok, digits} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "Digits",
        type: "number"
      })

    {:ok, gate} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "Gate",
        type: "checkbox"
      })

    {:ok, _} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        creates: [%{data: %{n.id => 1, digits.id => 1_000_000_000_000, gate.id => false}}]
      })

    {:ok, _} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "Bad",
        type: "formula",
        config: %{"source" => "ROUND([N], [Digits])"}
      })

    {:ok, safe} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "Safe",
        type: "formula",
        config: %{"source" => "IF([Gate], [Bad], 1)"}
      })

    filter = %{conditions: [%{field_id: safe.id, operator: "is", value: 1}]}

    assert {:ok, %{groups: [%{metrics: %{"sum" => 1}}]}} =
             Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               filter: filter,
               metrics: [%{operation: "sum", field_id: safe.id}]
             })

    assert {:ok, %{table: %{record_count: 1}}} =
             Database.copy_table(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               filter: filter
             })

    assert {:error, {:invalid_query, reason}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{})

    assert reason =~ "integer out of range"
  end

  test "each formula root compiles its dependency graph once across query and copy paths" do
    uid = human_fixture().principal.uid

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        type: "database",
        title: "Shared formulas"
      })

    {:ok, table} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, %{
        name: "Numbers"
      })

    {:ok, base} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
        name: "Base",
        type: "number"
      })

    last =
      Enum.reduce(1..20, base, fn index, previous ->
        {:ok, field} =
          Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
            name: "F#{index}",
            type: "formula",
            config: %{"source" => "[#{previous.name}] + [#{previous.name}]"}
          })

        field
      end)

    fields = Database.fields(table.id)
    assert {:ok, sql, :number, params} = Formula.expression(last, fields, [])
    assert byte_size(sql) < 5000
    assert length(params) == 1

    {projection, params} =
      fields
      |> Enum.filter(&(&1.type == :formula))
      |> Enum.reduce({"'{}'::jsonb", []}, fn field, {projection, params} ->
        {:ok, expression, :number, params} = Formula.expression(field, fields, params)
        {key, params} = Formula.bind(params, field.id)
        {projection <> " || jsonb_build_object(#{key}::text, #{expression})", params}
      end)

    assert byte_size(projection) < 60_000
    assert length(params) == 21

    assert {:ok, _} =
             Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               creates: [%{data: %{base.id => 2}}, %{data: %{base.id => 3}}]
             })

    filter = %{conditions: [%{field_id: last.id, operator: "gt", value: 2_500_000}]}

    assert {:ok, %{records: [row]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               filter: filter,
               sort: [%{field_id: last.id, direction: "desc"}]
             })

    assert row["data"][last.id] == 3_145_728

    assert {:ok, %{groups: [%{metrics: %{"total" => 5_242_880}}]}} =
             Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               metrics: [%{field_id: last.id, operation: "sum", alias: "total"}]
             })

    assert {:ok, copied} =
             Database.copy_table(Ankole.PrincipalsFixtures.actor_fixture(uid), table.id, %{
               filter: filter
             })

    copied_last = Enum.find(Database.fields(copied.table.id), &(&1.name == last.name))

    assert {:ok, %{records: [row]}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(uid), copied.table.id, %{})

    assert row["data"][copied_last.id] == 3_145_728
  end
end
