defmodule Ankole.Pod.PodVisualizationTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.{Bases, BaseTable, BaseView, Pages}

  setup do
    uid = human_fixture().principal.uid
    actor = actor_fixture(uid)
    {:ok, page} = Pages.create(actor, %{type: "base", title: "Visualization Base"})
    {:ok, table} = Bases.create_table(actor, page.id, %{name: "Deals"})
    [primary] = Bases.fields(table.id)
    %{uid: uid, actor: actor, page: page, table: table, primary: primary}
  end

  defp create_field!(actor, table_id, name, type, config \\ %{}) do
    {:ok, field} = Bases.create_field(actor, table_id, %{name: name, type: type, config: config})
    field
  end

  defp ensure_storage_mode!(actor, table, :inline) do
    {:ok, %{table: fresh}} = Bases.get_table(actor, table.id)
    assert fresh.storage_mode == :inline
    fresh
  end

  defp ensure_storage_mode!(actor, table, :physical) do
    _link = create_field!(actor, table.id, "SelfLink", "link", %{"table_id" => table.id})
    {:ok, %{table: fresh}} = Bases.get_table(actor, table.id)
    assert fresh.storage_mode == :physical
    fresh
  end

  describe "select option colors, chart views, delete_field scrubbing, and copy_table" do
    test "validates select option semantic palette tokens and hex colors", ctx do
      assert {:ok, select_field} =
               Bases.create_field(ctx.actor, ctx.table.id, %{
                 name: "Stage",
                 type: "select",
                 config: %{
                   "options" => [
                     %{"id" => "lead", "name" => "Lead", "color" => "brand"},
                     %{"id" => "qual", "name" => "Qualified", "color" => "teal"},
                     %{"id" => "won", "name" => "Won", "color" => "#0f8a5f"},
                     %{"id" => "lost", "name" => "Lost", "color" => "#C81E3A"},
                     %{"id" => "none", "name" => "Uncolored", "color" => nil},
                     %{"id" => "plain", "name" => "Plain"}
                   ]
                 }
               })

      assert Enum.map(select_field.config["options"], & &1["color"]) == [
               "brand",
               "teal",
               "#0f8a5f",
               "#C81E3A",
               nil,
               nil
             ]

      for bad_color <- ["neon", "#12345", "#1234567", "#GGGGGG", "", 123, %{}] do
        assert {:error, :invalid_options} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "BadColor",
                   type: "select",
                   config: %{
                     "options" => [%{"id" => "opt1", "name" => "Opt 1", "color" => bad_color}]
                   }
                 })
      end
    end

    test "creates chart views, scrubs deleted fields to missing_field_id, allows rename, and degrades incompatible slots on copy",
         ctx do
      amount = create_field!(ctx.actor, ctx.table.id, "Amount", "number")
      closed_at = create_field!(ctx.actor, ctx.table.id, "Closed At", "datetime")
      region = create_field!(ctx.actor, ctx.table.id, "Region", "text")
      extra_metric = create_field!(ctx.actor, ctx.table.id, "Discount", "number")

      chart_spec = %{
        "chart_type" => "combo",
        "query" => %{
          "group_by" => [
            %{"field_id" => closed_at.id, "bucket" => "month"},
            %{"field_id" => region.id}
          ],
          "metrics" => [
            %{"operation" => "count", "field_id" => nil, "alias" => "deal_count"},
            %{"operation" => "sum", "field_id" => amount.id, "alias" => "revenue"},
            %{"operation" => "avg", "field_id" => extra_metric.id, "alias" => "avg_discount"}
          ]
        },
        "encoding" => %{
          "x" => %{"field_id" => closed_at.id},
          "y" => [%{"field_id" => amount.id}, %{"field_id" => extra_metric.id}]
        }
      }

      assert {:ok, %BaseView{type: :chart} = chart_view} =
               Bases.create_view(ctx.actor, ctx.table.id, %{
                 name: "Monthly Revenue",
                 type: "chart",
                 config: %{"chart" => chart_spec}
               })

      for invalid_chart <- ["not-a-map", ["list"], nil] do
        assert {:error, :invalid_view} =
                 Bases.create_view(ctx.actor, ctx.table.id, %{
                   name: "Invalid",
                   type: "chart",
                   config: %{"chart" => invalid_chart}
                 })
      end

      assert {:error, :invalid_view} =
               Bases.create_view(ctx.actor, ctx.table.id, %{
                 name: "MissingWithoutMarker",
                 type: "chart",
                 config: %{
                   "chart" => %{
                     "query" => %{
                       "metrics" => [%{"operation" => "sum", "field_id" => nil, "alias" => "bad"}]
                     }
                   }
                 }
               })

      assert {:error, :unknown_field} =
               Bases.create_view(ctx.actor, ctx.table.id, %{
                 name: "UnknownField",
                 type: "chart",
                 config: %{
                   "chart" => %{
                     "encoding" => %{"x" => %{"field_id" => Ankole.Ecto.UUIDv7.autogenerate()}}
                   }
                 }
               })

      # Deleting extra_metric marks its slots with missing_field_id instead of wiping chart config.
      assert {:ok, _deleted} =
               Bases.delete_field(ctx.actor, extra_metric.id, extra_metric.version)

      {:ok, %{views: views}} = Bases.get_table(ctx.actor, ctx.table.id)
      scrubbed = Enum.find(views, &(&1.id == chart_view.id))

      assert [
               %{"alias" => "deal_count", "field_id" => nil, "operation" => "count"},
               %{"alias" => "revenue", "field_id" => amount_id, "operation" => "sum"},
               %{
                 "alias" => "avg_discount",
                 "field_id" => nil,
                 "missing_field_id" => missing_id,
                 "operation" => "avg"
               }
             ] = scrubbed.config["chart"]["query"]["metrics"]

      assert amount_id == amount.id
      assert missing_id == extra_metric.id

      assert [
               %{"field_id" => ^amount_id},
               %{"field_id" => nil, "missing_field_id" => ^missing_id}
             ] = scrubbed.config["chart"]["encoding"]["y"]

      # Renaming and reordering a chart view with missing_field_id slots succeeds cleanly.
      assert {:ok, renamed} =
               Bases.update_view(ctx.actor, scrubbed.id, %{
                 version: scrubbed.version,
                 name: "Monthly Revenue (Needs Repair)",
                 position: "Z"
               })

      assert renamed.name == "Monthly Revenue (Needs Repair)"

      # Convert `amount` to text and `closed_at` to text before copying so copy_table
      # exercises graceful degradation of incompatible sum/avg and bucket slots.
      assert {:ok, _} =
               Bases.update_field(ctx.actor, amount.id, %{
                 version: amount.version,
                 type: "text",
                 clear_invalid: true
               })

      {:ok, %{fields: refreshed_fields}} = Bases.get_table(ctx.actor, ctx.table.id)
      closed_fresh = Enum.find(refreshed_fields, &(&1.id == closed_at.id))

      assert {:ok, _} =
               Bases.update_field(ctx.actor, closed_fresh.id, %{
                 version: closed_fresh.version,
                 type: "text",
                 clear_invalid: true
               })

      assert {:ok, %{table: %BaseTable{} = copied_table}} =
               Bases.copy_table(ctx.actor, ctx.table.id, %{title: "Copied Deals"})

      {:ok, %{fields: copied_fields, views: copied_views}} =
        Bases.get_table(ctx.actor, copied_table.id)

      copied_by_name = Map.new(copied_fields, &{&1.name, &1})
      copied_chart = Enum.find(copied_views, &(&1.type == :chart))
      assert copied_chart.name == "Monthly Revenue (Needs Repair)"

      [copied_bucket_group, copied_region_group] =
        copied_chart.config["chart"]["query"]["group_by"]

      # Bucketed group on now-text field degrades gracefully to missing_field_id.
      assert copied_bucket_group["field_id"] == nil
      assert copied_bucket_group["missing_field_id"] == copied_by_name["Closed At"].id
      assert copied_bucket_group["bucket"] == "month"

      # Valid text group remaps to copied Region field ID.
      assert copied_region_group["field_id"] == copied_by_name["Region"].id

      [copied_count, copied_sum, copied_missing] =
        copied_chart.config["chart"]["query"]["metrics"]

      assert copied_count == %{"operation" => "count", "field_id" => nil, "alias" => "deal_count"}
      assert copied_sum["field_id"] == nil
      assert copied_sum["missing_field_id"] == copied_by_name["Amount"].id
      assert copied_sum["operation"] == "sum"
      assert copied_missing["field_id"] == nil
      assert copied_missing["missing_field_id"] == extra_metric.id
    end
  end

  describe "Query.aggregate key-folding, precision, array deduplication, and empty semantics" do
    for mode <- [:inline, :physical] do
      test "ranks each record once across a second multi-value dimension (#{mode})", ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        category = create_field!(ctx.actor, ctx.table.id, "Category", "text")
        amount = create_field!(ctx.actor, ctx.table.id, "Amount", "number")

        tags =
          create_field!(ctx.actor, ctx.table.id, "Tags", "select", %{
            "multiple" => true,
            "options" => Enum.map(~w(a b c), &%{"id" => &1, "name" => &1})
          })

        assert {:ok, _} =
                 Bases.write_records(ctx.actor, ctx.table.id, %{
                   creates: [
                     %{data: %{category.id => "Small", amount.id => 10, tags.id => ~w(a b c)}},
                     %{data: %{category.id => "Large", amount.id => 20, tags.id => ~w(a)}}
                   ]
                 })

        for direction <- ~w(asc desc) do
          assert {:ok, %{groups: groups}} =
                   Bases.aggregate(ctx.actor, ctx.table.id, %{
                     group_by: [%{field_id: tags.id}, %{field_id: category.id}],
                     metrics: [%{operation: "sum", field_id: amount.id, alias: "revenue"}],
                     order_by: [
                       %{group_index: 0, direction: "asc"},
                       %{metric_alias: "revenue", direction: direction}
                     ],
                     top_n: %{limit: 1, include_other: true}
                   })

          kept =
            groups
            |> Enum.reject(&Enum.at(&1.other, 1))
            |> Enum.map(&Enum.at(&1.values, 1))
            |> Enum.uniq()

          assert kept == [if(direction == "asc", do: "Small", else: "Large")]
        end
      end

      test "folds >1,000 raw groups into Top-N + Other without group_limit (#{mode})", ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        customer = create_field!(ctx.actor, ctx.table.id, "Customer", "text")
        amount = create_field!(ctx.actor, ctx.table.id, "Amount", "number")

        # Insert 1,050 distinct customer keys in <=200-row batches.
        for chunk <- Enum.chunk_every(1..1_050, 200) do
          creates =
            Enum.map(chunk, fn i ->
              key = "Cust-" <> String.pad_leading(Integer.to_string(i), 4, "0")
              val = if i <= 5, do: 10_000 - i * 100, else: 1
              %{data: %{customer.id => key, amount.id => val}}
            end)

          assert {:ok, _} = Bases.write_records(ctx.actor, ctx.table.id, %{creates: creates})
        end

        # Unfolded aggregation exceeds the 1,000 group guardrail.
        assert {:error, :group_limit} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: customer.id}],
                   metrics: [%{operation: "sum", field_id: amount.id, alias: "rev"}]
                 })

        # Key-folding Top-5 + Other succeeds in a single SQL query and returns 6 exact rows.
        assert {:ok, %{groups: groups}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: customer.id}],
                   metrics: [
                     %{operation: "sum", field_id: amount.id, alias: "rev"},
                     %{operation: "count", alias: "rows"}
                   ],
                   top_n: %{limit: 5, include_other: true}
                 })

        assert length(groups) == 6

        assert Enum.map(groups, &{&1.values, &1.other, &1.metrics}) == [
                 {["Cust-0001"], [false], %{"rev" => 9_900, "rows" => 1}},
                 {["Cust-0002"], [false], %{"rev" => 9_800, "rows" => 1}},
                 {["Cust-0003"], [false], %{"rev" => 9_700, "rows" => 1}},
                 {["Cust-0004"], [false], %{"rev" => 9_600, "rows" => 1}},
                 {["Cust-0005"], [false], %{"rev" => 9_500, "rows" => 1}},
                 {[nil], [true], %{"rev" => 1_045, "rows" => 1_045}}
               ]
      end

      test "computes exact weighted avg, non-additive count_distinct, and 25-digit metrics_text in Other (#{mode})",
           ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        segment = create_field!(ctx.actor, ctx.table.id, "Segment", "text")
        account = create_field!(ctx.actor, ctx.table.id, "Account", "text")
        score = create_field!(ctx.actor, ctx.table.id, "Score", "number")
        huge_hi = create_field!(ctx.actor, ctx.table.id, "HugeHi", "number")
        huge_lo = create_field!(ctx.actor, ctx.table.id, "HugeLo", "number")

        huge =
          create_field!(ctx.actor, ctx.table.id, "Huge", "formula", %{
            "source" => "[HugeHi] * 1000000000000 + [HugeLo]"
          })

        # Top1: 2 rows, score 1000 each.
        # TailHigh: 1 row, score 100, account "SharedAcct".
        # TailZero: 9 rows, score 0, accounts "SharedAcct" (x5) and "OnlyZeroAcct" (x4).
        # Exact weighted avg in Other = (100 + 9 * 0) / 10 = 10 (NOT unweighted (100 + 0)/2 = 50).
        # Exact count_distinct(Account) in Other = 2 ("SharedAcct", "OnlyZeroAcct"), NOT 1 + 2 = 3.
        creates =
          [
            %{
              data: %{
                segment.id => "Top1",
                account.id => "TopAcct",
                score.id => 1_000,
                huge_hi.id => 123_456_789_012,
                huge_lo.id => 345_678_901.234
              }
            },
            %{
              data: %{
                segment.id => "Top1",
                account.id => "TopAcct",
                score.id => 1_000,
                huge_hi.id => 0,
                huge_lo.id => 0.005
              }
            },
            %{
              data: %{
                segment.id => "TailHigh",
                account.id => "SharedAcct",
                score.id => 100,
                huge_hi.id => 900_000_000_000,
                huge_lo.id => 0.0002
              }
            }
          ] ++
            for i <- 1..9 do
              acct = if i <= 5, do: "SharedAcct", else: "OnlyZeroAcct"

              %{
                data: %{
                  segment.id => "TailZero",
                  account.id => acct,
                  score.id => 0,
                  huge_hi.id => 0,
                  huge_lo.id => 0.0001
                }
              }
            end

        assert {:ok, _} = Bases.write_records(ctx.actor, ctx.table.id, %{creates: creates})

        assert {:ok, %{groups: [top_row, other_row]}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: segment.id}],
                   metrics: [
                     %{operation: "sum", field_id: score.id, alias: "sum_score"},
                     %{operation: "avg", field_id: score.id, alias: "avg_score"},
                     %{operation: "count_distinct", field_id: account.id, alias: "uniq_accounts"},
                     %{operation: "sum", field_id: huge.id, alias: "sum_huge"}
                   ],
                   top_n: %{limit: 1, include_other: true}
                 })

        assert top_row.values == ["Top1"]
        assert top_row.other == [false]
        assert top_row.metrics_text["sum_huge"] == "123456789012000345678901.239"

        assert other_row.values == [nil]
        assert other_row.other == [true]
        assert other_row.metrics["sum_score"] == 100
        assert other_row.metrics["avg_score"] == 10
        assert Decimal.equal?(Decimal.new(other_row.metrics_text["avg_score"]), Decimal.new(10))
        assert other_row.metrics["uniq_accounts"] == 2
        assert other_row.metrics_text["uniq_accounts"] == "2"
        assert other_row.metrics_text["sum_huge"] == "900000000000000000000000.0011"
      end

      test "deduplicates multi-select array records folded into Other while preserving Top-N memberships (#{mode})",
           ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        amount = create_field!(ctx.actor, ctx.table.id, "Amount", "number")
        customer = create_field!(ctx.actor, ctx.table.id, "Customer", "text")

        tags =
          create_field!(ctx.actor, ctx.table.id, "Tags", "select", %{
            "multiple" => true,
            "options" => [
              %{"id" => "Top1", "name" => "Top1"},
              %{"id" => "Top2", "name" => "Top2"},
              %{"id" => "Tail1", "name" => "Tail1"},
              %{"id" => "Tail2", "name" => "Tail2"}
            ]
          })

        assert {:ok, _} =
                 Bases.write_records(ctx.actor, ctx.table.id, %{
                   creates: [
                     # Contributes to both Top1 and Top2 (high amounts so Top1 & Top2 win Top-2)
                     %{
                       data: %{
                         tags.id => ["Top1", "Top2"],
                         amount.id => 500,
                         customer.id => "C1"
                       }
                     },
                     # Has TWO tail tags ["Tail1", "Tail2"]: must be counted ONCE in Other!
                     %{
                       data: %{
                         tags.id => ["Tail1", "Tail2"],
                         amount.id => 30,
                         customer.id => "C2"
                       }
                     },
                     # Has one Top tag and one Tail tag: contributes to Top1 AND once to Other!
                     %{
                       data: %{
                         tags.id => ["Top1", "Tail1"],
                         amount.id => 20,
                         customer.id => "C3"
                       }
                     }
                   ]
                 })

        assert {:ok, %{groups: groups}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: tags.id}],
                   metrics: [
                     %{operation: "sum", field_id: amount.id, alias: "sum_amt"},
                     %{operation: "count", alias: "rows"},
                     %{operation: "avg", field_id: amount.id, alias: "avg_amt"},
                     %{operation: "count_distinct", field_id: customer.id, alias: "uniq_cust"},
                     %{operation: "count_distinct", field_id: tags.id, alias: "uniq_tag_sets"}
                   ],
                   top_n: %{limit: 2, include_other: true}
                 })

        assert [top1, top2, other] = groups
        assert top1.values == ["Top1"]
        assert top1.other == [false]
        assert top1.metrics["rows"] == 2
        assert top1.metrics["sum_amt"] == 520

        assert top2.values == ["Top2"]
        assert top2.other == [false]
        assert top2.metrics["rows"] == 1
        assert top2.metrics["sum_amt"] == 500

        assert other.values == [nil]
        assert other.other == [true]
        assert other.metrics["rows"] == 2
        assert other.metrics["sum_amt"] == 50
        assert other.metrics["avg_amt"] == 25
        assert other.metrics["uniq_cust"] == 2
        assert other.metrics["uniq_tag_sets"] == 2
      end

      test "isolates NULL from Top-N and Other when omit_empty is false, and preserves 0 and false when omit_empty is true (#{mode})",
           ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        num = create_field!(ctx.actor, ctx.table.id, "ZeroOrNull", "number")
        flag = create_field!(ctx.actor, ctx.table.id, "Flag", "checkbox")

        tags =
          create_field!(ctx.actor, ctx.table.id, "Tags", "select", %{
            "multiple" => true,
            "options" => [%{"id" => "t1", "name" => "T1"}]
          })

        # Give NULL 5 rows so it would beat every non-null key if NULL were mistakenly ranked!
        creates =
          for(_ <- 1..5, do: %{data: %{}}) ++
            [
              %{data: %{num.id => 0, flag.id => false, tags.id => ["t1"]}},
              %{data: %{num.id => 0, flag.id => false, tags.id => []}},
              %{data: %{num.id => 10, flag.id => true}},
              %{data: %{num.id => 20, flag.id => true}}
            ]

        assert {:ok, _} = Bases.write_records(ctx.actor, ctx.table.id, %{creates: creates})

        # omit_empty: false with top_n limit 1 on `num`:
        # Top-1 is `0` (2 rows), Other is `10` + `20` (2 rows), and `[nil]` (5 rows) stays independent!
        assert {:ok, %{groups: num_groups}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: num.id}],
                   metrics: [%{operation: "count", alias: "cnt"}],
                   omit_empty: false,
                   top_n: %{limit: 1, include_other: true}
                 })

        assert Enum.map(num_groups, &{&1.values, &1.other, &1.metrics["cnt"]}) == [
                 {[0], [false], 2},
                 {[nil], [true], 2},
                 {[nil], [false], 5}
               ]

        # omit_empty: true drops NULL on `num`, `flag`, and empty `tags`, while keeping `0` and `false`!
        assert {:ok, %{groups: non_empty_num}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: num.id}],
                   metrics: [%{operation: "count", alias: "cnt"}],
                   omit_empty: true,
                   order_by: [%{group_index: 0, direction: "asc"}]
                 })

        assert Enum.map(non_empty_num, &{&1.values, &1.metrics["cnt"]}) == [
                 {[0], 2},
                 {[10], 1},
                 {[20], 1}
               ]

        assert {:ok, %{groups: non_empty_flag}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: flag.id}],
                   metrics: [%{operation: "count", alias: "cnt"}],
                   omit_empty: true,
                   order_by: [%{group_index: 0, direction: "asc"}]
                 })

        assert Enum.map(non_empty_flag, &{&1.values, &1.metrics["cnt"]}) == [
                 {[false], 2},
                 {[true], 2}
               ]

        assert {:ok, %{groups: non_empty_tags}} =
                 Bases.aggregate(ctx.actor, ctx.table.id, %{
                   group_by: [%{field_id: tags.id}],
                   metrics: [%{operation: "count", alias: "cnt"}],
                   omit_empty: true
                 })

        assert Enum.map(non_empty_tags, &{&1.values, &1.metrics["cnt"]}) == [
                 {["t1"], 1}
               ]
      end
    end
  end

  describe "Query.records drill-down slices and Browser JSON:API contract" do
    for mode <- [:inline, :physical] do
      test "drills down with OR filter + 2D bucket slice, cumulative bucket range, Other exclusions, and cursors (#{mode})",
           ctx do
        _table = ensure_storage_mode!(ctx.actor, ctx.table, unquote(mode))
        occurred_at = create_field!(ctx.actor, ctx.table.id, "Occurred At", "datetime")
        category = create_field!(ctx.actor, ctx.table.id, "Category", "text")
        channel = create_field!(ctx.actor, ctx.table.id, "Channel", "text")
        amount = create_field!(ctx.actor, ctx.table.id, "Amount", "number")

        tags =
          create_field!(ctx.actor, ctx.table.id, "Tags", "select", %{
            "multiple" => true,
            "options" => [
              %{"id" => "TopTag", "name" => "TopTag"},
              %{"id" => "TailA", "name" => "TailA"},
              %{"id" => "TailB", "name" => "TailB"}
            ]
          })

        {:ok, write_res} =
          Bases.write_records(ctx.actor, ctx.table.id, %{
            creates: [
              %{
                data: %{
                  ctx.primary.id => "R1",
                  occurred_at.id => "2026-01-15T10:00:00Z",
                  category.id => "SaaS",
                  channel.id => "Direct",
                  amount.id => 100,
                  tags.id => ["TopTag"]
                }
              },
              %{
                data: %{
                  ctx.primary.id => "R2",
                  occurred_at.id => "2026-02-10T10:00:00Z",
                  category.id => "SaaS",
                  channel.id => "Partner",
                  amount.id => 500,
                  tags.id => ["TopTag", "TailA"]
                }
              },
              %{
                data: %{
                  ctx.primary.id => "R3",
                  occurred_at.id => "2026-02-20T10:00:00Z",
                  category.id => "Services",
                  channel.id => "Direct",
                  amount.id => 50,
                  tags.id => ["TailA", "TailB"]
                }
              },
              %{
                data: %{
                  ctx.primary.id => "R4",
                  occurred_at.id => "2026-03-05T10:00:00Z",
                  category.id => "Hardware",
                  channel.id => "Direct",
                  amount.id => 40,
                  tags.id => []
                }
              },
              %{
                data: %{
                  ctx.primary.id => "R5",
                  category.id => "Unscheduled",
                  channel.id => "Direct",
                  amount.id => 10
                }
              }
            ]
          })

        by_name = Map.new(write_res.records, &{&1.data[ctx.primary.id], &1.id})

        # 1. (Channel = Direct OR Amount >= 400) AND 2D slice (month = "2026-02" AND Category = "SaaS") -> only R2!
        or_filter = %{
          conjunction: "or",
          conditions: [
            %{field_id: channel.id, operator: "is", value: "Direct"},
            %{field_id: amount.id, operator: "gte", value: 400}
          ]
        }

        assert {:ok, %{records: [only_r2]}} =
                 Bases.query(ctx.actor, ctx.table.id, %{
                   filter: or_filter,
                   groups: [
                     %{field_id: occurred_at.id, bucket: "month", value_json: "\"2026-02\""},
                     %{field_id: category.id, value_json: "\"SaaS\""}
                   ]
                 })

        assert only_r2["id"] == by_name["R2"]

        # 2. Cumulative month slice from "2026-01" through "2026-02" -> R1, R2, R3 (excludes R4 in 2026-03 and R5 with NULL date)
        assert {:ok, %{records: cum_records}} =
                 Bases.query(ctx.actor, ctx.table.id, %{
                   group: %{
                     field_id: occurred_at.id,
                     bucket: "month",
                     value_json: "\"2026-02\"",
                     cumulative_from_json: "\"2026-01\""
                   },
                   sort: [%{field_id: ctx.primary.id, direction: "asc"}]
                 })

        assert Enum.map(cum_records, & &1["id"]) == [by_name["R1"], by_name["R2"], by_name["R3"]]

        # 3. Scalar "Other" drill-down excluding Top-1 category ("SaaS") -> R3, R4, R5 (non-null and != "SaaS")
        assert {:ok, %{records: scalar_other}} =
                 Bases.query(ctx.actor, ctx.table.id, %{
                   groups: [
                     %{field_id: category.id, other_exclude_values_json: ["\"SaaS\""]}
                   ],
                   sort: [%{field_id: ctx.primary.id, direction: "asc"}]
                 })

        assert Enum.map(scalar_other, & &1["id"]) == [
                 by_name["R3"],
                 by_name["R4"],
                 by_name["R5"]
               ]

        # 4. Array "Other" drill-down excluding Top-1 tag ("TopTag") -> R2 (has TailA) and R3 (has TailA, TailB), excluding R1 (only TopTag) and R4/R5 (empty/null)!
        assert {:ok, %{records: array_other}} =
                 Bases.query(ctx.actor, ctx.table.id, %{
                   groups: [
                     %{field_id: tags.id, other_exclude_values_json: ["\"TopTag\""]}
                   ],
                   sort: [%{field_id: ctx.primary.id, direction: "asc"}]
                 })

        assert Enum.map(array_other, & &1["id"]) == [by_name["R2"], by_name["R3"]]

        # 5. Cursor pagination binds to `groups` slices and rejects tampered slices.
        paged_query = %{
          groups: [%{field_id: tags.id, other_exclude_values_json: ["\"TopTag\""]}],
          sort: [%{field_id: ctx.primary.id, direction: "asc"}],
          page_size: 1
        }

        assert {:ok, %{records: [page1], page_token: token, complete: false}} =
                 Bases.query(ctx.actor, ctx.table.id, paged_query)

        assert page1["id"] == by_name["R2"]

        assert {:ok, %{records: [page2], complete: true}} =
                 Bases.query(ctx.actor, ctx.table.id, Map.put(paged_query, :page_token, token))

        assert page2["id"] == by_name["R3"]

        assert {:error, :invalid_page_token} =
                 Bases.query(
                   ctx.actor,
                   ctx.table.id,
                   paged_query
                   |> Map.put(:groups, [%{field_id: tags.id, other_exclude_values_json: []}])
                   |> Map.put(:page_token, token)
                 )
      end
    end

    test "exposes chart views, key-folding aggregate, and drill-down slices over /api/v2/pod JSON:API",
         ctx do
      {conn, api_uid} = console_conn_with_principal(ctx.conn)
      Ankole.Repo.put_tenant_id(ctx.tenant.id)
      api_actor = actor_fixture(api_uid)
      {:ok, api_page} = Pages.create(api_actor, %{type: "base", title: "API Viz Base"})
      {:ok, api_table} = Bases.create_table(api_actor, api_page.id, %{name: "API Deals"})
      [api_primary] = Bases.fields(api_table.id)
      amount = create_field!(api_actor, api_table.id, "Amount", "number")
      category = create_field!(api_actor, api_table.id, "Category", "text")

      assert {:ok, _} =
               Bases.write_records(api_actor, api_table.id, %{
                 creates: [
                   %{
                     data: %{api_primary.id => "Deal A", category.id => "Alpha", amount.id => 100}
                   },
                   %{data: %{api_primary.id => "Deal B", category.id => "Beta", amount.id => 30}},
                   %{data: %{api_primary.id => "Deal C", category.id => "Gamma", amount.id => 10}}
                 ]
               })

      created_view_conn =
        api_post(conn, "/api/v2/pod/tables/#{api_table.id}/views", %{
          name: "Top Categories",
          type: "chart",
          config: %{
            "chart" => %{
              "chart_type" => "bar",
              "query" => %{
                "group_by" => [%{"field_id" => category.id}],
                "metrics" => [
                  %{"operation" => "sum", "field_id" => amount.id, "alias" => "rev"}
                ]
              }
            }
          }
        })

      create_view_resp = api_response(created_view_conn, 200)
      assert create_view_resp["view"]["type"] == "chart"

      agg_conn =
        created_view_conn
        |> recycle_api()
        |> api_post("/api/v2/pod/tables/#{api_table.id}/aggregate", %{
          group_by: [%{field_id: category.id}],
          metrics: [
            %{operation: "sum", field_id: amount.id, alias: "rev"},
            %{operation: "count_distinct", field_id: category.id, alias: "cats"}
          ],
          omit_empty: true,
          order_by: [%{metric_alias: "rev", direction: "desc"}],
          top_n: %{limit: 1, include_other: true}
        })

      agg_resp = api_response(agg_conn, 200)

      assert [
               %{
                 "values" => ["Alpha"],
                 "other" => [false],
                 "metrics" => %{"rev" => 100, "cats" => 1},
                 "metrics_text" => %{"rev" => "100", "cats" => "1"}
               },
               %{
                 "values" => [nil],
                 "other" => [true],
                 "metrics" => %{"rev" => 40, "cats" => 2},
                 "metrics_text" => %{"rev" => "40", "cats" => "2"}
               }
             ] = agg_resp["groups"]

      query_conn =
        agg_conn
        |> recycle_api()
        |> api_post("/api/v2/pod/tables/#{api_table.id}/query", %{
          groups: [
            %{
              field_id: category.id,
              other_exclude_values_json: ["\"Alpha\""]
            }
          ]
        })

      query_resp = api_response(query_conn, 200)
      assert length(query_resp["records"]) == 2
    end
  end
end
