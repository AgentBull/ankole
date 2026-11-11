defmodule Ankole.Brain.DataSemanticsTest do
  use Ankole.DataCase, async: false
  require Ash.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.Brain
  alias Ankole.Brain.{ContextPack, Links, ObjectWrites, Objects, Tools.Context}
  alias Ankole.Brain.Schemas.{DatasetBinding, EntityIdentifier, Link, MetricRevision}
  alias Ankole.Pod.{Bases, Knowledge, Pages}

  setup do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("brain.enabled", true)
    owner = human_fixture().principal
    actor = actor_fixture(owner.uid)
    datasets = Ankole.BrainFixtures.category_fixture(owner.uid, "datasets")
    metrics = Ankole.BrainFixtures.category_fixture(owner.uid, "metrics")
    companies = Ankole.BrainFixtures.category_fixture(owner.uid, "companies")
    {:ok, base} = Pages.create(actor, %{type: "base", title: "Sales"})
    {:ok, %{tables: [table]}} = Bases.list_tables(actor, base.id)
    primary = Enum.find(Bases.fields(table.id), & &1.is_primary)
    {:ok, amount} = Bases.create_field(actor, table.id, %{name: "Amount", type: "number"})
    {:ok, region} = Bases.create_field(actor, table.id, %{name: "Region", type: "text"})

    %{
      owner: owner,
      actor: actor,
      datasets: datasets,
      metrics: metrics,
      companies: companies,
      base: base,
      table: table,
      primary: primary,
      amount: amount,
      region: region
    }
  end

  defp write_orders(ctx) do
    {:ok, _} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: [
          %{data: %{ctx.primary.id => "A", ctx.amount.id => 10, ctx.region.id => "north"}},
          %{data: %{ctx.primary.id => "B", ctx.amount.id => 20.5, ctx.region.id => "north"}},
          %{data: %{ctx.primary.id => "C", ctx.amount.id => 30, ctx.region.id => "south"}}
        ]
      })
  end

  defp create_object(ctx, category, title, metadata) do
    Pages.create(ctx.actor, %{
      type: :knowledge,
      parent_id: category.id,
      title: title,
      xml: "<page><p>#{title}</p></page>",
      metadata: metadata
    })
  end

  defp save(ctx, page_id, metadata, text \\ "Definition") do
    {:ok, %{page: page}} = Pages.get(ctx.actor, page_id)
    Knowledge.write(ctx.actor, page_id, page.revision, "<page><p>#{text}</p></page>", metadata)
  end

  defp dataset_meta(ctx) do
    %{
      "aliases" => ["orders ledger"],
      "grain" => "one row per order",
      "source" => %{"kind" => "base", "table_id" => ctx.table.id},
      "primary_key" => [ctx.primary.id]
    }
  end

  defp metric_meta(ctx, dataset_id, overrides \\ %{}) do
    Map.merge(
      %{
        "aliases" => ["GMV", "成交额"],
        "dataset" => dataset_id,
        "grain" => "order",
        "unit" => "CNY",
        "numerator" => "Sum of order amount",
        "parameters" => [%{"name" => "min_amount", "type" => "number", "default" => 0}],
        "addible_dimensions" => [%{"name" => "region", "field_id" => ctx.region.id}],
        "spec" => %{
          "metrics" => [
            %{"operation" => "sum", "field_id" => ctx.amount.id, "alias" => "value"}
          ],
          "filter" => %{
            "conditions" => [
              %{
                "field_id" => ctx.amount.id,
                "operator" => "gte",
                "value" => %{"$param" => "min_amount"}
              }
            ]
          }
        }
      },
      overrides
    )
  end

  defp metric_fixture(ctx) do
    {:ok, dataset} = create_object(ctx, ctx.datasets, "Orders", dataset_meta(ctx))
    {:ok, metric} = create_object(ctx, ctx.metrics, "GMV", metric_meta(ctx, dataset.id))
    {:ok, object} = Objects.get_by_slug(metric.id)
    %{dataset: dataset, metric: metric, slug: object.slug}
  end

  defp revisions(page_id),
    do:
      MetricRevision
      |> Ash.Query.filter(metric_page_id == ^page_id)
      |> Ash.Query.sort(revision: :asc)
      |> Ankole.Ash.read!()

  defp value(%{result: %{groups: [group]}}), do: group.metrics_text["value"]

  # A stored database connection whose catalog cache holds the given tables;
  # its host is never reached.
  defp warehouse(tables) do
    %{principal: admin} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Ankole.Connectors.Store.create_auth_config(admin, %{
        "plugin_id" => "postgresql",
        "slug" => "warehouse",
        "display_name" => "Warehouse",
        "auth_scheme" => "password",
        "public_metadata" => %{
          "host" => "127.0.0.1",
          "port" => 1,
          "database" => "warehouse",
          "tls_mode" => "disable"
        },
        "secret" => %{"username" => "reader", "password" => "unused"}
      })

    {:ok, _} = Ankole.Connectors.Databases.replace_catalog(config, tables, true)
    config
  end

  for mode <- [:inline, :physical] do
    test "a #{mode} Base metric executes its published revision with exact values", ctx do
      if unquote(mode) == :physical do
        {:ok, _} =
          Bases.create_field(ctx.actor, ctx.table.id, %{
            name: "Peer",
            type: "link",
            config: %{"table_id" => ctx.table.id}
          })
      end

      write_orders(ctx)
      %{dataset: dataset, metric: metric, slug: slug} = metric_fixture(ctx)
      assert {:ok, %{storage_mode: unquote(mode)}} = Bases.fetch_table(ctx.table.id)

      binding =
        Ankole.Ash.read_one!(Ash.Query.filter(DatasetBinding, dataset_page_id == ^dataset.id))

      assert binding.source_kind == :base
      assert binding.base_page_id == ctx.base.id
      assert binding.field_types == %{ctx.table.id => %{ctx.primary.id => "text"}}

      assert [%{revision: 1, status: :published} = revision] = revisions(metric.id)
      assert revision.approved_by.uid == ctx.owner.uid

      assert revision.field_types[ctx.table.id] == %{
               ctx.primary.id => "text",
               ctx.amount.id => "number",
               ctx.region.id => "text"
             }

      assert {:ok, result} = Brain.execute_metric(ctx.actor, slug, :latest, %{})
      assert value(result) == "60.5"
      assert result.revision.revision == 1
      assert result.revision.latest
      assert result.params == %{"min_amount" => 0}
      assert result.source["table_id"] == ctx.table.id
      assert result.metric.slug == slug
      assert result.data_versions == result.result.data_versions
      assert is_integer(result.data_versions[ctx.table.id])

      assert get_in(result.executed_spec, ["filter", "conditions", Access.at(0), "value"]) == 0

      assert {:ok, filtered} =
               Brain.execute_metric(ctx.actor, metric.id, 1, %{"min_amount" => 15})

      assert value(filtered) == "50.5"

      assert {:ok, by_region} =
               Brain.execute_metric(ctx.actor, slug, :latest, %{dimensions: ["region"]})

      assert by_region.dimensions == ["region"]

      assert by_region.result.groups |> Enum.map(& &1.metrics_text["value"]) |> Enum.sort() ==
               ["30", "30.5"]

      edges =
        Link
        |> Ash.Query.filter(origin_page_id == ^metric.id and link_source == "data_semantics")
        |> Ankole.Ash.read!()

      assert [%{link_type: "measures", to_page_id: to}] = edges
      assert to == dataset.id
    end
  end

  test "a changed definition appends a revision and pinned revisions keep executing", ctx do
    write_orders(ctx)
    %{dataset: dataset, metric: metric, slug: slug} = metric_fixture(ctx)

    assert {:ok, _} = save(ctx, metric.id, metric_meta(ctx, dataset.id), "Prose-only edit")
    assert [%{revision: 1}] = revisions(metric.id)

    count = %{
      "spec" => %{"metrics" => [%{"operation" => "count", "alias" => "value"}]},
      "unit" => "orders",
      "parameters" => []
    }

    assert {:ok, _} = save(ctx, metric.id, metric_meta(ctx, dataset.id, count))
    assert [%{revision: 1}, %{revision: 2} = second] = revisions(metric.id)
    assert second.unit == "orders"

    assert {:ok, latest} = Brain.execute_metric(ctx.actor, slug, :latest, %{})
    assert value(latest) == "3"
    assert latest.revision.revision == 2

    assert {:ok, pinned} = Brain.execute_metric(ctx.actor, slug, 1, %{})
    assert value(pinned) == "60.5"
    refute pinned.revision.latest
    assert pinned.definition.unit == "CNY"

    assert {:ok, _} = save(ctx, metric.id, %{"status" => "retired"})
    assert %{revision: 3, status: :retired} = List.last(revisions(metric.id))

    assert {:error, {:metric_not_found, %{status: :retired}}} =
             Brain.execute_metric(ctx.actor, slug, 1, %{})
  end

  test "strict carriers receive structured error codes", ctx do
    write_orders(ctx)
    %{dataset: dataset, slug: slug} = metric_fixture(ctx)

    assert {:error, {:metric_not_found, _}} =
             Brain.execute_metric(ctx.actor, "metrics/missing", :latest, %{})

    assert {:error, {:metric_revision_not_found, %{revision: 9}}} =
             Brain.execute_metric(ctx.actor, slug, 9, %{})

    assert {:error, {:invalid_metric_params, %{param: "channel"}}} =
             Brain.execute_metric(ctx.actor, slug, :latest, %{"channel" => "web"})

    assert {:error, {:invalid_metric_params, %{param: "min_amount"}}} =
             Brain.execute_metric(ctx.actor, slug, :latest, %{"min_amount" => "15"})

    assert {:error, {:dimension_not_addible, %{dimension: "customer", addible: ["region"]}}} =
             Brain.execute_metric(ctx.actor, slug, :latest, %{"dimensions" => ["customer"]})

    required = %{
      "parameters" => [%{"name" => "min_amount", "type" => "number", "required" => true}]
    }

    {:ok, other} =
      create_object(ctx, ctx.metrics, "Strict", metric_meta(ctx, dataset.id, required))

    assert {:error, {:invalid_metric_params, %{param: "min_amount", message: "is required"}}} =
             Brain.execute_metric(ctx.actor, other.id, :latest, %{})
  end

  test "invalid frontmatter rejects the save and keeps the page unchanged", ctx do
    %{dataset: dataset, metric: metric} = metric_fixture(ctx)
    {:ok, %{page: before}} = Pages.get(ctx.actor, metric.id)
    missing = Ecto.UUID.generate()

    broken =
      metric_meta(ctx, dataset.id, %{
        "spec" => %{"metrics" => [%{"operation" => "sum", "field_id" => missing, "alias" => "v"}]}
      })

    assert {:error, {:invalid_metric_definition, %{key: "spec", message: message}}} =
             save(ctx, metric.id, broken)

    assert message =~ missing

    assert {:error, {:invalid_metric_definition, %{key: "spec"}}} =
             save(
               ctx,
               metric.id,
               metric_meta(ctx, dataset.id, %{
                 "spec" => %{
                   "metrics" => [%{"operation" => "count", "alias" => "v"}],
                   "filter" => %{
                     "conditions" => [
                       %{
                         "field_id" => ctx.amount.id,
                         "operator" => "gte",
                         "value" => %{"$param" => "undeclared"}
                       }
                     ]
                   }
                 }
               })
             )

    assert {:error, {:invalid_metric_definition, %{key: "unit"}}} =
             save(ctx, metric.id, Map.delete(metric_meta(ctx, dataset.id), "unit"))

    assert {:error, {:invalid_metric_definition, %{key: "dataset"}}} =
             save(ctx, metric.id, %{"aliases" => ["GMV"]})

    assert {:error, {:invalid_dataset_definition, %{key: "source.table_id"}}} =
             save(ctx, dataset.id, put_in(dataset_meta(ctx), ["source", "table_id"], missing))

    assert {:error, {:invalid_dataset_definition, %{key: "joins_to"}}} =
             save(
               ctx,
               dataset.id,
               Map.put(dataset_meta(ctx), "joins_to", [%{"dataset" => dataset.id}])
             )

    {:ok, %{page: after_rejections}} = Pages.get(ctx.actor, metric.id)
    assert after_rejections.revision == before.revision
    assert [%{revision: 1}] = revisions(metric.id)

    assert {:error, {:invalid_metric_definition, %{key: "spec"}}} =
             create_object(ctx, ctx.metrics, "Broken", broken)

    refute Enum.any?(Pages.Tree.list_children(ctx.metrics.id), &(&1.title == "Broken"))
    assert {:ok, _draft} = create_object(ctx, ctx.metrics, "Draft", %{"aliases" => ["draft"]})
  end

  test "an Agent saves metric frontmatter as Markdown through write_object", ctx do
    agent = agent_fixture(%{owner_principal_uid: ctx.owner.uid}).principal

    {:ok, :ok} =
      Repo.transact(fn ->
        :ok =
          Ankole.Pod.Access.put_role(
            %{principal_uid: agent.uid},
            "drive:**:#{ctx.metrics.id}:**",
            "edit"
          )

        {:ok, :ok}
      end)

    {:ok, dataset} = create_object(ctx, ctx.datasets, "Orders", dataset_meta(ctx))

    markdown = """
    ---
    aliases: [Order count]
    dataset: #{dataset.id}
    grain: order
    unit: orders
    numerator: Orders in the ledger
    spec:
      metrics:
        - {operation: count, alias: value}
    ---
    Counts every order row.
    """

    context = %Context{
      querier_uid: agent.uid,
      disclosure: %{mode: :strict, asker_uid: ctx.owner.uid, present_uids: [ctx.owner.uid]}
    }

    assert {:ok, %{"status" => "saved", "object_id" => id}} =
             ObjectWrites.write(
               %{
                 "category" => "metrics",
                 "title" => "Order count",
                 "base_revision" => 0,
                 "markdown" => markdown
               },
               context
             )

    assert [%{revision: 1, spec: %{"metrics" => [%{"operation" => "count"}]}} = revision] =
             revisions(id)

    assert revision.approved_by.uid == agent.uid
  end

  test "Base schema drift marks revisions needs_review until the definition is saved again",
       ctx do
    write_orders(ctx)
    %{dataset: dataset, metric: metric, slug: slug} = metric_fixture(ctx)

    {:ok, total} =
      create_object(
        ctx,
        ctx.metrics,
        "Order total",
        metric_meta(ctx, dataset.id, %{"addible_dimensions" => []})
      )

    assert {:ok, _} = Bases.delete_field(ctx.actor, ctx.region.id, ctx.region.version)

    assert [%{status: :needs_review, review_reason: reason}] = revisions(metric.id)
    assert reason["missing_field_ids"] == [ctx.region.id]
    assert [%{status: :published}] = revisions(total.id)

    assert {:error, {:metric_needs_review, %{revision: 1}}} =
             Brain.execute_metric(ctx.actor, slug, :latest, %{})

    assert {:error, {:invalid_metric_definition, _}} =
             save(ctx, metric.id, metric_meta(ctx, dataset.id))

    assert {:ok, _} =
             save(ctx, metric.id, metric_meta(ctx, dataset.id, %{"addible_dimensions" => []}))

    assert [%{status: :needs_review}, %{revision: 2, status: :published}] = revisions(metric.id)

    assert {:ok, %{revision: %{revision: 2}}} =
             Brain.execute_metric(ctx.actor, slug, :latest, %{})

    amount = Enum.find(Bases.fields(ctx.table.id), &(&1.id == ctx.amount.id))

    assert {:ok, _} =
             Bases.update_field(ctx.actor, ctx.amount.id, %{
               type: "text",
               version: amount.version,
               clear_invalid: true
             })

    assert %{status: :needs_review, review_reason: %{"changed_field_ids" => [changed]}} =
             List.last(revisions(metric.id))

    assert changed == ctx.amount.id
    assert [%{status: :needs_review}] = revisions(total.id)
  end

  test "deleting a bound table marks dataset metrics needs_review", ctx do
    %{metric: metric} = metric_fixture(ctx)
    {:ok, _spare} = Bases.create_table(ctx.actor, ctx.base.id, %{name: "Spare"})

    assert {:ok, _} = Bases.delete_table(ctx.actor, ctx.table.id)

    assert [%{status: :needs_review, review_reason: %{"table_deleted" => true}}] =
             revisions(metric.id)
  end

  test "connector catalog refreshes mark revisions that read a missing column", ctx do
    warehouse([%{"schema" => "public", "name" => "invoices", "columns" => []}])

    connector = %{
      "grain" => "one row per invoice",
      "source" => %{
        "kind" => "connector",
        "connection" => "warehouse",
        "schema" => "public",
        "table" => "invoices"
      },
      "primary_key" => ["invoice_id"]
    }

    {:ok, dataset} = create_object(ctx, ctx.datasets, "Invoices", connector)

    meta = %{
      "dataset" => dataset.id,
      "grain" => "invoice",
      "unit" => "USD",
      "numerator" => "Invoice totals",
      "sql" => "SELECT sum(total) AS value FROM public.invoices WHERE issued_at >= $1",
      "columns" => ["total", "issued_at"],
      "parameters" => [%{"name" => "since", "type" => "date", "required" => true}]
    }

    {:ok, metric} = create_object(ctx, ctx.metrics, "Invoice total", meta)

    assert [%{source_kind: :connector, spec: %{"sql" => _}, source: %{"table" => "invoices"}}] =
             revisions(metric.id)

    # The connection's host is unreachable; the Connectors error passes through.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, reason} =
               Brain.execute_metric(ctx.actor, metric.id, :latest, %{"since" => "2026-01-01"})

      refute match?({:metric_not_found, _}, reason)
    end)

    assert {:ok, :ok} =
             Repo.transact(fn ->
               :ok =
                 Brain.connector_columns_missing_in_tx("warehouse", [
                   %{table: "invoices", schema: "public", column: "discount"},
                   %{table: "orders", column: "total"}
                 ])

               {:ok, :ok}
             end)

    assert [%{status: :published}] = revisions(metric.id)

    assert {:ok, :ok} =
             Repo.transact(fn ->
               :ok =
                 Brain.connector_columns_missing_in_tx("warehouse", [
                   %{"table" => "invoices", "column" => "total"}
                 ])

               {:ok, :ok}
             end)

    assert [%{status: :needs_review, review_reason: %{"connection" => "warehouse"}}] =
             revisions(metric.id)
  end

  test "a connector metric stores the schema that the catalog cache resolves", ctx do
    warehouse([
      %{"schema" => "public", "name" => "invoices", "columns" => []},
      %{"schema" => "archive", "name" => "invoices", "columns" => []},
      %{"schema" => "public", "name" => "ledger", "columns" => []}
    ])

    metric = fn table, connection ->
      {:ok, dataset} =
        create_object(ctx, ctx.datasets, "#{table} #{connection}", %{
          "grain" => "row",
          "source" => %{"kind" => "connector", "connection" => connection, "table" => table}
        })

      create_object(ctx, ctx.metrics, "#{table} #{connection} total", %{
        "dataset" => dataset.id,
        "grain" => "row",
        "unit" => "USD",
        "numerator" => "Totals",
        "sql" => "SELECT sum(total) AS value FROM #{table}",
        "columns" => ["total"]
      })
    end

    assert {:ok, ledger} = metric.("ledger", "warehouse")
    assert [%{source: %{"schema" => "public", "table" => "ledger"}}] = revisions(ledger.id)

    assert {:ok, :ok} =
             Repo.transact(fn ->
               :ok =
                 Brain.connector_columns_missing_in_tx("warehouse", [
                   %{"table" => "ledger", "schema" => "public", "column" => "total"}
                 ])

               {:ok, :ok}
             end)

    assert [%{status: :needs_review}] = revisions(ledger.id)

    assert {:error, {:invalid_metric_definition, %{key: "dataset", message: ambiguous}}} =
             metric.("invoices", "warehouse")

    assert ambiguous =~ "set source.schema"

    assert {:error, {:invalid_metric_definition, %{key: "dataset", message: uncached}}} =
             metric.("refunds", "warehouse")

    assert uncached =~ "refresh the connection's catalog"

    assert {:error, {:invalid_metric_definition, %{key: "dataset", message: missing}}} =
             metric.("ledger", "nowhere")

    assert missing =~ "does not exist"
  end

  test "a revision keeps its own dependency snapshot after its dataset is rebound", ctx do
    %{dataset: dataset, metric: metric} = metric_fixture(ctx)
    {:ok, other} = Bases.create_table(ctx.actor, ctx.base.id, %{name: "Other"})
    {:ok, _spare} = Bases.create_table(ctx.actor, ctx.base.id, %{name: "Spare"})
    other_primary = Enum.find(Bases.fields(other.id), & &1.is_primary)

    rebound =
      dataset_meta(ctx)
      |> put_in(["source", "table_id"], other.id)
      |> Map.put("primary_key", [other_primary.id])

    assert {:ok, _} = save(ctx, dataset.id, rebound)
    assert {:ok, _} = Bases.delete_table(ctx.actor, other.id)
    assert [%{status: :published}] = revisions(metric.id)

    assert {:ok, _} = Bases.delete_table(ctx.actor, ctx.table.id)

    assert [%{status: :needs_review, review_reason: %{"table_id" => table_id}}] =
             revisions(metric.id)

    assert table_id == ctx.table.id
  end

  test "deleting a link field that a metric path follows marks the revision needs_review",
       ctx do
    {:ok, items} = Bases.create_table(ctx.actor, ctx.base.id, %{name: "Items"})

    {:ok, link} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Items",
        type: "link",
        config: %{"table_id" => items.id}
      })

    {:ok, dataset} = create_object(ctx, ctx.datasets, "Orders", dataset_meta(ctx))

    {:ok, metric} =
      create_object(ctx, ctx.metrics, "Item count", %{
        "dataset" => dataset.id,
        "grain" => "order item",
        "unit" => "items",
        "numerator" => "Linked items",
        "spec" => %{"metrics" => [%{"operation" => "count", "path" => [link.id], "alias" => "n"}]}
      })

    assert [%{field_types: field_types}] = revisions(metric.id)
    assert field_types[ctx.table.id][link.id] == "link"
    assert field_types[items.id] == %{}

    assert {:error, {:invalid_metric_definition, %{message: message}}} =
             create_object(ctx, ctx.metrics, "Bad path", %{
               "dataset" => dataset.id,
               "grain" => "order",
               "unit" => "orders",
               "numerator" => "Orders",
               "spec" => %{
                 "metrics" => [
                   %{"operation" => "count", "path" => [ctx.amount.id], "alias" => "n"}
                 ]
               }
             })

    assert message =~ "not a link field"

    link = Enum.find(Bases.fields(ctx.table.id), &(&1.id == link.id))
    assert {:ok, _} = Bases.delete_field(ctx.actor, link.id, link.version)

    assert [%{status: :needs_review, review_reason: %{"missing_field_ids" => [missing]}}] =
             revisions(metric.id)

    assert missing == link.id
  end

  test "an Agent executes a Base metric through the brain tool without a database connection",
       ctx do
    write_orders(ctx)
    %{metric: metric, slug: slug} = metric_fixture(ctx)
    context = Context.for_subject(ctx.owner.uid)

    assert {:ok, output} =
             Ankole.Brain.Tools.execute(
               "metric_query",
               %{"metric_slug" => slug, "params" => %{"dimensions" => ["region"]}},
               context
             )

    assert output["revision"]["revision"] == 1
    assert output["dimensions"] == ["region"]
    assert output["data_versions"] == output["result"]["data_versions"]

    assert output["result"]["groups"] |> Enum.map(& &1["metrics_text"]["value"]) |> Enum.sort() ==
             ["30", "30.5"]

    assert {:error, {:metric_revision_not_found, %{revision: 9}}} =
             Ankole.Brain.Tools.execute(
               "metric_query",
               %{"metric_slug" => slug, "revision" => 9},
               context
             )

    assert %{status: :failed, error_code: "metric_revision_not_found"} =
             Ankole.AIGateway.HostedTools.Brain.run_job(%{
               kind: :brain,
               operation: "metric_query",
               params: %{"metric_slug" => slug, "revision" => 9},
               context: context
             })

    # A requester outside the metric's readers keeps it out of the conversation.
    reader = human_fixture().principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, metric.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.owner.uid, role: "manage"}]
      })

    strict = %{
      context
      | disclosure: %{mode: :strict, asker_uid: reader.uid, present_uids: [reader.uid]}
    }

    assert {:error, {:metric_not_found, _}} =
             Ankole.Brain.Tools.execute("metric_query", %{"metric_slug" => slug}, strict)

    assert {:ok, _} =
             Ankole.Brain.Tools.execute("metric_query", %{"metric_slug" => slug}, context)
  end

  test "a codex Job runs a Base metric through the read-tool broker", ctx do
    write_orders(ctx)
    %{slug: slug} = metric_fixture(ctx)
    agent = agent_fixture(%{owner_principal_uid: ctx.owner.uid}).principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.base.id, %{
        inherit_permissions: true,
        grants: [%{principal_uid: agent.uid, role: "view"}]
      })

    signal = Ankole.AIGateway.ResponseFixtures.signal_fixture(agent.uid, "job:1000", "job-turn")

    turn = %Ankole.Sessions.JobTurnRef{
      agent_uid: agent.uid,
      session_id: "job:1000",
      signal_id: signal.id,
      job_id: 1000,
      attempt: 1
    }

    read = fn args ->
      Ankole.Sessions.ReadToolBroker.handle_read(
        turn,
        struct!(Ankole.RuntimeFabric.V1.ReadToolRequest,
          name: "metric_query",
          arguments_json: Ankole.JSON.encode!(args)
        ),
        %{request_id: "r"}
      )
    end

    assert {:ok, result} = read.(%{"metric_slug" => slug})
    assert [%{"metrics_text" => %{"value" => "60.5"}}] = result["details"]["result"]["groups"]

    assert {:error, %{"code" => "metric_revision_not_found"}} =
             read.(%{"metric_slug" => slug, "revision" => 9})
  end

  test "a reader who cannot view the metric object cannot execute it", ctx do
    write_orders(ctx)
    %{metric: metric, slug: slug} = metric_fixture(ctx)
    reader = actor_fixture(human_fixture().principal.uid)

    owner_only = %{
      inherit_permissions: false,
      grants: [%{principal_uid: ctx.owner.uid, role: "manage"}]
    }

    assert {:ok, _} = Brain.execute_metric(reader, slug, :latest, %{})
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.base.id, owner_only)
    assert {:error, :forbidden} = Brain.execute_metric(reader, slug, :latest, %{})

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, metric.id, owner_only)

    assert {:error, {:metric_not_found, _}} = Brain.execute_metric(reader, slug, :latest, %{})
    assert {:ok, _} = Brain.execute_metric(ctx.actor, slug, :latest, %{})
  end

  test "an Applet backend executes a Base metric through metrics.query on a GET route", ctx do
    write_orders(ctx)
    %{slug: slug} = metric_fixture(ctx)

    {:ok, applet} =
      Pages.create(ctx.actor, %{
        type: "applet",
        title: "Dashboard",
        private_owner_uid: ctx.owner.uid
      })

    context = %{
      "principal" => %{"uid" => ctx.owner.uid},
      "applet" => %{"pageId" => applet.id, "revision" => 1},
      "method" => "GET"
    }

    assert {:ok, result} =
             Ankole.Pod.Applets.Capabilities.call(context, ctx.actor, "metrics.query", [
               slug,
               %{"revision" => 1, "params" => %{"min_amount" => 15}}
             ])

    assert [%{"metrics_text" => %{"value" => "50.5"}}] = result["result"]["groups"]
    assert result["revision"]["revision"] == 1

    assert {:error, %{code: "dimension_not_addible", status: 422}} =
             Ankole.Pod.Applets.Capabilities.call(context, ctx.actor, "metrics.query", [
               slug,
               %{"params" => %{"dimensions" => ["customer"]}}
             ])
  end

  test "entity identifiers are unique per namespace and value", ctx do
    {:ok, acme} =
      create_object(ctx, ctx.companies, "Acme", %{
        "identifiers" => %{"erp.supplier_id" => ["S-1", 42]}
      })

    assert ["42", "S-1"] ==
             EntityIdentifier
             |> Ash.Query.filter(entity_page_id == ^acme.id)
             |> Ankole.Ash.read!()
             |> Enum.map(& &1.value)
             |> Enum.sort()

    assert {:error, {:entity_identifier_conflict, %{namespace: "erp.supplier_id", value: "42"}}} =
             create_object(ctx, ctx.companies, "Acme copy", %{
               "identifiers" => %{"erp.supplier_id" => 42}
             })

    {:ok, vendor} = create_object(ctx, ctx.companies, "Vendor", %{})
    {:ok, acme_obj} = Objects.get_by_slug(acme.id)
    {:ok, vendor_obj} = Objects.get_by_slug(vendor.id)

    assert {:ok, :healthy_tx} =
             Repo.transact(fn ->
               assert :ok = Ankole.Brain.DataSemantics.sync_in_tx(acme_obj)

               assert {:error,
                       {:entity_identifier_conflict, %{namespace: "erp.supplier_id", value: "42"}}} =
                        Ankole.Brain.DataSemantics.sync_in_tx(%{
                          vendor_obj
                          | meta: %{"identifiers" => %{"erp.supplier_id" => 42}}
                        })

               assert :ok =
                        Ankole.Brain.DataSemantics.sync_in_tx(%{
                          vendor_obj
                          | meta: %{"identifiers" => %{"erp.supplier_id" => "S-2"}}
                        })

               {:ok, :healthy_tx}
             end)

    assert ["S-2"] ==
             EntityIdentifier
             |> Ash.Query.filter(entity_page_id == ^vendor.id)
             |> Ankole.Ash.read!()
             |> Enum.map(& &1.value)

    assert {:error, {:invalid_entity_identifiers, _}} =
             create_object(ctx, ctx.companies, "Blank", %{
               "identifiers" => %{"erp.supplier_id" => " "}
             })

    assert {:ok, _} = save(ctx, acme.id, %{"identifiers" => %{"erp.supplier_id" => "S-1"}})

    assert {:ok, _} =
             create_object(ctx, ctx.companies, "Acme copy", %{
               "identifiers" => %{"erp.supplier_id" => 42}
             })
  end

  test "metric and dataset aliases feed lookup and volunteer pointers", ctx do
    %{dataset: dataset, metric: metric} = metric_fixture(ctx)
    assert metric.id in Links.lookup_alias("gmv")
    assert dataset.id in Links.lookup_alias("Orders Ledger")

    pointers = ContextPack.volunteer_pointers(ctx.owner.uid, "上个月成交额是多少？")
    assert Enum.any?(pointers, &(&1.id == metric.id and &1.type == "metric"))
  end
end
