defmodule Ankole.Pod.BaseLinkAggregateTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Bases, Pages}

  # Orders link to one product, to many items, and receive returns through the
  # reverse side of a two-way link.
  setup do
    owner = human_fixture().principal.uid
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "base", private_owner_uid: owner})
    {:ok, %{tables: [orders]}} = Bases.list_tables(actor, page.id)
    {:ok, products} = Bases.create_table(actor, page.id, %{name: "Products"})
    {:ok, items} = Bases.create_table(actor, page.id, %{name: "Items"})
    {:ok, returns} = Bases.create_table(actor, page.id, %{name: "Returns"})

    field = fn table, name, type, config ->
      {:ok, field} =
        Bases.create_field(actor, table.id, %{name: name, type: type, config: config})

      field
    end

    f = %{
      amount: field.(orders, "Amount", "number", %{}),
      product:
        field.(orders, "Product", "link", %{"table_id" => products.id, "multiple" => false}),
      items: field.(orders, "Items", "link", %{"table_id" => items.id}),
      category: field.(products, "Category", "text", %{}),
      item_amount: field.(items, "Amount", "number", %{}),
      sku: field.(items, "SKU", "text", %{}),
      reason: field.(returns, "Reason", "text", %{}),
      refund: field.(returns, "Refund", "number", %{})
    }

    returned =
      field.(returns, "Order", "link", %{
        "table_id" => orders.id,
        "multiple" => false,
        "bidirectional" => true
      })

    f = Map.merge(f, %{order: returned, returns: returned.config["reverse_field_id"]})

    write = fn table, data ->
      {:ok, %{records: records}} =
        Bases.write_records(actor, table.id, %{creates: Enum.map(data, &%{data: &1})})

      Enum.map(records, & &1.id)
    end

    [tools, toys] = write.(products, [%{f.category.id => "tools"}, %{f.category.id => "toys"}])

    [i1, i2, i3, i4] =
      write.(items, [
        %{f.item_amount.id => 10.1, f.sku.id => "a"},
        %{f.item_amount.id => 20.2, f.sku.id => "b"},
        %{f.item_amount.id => 30.3, f.sku.id => "c"},
        %{f.item_amount.id => 5, f.sku.id => "d"}
      ])

    # A has three items, B has one, C has neither a product nor items.
    [a, b, c] =
      write.(orders, [
        %{f.amount.id => 100.01, f.product.id => [tools], f.items.id => [i1, i2, i3]},
        %{f.amount.id => 50, f.product.id => [toys], f.items.id => [i4]},
        %{f.amount.id => 7}
      ])

    write.(returns, [
      %{f.reason.id => "damaged", f.refund.id => 3, f.order.id => [a]},
      %{f.reason.id => "late", f.refund.id => 4, f.order.id => [a]},
      %{f.reason.id => "late", f.refund.id => 2, f.order.id => [b]}
    ])

    %{
      actor: actor,
      page: page,
      orders: orders,
      products: products,
      items: items,
      returns: returns,
      f: f,
      ids: %{a: a, b: b, c: c}
    }
  end

  defp aggregate(ctx, attrs), do: Bases.aggregate(ctx.actor, ctx.orders.id, attrs)

  defp by_group(result),
    do: Map.new(result.groups, &{hd(&1.values), &1.metrics_text})

  test "N:1 dimensions group parent rows once and report every participating version", ctx do
    %{f: f} = ctx

    assert {:ok, result} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: [f.product.id]}],
               metrics: [
                 %{operation: "sum", field_id: f.amount.id, alias: "amount"},
                 %{operation: "count", alias: "orders"}
               ]
             })

    assert by_group(result) == %{
             "tools" => %{"amount" => "100.01", "orders" => "1"},
             "toys" => %{"amount" => "50", "orders" => "1"},
             nil => %{"amount" => "7", "orders" => "1"}
           }

    assert Map.keys(result.data_versions) |> Enum.sort() ==
             Enum.sort([ctx.orders.id, ctx.products.id])

    assert result.data_versions[ctx.orders.id] == result.data_version
  end

  test "1:N metrics pre-aggregate children so parent sums never inflate", ctx do
    %{f: f} = ctx

    assert {:ok, result} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: [f.product.id]}],
               metrics: [
                 %{operation: "sum", field_id: f.amount.id, alias: "amount"},
                 %{operation: "count", alias: "orders"},
                 %{
                   operation: "sum",
                   field_id: f.item_amount.id,
                   path: [f.items.id],
                   alias: "items"
                 },
                 %{operation: "count", path: [f.items.id], alias: "item_count"},
                 %{
                   operation: "avg",
                   field_id: f.item_amount.id,
                   path: [f.items.id],
                   alias: "avg"
                 },
                 %{operation: "max", field_id: f.sku.id, path: [f.items.id], alias: "last_sku"}
               ]
             })

    groups = by_group(result)
    # Order A carries three items; its own amount stays 100.01 rather than 300.03.
    assert groups["tools"]["amount"] == "100.01"
    assert groups["tools"]["orders"] == "1"
    assert groups["tools"]["items"] == "60.6"
    assert groups["tools"]["item_count"] == "3"
    assert Decimal.equal?(Decimal.new(groups["tools"]["avg"]), Decimal.new("20.2"))
    assert groups["tools"]["last_sku"] == "c"

    assert groups[nil] == %{
             "amount" => "7",
             "orders" => "1",
             "items" => nil,
             "item_count" => "0",
             "avg" => nil,
             "last_sku" => nil
           }

    assert {:ok, %{groups: [total]}} =
             aggregate(ctx, %{
               metrics: [
                 %{operation: "sum", field_id: f.amount.id, alias: "amount"},
                 %{
                   operation: "sum",
                   field_id: f.item_amount.id,
                   path: [f.items.id],
                   alias: "items"
                 },
                 %{operation: "avg", field_id: f.item_amount.id, path: [f.items.id], alias: "avg"}
               ]
             })

    assert total.metrics_text["amount"] == "157.01"
    assert total.metrics_text["items"] == "65.6"
    assert Decimal.equal?(Decimal.new(total.metrics_text["avg"]), Decimal.new("16.4"))
  end

  test "reverse-link metrics honor child filters and count each parent once", ctx do
    %{f: f} = ctx

    assert {:ok, %{groups: [total], data_versions: versions}} =
             aggregate(ctx, %{
               metrics: [
                 %{operation: "count", alias: "orders"},
                 %{operation: "sum", field_id: f.amount.id, alias: "amount"},
                 %{operation: "sum", field_id: f.refund.id, path: [f.returns], alias: "refunds"},
                 %{
                   operation: "sum",
                   field_id: f.refund.id,
                   path: [f.returns],
                   alias: "late",
                   filter: %{
                     conjunction: "and",
                     conditions: [%{field_id: f.reason.id, operator: "is", value: "late"}]
                   }
                 }
               ]
             })

    assert total.metrics_text == %{
             "orders" => "3",
             "amount" => "157.01",
             "refunds" => "9",
             "late" => "6"
           }

    assert Map.has_key?(versions, ctx.returns.id)
  end

  test "EXISTS and NOT EXISTS filter parents by linked records", ctx do
    %{f: f} = ctx

    damaged = %{
      operator: "exists",
      path: [f.returns],
      filter: %{
        conjunction: "and",
        conditions: [%{field_id: f.reason.id, operator: "is", value: "damaged"}]
      }
    }

    sum = [%{operation: "sum", field_id: f.amount.id, alias: "amount"}]

    assert {:ok, %{groups: [%{metrics_text: %{"amount" => "100.01"}}]}} =
             aggregate(ctx, %{
               filter: %{conjunction: "and", conditions: [damaged]},
               metrics: sum
             })

    assert {:ok, %{groups: [%{metrics_text: %{"amount" => "7"}}]}} =
             aggregate(ctx, %{
               filter: %{
                 conjunction: "and",
                 conditions: [%{operator: "not_exists", path: [f.returns]}]
               },
               metrics: sum
             })

    assert {:ok, %{groups: [%{metrics_text: %{"amount" => "57"}}]}} =
             aggregate(ctx, %{
               filter: %{
                 conjunction: "and",
                 conditions: [Map.put(damaged, :operator, "not_exists")]
               },
               metrics: sum
             })

    # A linked-field condition matches when a reached record satisfies it.
    assert {:ok, %{groups: [%{metrics_text: %{"amount" => "107.01"}}]}} =
             aggregate(ctx, %{
               filter: %{
                 conjunction: "or",
                 conditions: [
                   %{
                     field_id: f.category.id,
                     path: [f.product.id],
                     operator: "is",
                     value: "tools"
                   },
                   %{field_id: f.amount.id, operator: "lt", value: 10}
                 ]
               },
               metrics: sum
             })
  end

  test "multi-hop paths reach a table through intermediate links", ctx do
    %{f: f} = ctx

    assert {:ok, result} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: [f.product.id]}],
               metrics: [
                 %{
                   operation: "count",
                   path: [f.returns, f.order.id, f.product.id],
                   alias: "products"
                 }
               ]
             })

    # Each order with returns reaches its own product once through the returns.
    assert by_group(result) == %{
             "tools" => %{"products" => "1"},
             "toys" => %{"products" => "1"},
             nil => %{"products" => "0"}
           }
  end

  test "invalid paths fail with explicit reasons", ctx do
    %{f: f} = ctx
    count = [%{operation: "count", alias: "n"}]

    assert {:error, {:invalid_link_path, %{reason: "multi_value_dimension"}}} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.item_amount.id, path: [f.items.id]}],
               metrics: count
             })

    assert {:error, {:invalid_link_path, %{reason: "not_link"}}} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: [f.amount.id]}],
               metrics: count
             })

    assert {:error, {:invalid_link_path, %{reason: "unknown_field"}}} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: [f.category.id]}],
               metrics: count
             })

    # A field of another table needs a link path.
    assert {:error, :unknown_field} =
             aggregate(ctx, %{group_by: [%{field_id: f.category.id}], metrics: count})

    assert {:error, {:invalid_link_path, %{reason: "invalid_path"}}} =
             aggregate(ctx, %{
               group_by: [%{field_id: f.category.id, path: []}],
               metrics: count
             })

    assert {:error, {:invalid_link_path, %{reason: "unsupported_operation"}}} =
             aggregate(ctx, %{
               metrics: [
                 %{
                   operation: "count_distinct",
                   field_id: f.sku.id,
                   path: [f.items.id],
                   alias: "n"
                 }
               ]
             })

    assert {:error, {:invalid_link_path, %{reason: "path_required"}}} =
             aggregate(ctx, %{
               filter: %{conjunction: "and", conditions: [%{operator: "exists"}]},
               metrics: count
             })

    assert {:error, {:invalid_link_path, %{reason: "nested_path"}}} =
             aggregate(ctx, %{
               filter: %{
                 conjunction: "and",
                 conditions: [
                   %{
                     operator: "exists",
                     path: [f.returns],
                     filter: %{
                       conjunction: "and",
                       conditions: [
                         %{field_id: f.amount.id, path: [f.order.id], operator: "is_not_empty"}
                       ]
                     }
                   }
                 ]
               },
               metrics: count
             })

    # Record queries do not follow links and reject a path instead of ignoring it.
    assert {:error, {:invalid_link_path, %{reason: "nested_path"}}} =
             Bases.query(ctx.actor, ctx.orders.id, %{
               filter: %{
                 conjunction: "and",
                 conditions: [
                   %{field_id: f.category.id, path: [f.product.id], operator: "is_not_empty"}
                 ]
               }
             })

    assert {:error, :invalid_query} =
             aggregate(ctx, %{
               metrics: [
                 %{
                   operation: "count",
                   alias: "n",
                   filter: %{conjunction: "and", conditions: []}
                 }
               ]
             })
  end

  test "linked aggregates require view access on the Base page", ctx do
    outsider = actor_fixture(human_fixture().principal.uid)

    assert {:error, :forbidden} =
             Bases.aggregate(outsider, ctx.orders.id, %{
               group_by: [%{field_id: ctx.f.category.id, path: [ctx.f.product.id]}],
               metrics: [%{operation: "count", alias: "n"}]
             })
  end

  test "inline tables report their own version and reject link paths", ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "base"})
    {:ok, %{tables: [table]}} = Bases.list_tables(ctx.actor, page.id)
    assert table.storage_mode == :inline
    {:ok, amount} = Bases.create_field(ctx.actor, table.id, %{name: "Amount", type: "number"})

    {:ok, _} =
      Bases.write_records(ctx.actor, table.id, %{
        creates: [%{data: %{amount.id => 1.5}}, %{data: %{amount.id => 2}}]
      })

    assert {:ok, %{groups: [%{metrics_text: %{"sum" => "3.5"}}]} = result} =
             Bases.aggregate(ctx.actor, table.id, %{
               metrics: [%{operation: "sum", field_id: amount.id, alias: "sum"}]
             })

    assert result.data_versions == %{table.id => result.data_version}

    assert {:error, {:invalid_link_path, %{reason: "not_link"}}} =
             Bases.aggregate(ctx.actor, table.id, %{
               metrics: [%{operation: "count", path: [amount.id], alias: "n"}]
             })
  end
end
