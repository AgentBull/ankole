defmodule BullX.EventBus.RoutingTableTest do
  use BullX.DataCase, async: false

  alias BullX.EventBus.{EventRoutingRule, RoutingTable, RuleWriter, SystemCommands}
  alias BullX.Repo

  test "refresh failure keeps the latest successfully compiled snapshot" do
    {:ok, valid} =
      RuleWriter.create_rule(%{
        name: "valid route",
        priority: 100,
        match_expr: "true",
        target_type: :blackhole
      })

    assert {:ok, rules} = RoutingTable.snapshot()
    assert Enum.map(database_rules(rules), & &1.id) == [valid.id]

    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(EventRoutingRule, [
      %{
        id: BullX.Ext.gen_uuid_v7(),
        name: "invalid route",
        active: true,
        priority: 101,
        match_expr: "type ==",
        target_type: :blackhole,
        target_ref: nil,
        scope_fields: [],
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:error, _reason} = RoutingTable.refresh()
    assert {:ok, rules} = RoutingTable.snapshot()
    assert Enum.map(database_rules(rules), & &1.id) == [valid.id]
  end

  test "reorder_priorities uses a database-safe temporary priority range" do
    {:ok, first} =
      RuleWriter.create_rule(%{
        name: "first",
        priority: 200,
        match_expr: "true",
        target_type: :blackhole
      })

    {:ok, second} =
      RuleWriter.create_rule(%{
        name: "second",
        priority: 201,
        match_expr: "true",
        target_type: :blackhole
      })

    assert {:ok, [reordered_first, reordered_second]} =
             RuleWriter.reorder_priorities([second.id, first.id], 1)

    assert {reordered_first.id, reordered_first.priority} == {second.id, 1}
    assert {reordered_second.id, reordered_second.priority} == {first.id, 2}
  end

  test "upsert_by_name creates and then updates the same durable rule" do
    assert {:ok, created} =
             RuleWriter.upsert_by_name("setup.default-ai-agent.addressed", %{
               priority: 300,
               match_expr: "false",
               target_type: :blackhole
             })

    assert {:ok, updated} =
             RuleWriter.upsert_by_name("setup.default-ai-agent.addressed", %{
               priority: 301,
               match_expr: "true",
               target_type: :blackhole
             })

    assert updated.id == created.id
    assert updated.priority == 301
    assert updated.match_expr == "true"

    assert Repo.aggregate(EventRoutingRule, :count) == 1
  end

  test "create_rule rejects duplicate durable names" do
    assert {:ok, _rule} =
             RuleWriter.create_rule(%{
               name: "duplicate durable route",
               priority: 310,
               match_expr: "true",
               target_type: :blackhole
             })

    assert {:error, changeset} =
             RuleWriter.create_rule(%{
               name: "duplicate durable route",
               priority: 311,
               match_expr: "true",
               target_type: :blackhole
             })

    assert {"has already been taken", _metadata} = changeset.errors[:name]
  end

  defp database_rules(rules) do
    builtin_ids =
      SystemCommands.builtin_routing_rules()
      |> MapSet.new(& &1.id)

    Enum.reject(rules, &MapSet.member?(builtin_ids, &1.id))
  end
end
