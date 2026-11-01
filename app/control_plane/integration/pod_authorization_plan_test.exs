defmodule Ankole.Pod.AuthorizationPlanTest do
  use Ankole.DataCase, async: false

  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{Pages}

  @moduletag sandbox: false, timeout: 1_800_000
  @page_count 500_000
  @anchor_count 8_000
  @userset_count 2_000
  @rounds 5
  @samples_per_round 20
  @warmups 5
  @capture_key {__MODULE__, :capture}

  setup_all do
    assert System.get_env("MIX_TEST_PARTITION") == "pod_authz_plan"
    :ok
  end

  setup %{tenant: tenant} do
    on_exit(fn -> cleanup_dataset!(tenant) end)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, public_root} = Nodes.public_root()
    roots = Enum.map(1..100, fn _ -> Ankole.Ecto.UUIDv7.autogenerate() end)

    boundaries =
      Enum.map(1..(@anchor_count - length(roots)), fn index ->
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          parent_id: Enum.at(roots, 2 + rem(index - 1, length(roots) - 2)),
          has_local_acl: index <= @userset_count,
          inherit_permissions: false
        }
      end)

    anchors =
      Enum.map(
        roots,
        &%{id: &1, parent_id: public_root.id, has_local_acl: true, inherit_permissions: true}
      ) ++
        boundaries

    now = DateTime.utc_now(:microsecond)

    base = %{
      tenant_id: tenant.id,
      type: :doc,
      created_by: Ankole.ActorRef.from_principal(owner),
      created_at: now,
      updated_at: now
    }

    anchors
    |> Stream.with_index()
    |> Stream.map(fn {anchor, index} ->
      Map.merge(base, %{
        id: anchor.id,
        parent_id: anchor.parent_id,
        position: position(index),
        title: title(index),
        inherit_permissions: anchor.inherit_permissions,
        has_local_acl: anchor.has_local_acl,
        acl_anchor_id: anchor.id,
        parent_anchor_id: anchor.parent_id
      })
    end)
    |> insert_rows(Ankole.Pod.Page)

    leaf_count = @page_count - @anchor_count

    anchors
    |> Stream.with_index()
    |> Stream.flat_map(fn {anchor, index} ->
      count =
        div(leaf_count, @anchor_count) +
          if(index < rem(leaf_count, @anchor_count), do: 1, else: 0)

      ids = Enum.map(1..count, fn _ -> Ankole.Ecto.UUIDv7.autogenerate() end)

      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, offset} ->
        parent = if offset < 10, do: anchor.id, else: Enum.at(ids, rem(offset, 10))

        Map.merge(base, %{
          id: id,
          parent_id: parent,
          position: position(offset),
          title: title(@anchor_count + index * 62 + offset),
          acl_anchor_id: anchor.id
        })
      end)
    end)
    |> insert_rows(Ankole.Pod.Page)

    direct_grants(roots, owner.uid, tenant.id, now)
    |> insert_rows(Ankole.AuthZ.Grant)

    boundaries
    |> Enum.take(@userset_count)
    |> Stream.with_index()
    |> Stream.map(fn {target, index} ->
      %{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        tenant_id: tenant.id,
        source_node_id: Enum.at(roots, 2 + rem(index, length(roots) - 2)),
        source_action: "node_view",
        target_node_id: target.id,
        target_scope: "container",
        resource_pattern: "drive:**:#{target.id}:**",
        action: "node_view",
        condition: "true",
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_rows(Ankole.AuthZ.Grant)

    assert Repo.query!(
             "SELECT count(*), count(*) FILTER (WHERE is_acl_anchor) FROM drive_nodes WHERE tenant_id = $1::text::uuid AND parent_id IS NOT NULL",
             [tenant.id]
           ).rows == [[@page_count, @anchor_count]]

    assert Repo.query!(
             "SELECT count(*) FROM permission_grants WHERE tenant_id = $1::text::uuid AND source_node_id IS NOT NULL",
             [tenant.id]
           ).rows == [[@userset_count]]

    Repo.query!("VACUUM (ANALYZE) drive_nodes", [], timeout: 180_000)
    Repo.query!("VACUUM (ANALYZE) pages", [], timeout: 180_000)
    Repo.query!("VACUUM (ANALYZE) permission_grants", [], timeout: 180_000)

    %{
      owner: Ankole.AuthZ.Actor.new(owner),
      roots: roots,
      public_root: public_root,
      userset_target: hd(boundaries)
    }
  end

  test "production authorization and retrieval record latency distributions and bounded index plans",
       context do
    {root_result, root_query} =
      capture_directory(fn -> Pages.list_children(context.owner, nil) end, nil)

    assert {:ok, %{pages: roots, next_cursor: nil}} = root_result
    assert MapSet.new(Enum.map(roots, & &1.id)) == MapSet.new(context.roots)
    root_plan = explain(root_query)

    root = hd(context.roots)
    destination = Enum.at(context.roots, 1)

    {child_result, child_query} =
      capture_directory(fn -> Pages.list_children(context.owner, root) end, root)

    assert {:ok, %{pages: children, next_cursor: nil}} = child_result
    assert length(children) == 10
    child_plan = explain(child_query)

    # The source becomes a pass-through subtree before measuring its move.
    # Other top-level nodes keep real direct grants, preserving 8,000 anchors.
    set_root_role(context.owner, root, nil)

    {move_result, move_query} =
      capture_query(
        fn -> Pages.move(context.owner, root, %{parent_id: destination}) end,
        :reanchor
      )

    assert {:ok, %{page: %{id: ^root, acl_anchor_id: ^destination}}} = move_result
    assert move_query.affected_rows == 62

    assert Repo.query!(
             "SELECT count(*) FROM drive_nodes WHERE tenant_id = $1::text::uuid AND acl_anchor_id = $2::text::uuid",
             [context.tenant.id, destination]
           ).rows == [[126]]

    plans = %{
      root: root_plan,
      child: child_plan,
      reanchor: explain(move_query)
    }

    assert {:ok, %{page: restored}} = Pages.move(context.owner, root, %{parent_id: nil})
    assert restored.id == root
    assert restored.acl_anchor_id == context.public_root.id
    set_root_role(context.owner, root, "manage")

    assert_dataset!(context.tenant.id)

    {graph_result, graph_query} =
      capture_query(fn -> Access.reachable_anchors(context.owner) end, :graph)

    assert {:ok, reachable} = graph_result
    assert map_size(reachable) == length(context.roots) + @userset_count + 2
    graph_plan = explain(graph_query)
    assert plan_failures(:graph, graph_plan) == []
    plans = Map.put(plans, :graph, graph_plan)

    searches =
      for {name, term} <- [search_broad: "Authorization", search_selective: "topic-00000007"],
          into: %{} do
        {result, query} = capture_query(fn -> Pages.search(context.owner, term) end, :search)
        assert {:ok, %{pages: pages}} = result
        assert length(pages) == 30

        [[matches]] =
          Repo.query!(
            "SELECT count(*) FROM pod_page_nodes WHERE tenant_id = $1::text::uuid AND title ILIKE ('%' || $2::text || '%')",
            [context.tenant.id, term]
          ).rows

        {name, %{term: term, matches: matches, query: query}}
      end

    moving = hd(children)

    {targeted_result, targeted_query} =
      capture_query(
        fn ->
          Access.reachable_anchors(context.owner, target_ids: [context.userset_target.id])
        end,
        :graph
      )

    assert {:ok, targeted} = targeted_result

    assert targeted ==
             Map.take(reachable, [
               context.userset_target.id,
               context.userset_target.parent_id,
               context.public_root.id
             ])

    plans = Map.put(plans, :targeted, explain(targeted_query))

    [[descendants]] =
      Repo.query!(
        """
        WITH RECURSIVE subtree AS (
          SELECT id FROM drive_nodes WHERE tenant_id = $1::text::uuid AND parent_id = $2::text::uuid
          UNION ALL
          SELECT p.id FROM drive_nodes p JOIN subtree s ON p.parent_id = s.id
          WHERE p.tenant_id = $1::text::uuid
        ) SELECT count(*) FROM subtree
        """,
        [context.tenant.id, moving.id]
      ).rows

    evidence = %{
      tenant_id: context.tenant.id,
      dataset: %{
        pages: @page_count,
        anchors_before_move: @anchor_count,
        business_roots: 2,
        top_level_direct_grants: length(context.roots) * 5,
        usersets: @userset_count,
        moved_descendants: move_query.affected_rows
      },
      postgres: Repo.query!("SELECT version()").rows,
      planner:
        Repo.query!(
          "SELECT name, setting FROM pg_settings WHERE name IN ('enable_seqscan', 'enable_indexscan', 'enable_indexonlyscan', 'random_page_cost', 'work_mem', 'shared_buffers', 'jit', 'max_parallel_workers_per_gather') ORDER BY name"
        ).rows,
      timing_scope:
        "Warm serial calls on a shared development machine in MIX_ENV=test. SQL targets use PostgreSQL EXPLAIN Execution Time. Domain durations include the production authorization, snapshot, transaction, hydration, and callback paths. These measurements do not establish a production latency bound.",
      queries:
        Map.new(
          Map.merge(
            %{
              root: root_query,
              child: child_query,
              reanchor: move_query,
              graph: graph_query,
              targeted: targeted_query
            },
            Map.new(searches, fn {name, search} -> {name, search.query} end)
          ),
          fn {name, query} -> {name, query_evidence(query)} end
        ),
      plans: plans,
      workload: %{
        concurrency: 1,
        directory_limit: 200,
        root_rows: length(roots),
        child_rows: length(children),
        reachable_anchors: map_size(reachable),
        title_shape: "Authorization plan fixture topic-NNNNNNNN page-NNNNNNNN",
        title_index:
          "Anchors use their zero-based index. Leaves use 8000 + anchor_index * 62 + leaf_offset.",
        topic_modulus: 1_000,
        searches:
          Map.new(searches, fn {name, search} -> {name, Map.take(search, [:term, :matches])} end),
        domain_move_descendants: descendants,
        sql_move_descendants: move_query.affected_rows
      }
    }

    output = evidence_path()

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(evidence, pretty: true))
    IO.puts("Pod authorization plan evidence #{output}")

    sql_workloads =
      [
        %{name: :root, query: root_query, rows: length(roots), p99: 3},
        %{name: :child, query: child_query, rows: length(children), p99: 3},
        %{name: :graph, query: graph_query, rows: map_size(reachable), p95: 6, p99: 15},
        %{name: :targeted, query: targeted_query, rows: map_size(targeted)},
        %{name: :reanchor, query: move_query, rows: move_query.affected_rows, p99: 5}
      ] ++
        Enum.map(searches, fn {name, search} ->
          %{
            name: name,
            query: search.query,
            rows: Map.new(search.query, &{&1.branch, &1.affected_rows}),
            p95: 30,
            p99: 60
          }
        end)

    domain_workloads =
      [
        %{
          name: :single_page,
          run: fn -> Pages.authorize(context.owner, moving.id, "node_view") end,
          validate: fn result ->
            assert {:ok, %{id: id}} = result
            assert id == moving.id
            1
          end,
          p99: 3
        },
        %{
          name: :graph,
          run: fn -> Access.reachable_anchors(context.owner) end,
          validate: fn result ->
            assert {:ok, actual} = result
            assert actual == reachable
            map_size(actual)
          end
        },
        %{
          name: :root,
          run: fn -> Pages.list_children(context.owner, nil, %{limit: 200}) end,
          validate: directory_validator(roots)
        },
        %{
          name: :child,
          run: fn -> Pages.list_children(context.owner, root, %{limit: 200}) end,
          validate: directory_validator(children)
        },
        %{
          name: :reanchor,
          run: fn -> Pages.move(context.owner, moving.id, %{parent_id: destination}) end,
          validate: fn result ->
            assert {:ok, %{page: %{id: id, parent_id: parent, acl_anchor_id: anchor}}} = result
            assert {id, parent, anchor} == {moving.id, destination, destination}

            assert Repo.query!(
                     "SELECT count(*) FROM drive_nodes WHERE tenant_id = $1::text::uuid AND acl_anchor_id = $2::text::uuid",
                     [context.tenant.id, destination]
                   ).rows == [[64 + descendants]]

            1 + descendants
          end,
          reset: fn ->
            assert {:ok, %{page: %{id: id, parent_id: ^root, acl_anchor_id: ^root}}} =
                     Pages.move(context.owner, moving.id, %{parent_id: root})

            assert id == moving.id
          end
        }
      ] ++
        Enum.map(searches, fn {name, search} ->
          %{
            name: name,
            run: fn -> Pages.search(context.owner, search.term) end,
            validate: fn result ->
              assert {:ok, %{pages: actual}} = result
              assert length(actual) == 30
              assert MapSet.size(MapSet.new(Enum.map(actual, & &1.id))) == 30

              assert Enum.all?(actual, fn page ->
                       String.contains?(String.downcase(page.title), String.downcase(search.term)) and
                         Bitwise.band(Access.page_bits(page, reachable), 1) != 0
                     end)

              30
            end
          }
        end)

    benchmark = benchmark(sql_workloads, domain_workloads)
    assert_dataset!(context.tenant.id)

    full_page = benchmark_full_page(context, output <> ".full-page")
    assert_dataset!(context.tenant.id)

    File.write!(
      output,
      Jason.encode!(Map.merge(evidence, %{benchmark: benchmark, full_page: full_page}),
        pretty: true
      )
    )

    failures =
      for {name, plan} <- plans,
          failure <- plan_failures(name, plan),
          do: {name, failure}

    assert failures == [], "Production plan mismatches #{inspect(failures)}. See #{output}"
  end

  defp benchmark_full_page(context, output) do
    converted =
      Repo.query!(
        """
        UPDATE drive_nodes p SET parent_id = $2::text::uuid, parent_anchor_id = $2::text::uuid, inherit_permissions = true, has_local_acl = true
        WHERE p.tenant_id = $1::text::uuid AND p.id IN (
          SELECT candidate.id FROM drive_nodes candidate
          WHERE candidate.tenant_id = $1::text::uuid AND candidate.is_acl_anchor
            AND candidate.parent_id IS NOT NULL AND NOT candidate.has_local_acl
          ORDER BY candidate.id LIMIT 100
        ) RETURNING p.id::text
        """,
        [context.tenant.id, context.public_root.id]
      ).rows
      |> Enum.map(&hd/1)

    direct_grants(
      converted,
      context.owner.principal.uid,
      context.tenant.id,
      DateTime.utc_now(:microsecond)
    )
    |> insert_rows(Ankole.AuthZ.Grant)

    assert length(converted) == 100
    parent = hd(converted)

    assert %{num_rows: 190} =
             Repo.query!(
               """
               UPDATE drive_nodes p SET parent_id = $2::text::uuid, acl_anchor_id = $2::text::uuid
               WHERE p.tenant_id = $1::text::uuid AND p.id IN (
                 SELECT candidate.id FROM drive_nodes candidate
                 WHERE candidate.tenant_id = $1::text::uuid AND NOT candidate.is_acl_anchor
                   AND candidate.acl_anchor_id <> $2::text::uuid
                   AND NOT EXISTS (
                     SELECT 1 FROM drive_nodes child
                     WHERE child.tenant_id = $1::text::uuid AND child.parent_id = candidate.id
                   )
                 ORDER BY candidate.id LIMIT 190
               )
               """,
               [context.tenant.id, parent]
             )

    Repo.query!("VACUUM (ANALYZE) drive_nodes", [], timeout: 180_000)
    Repo.query!("VACUUM (ANALYZE) pages", [], timeout: 180_000)

    workloads =
      for {name, parent_id} <- [root: nil, child: parent] do
        {result, query} =
          capture_directory(fn -> Pages.list_children(context.owner, parent_id) end, parent_id)

        assert {:ok, %{pages: pages, next_cursor: nil}} = result
        assert length(pages) == 200

        if name == :root,
          do:
            assert(MapSet.new(Enum.map(pages, & &1.id)) == MapSet.new(context.roots ++ converted))

        assert plan_failures(name, explain(query)) == []
        {name, parent_id, pages, query}
      end

    benchmark(
      Enum.map(workloads, fn {name, _, _, query} ->
        %{name: name, query: query, rows: 200, p99: 3}
      end),
      Enum.map(workloads, fn {name, parent_id, pages, _} ->
        %{
          name: name,
          run: fn -> Pages.list_children(context.owner, parent_id) end,
          validate: directory_validator(pages)
        }
      end),
      output
    )
  end

  defp position(index), do: index |> Integer.to_string() |> String.pad_leading(8, "0")

  defp title(index),
    do: "Authorization plan fixture topic-#{position(rem(index, 1_000))} page-#{position(index)}"

  defp evidence_path do
    System.get_env(
      "ANKOLE_POD_PLAN_EVIDENCE",
      Path.join(System.tmp_dir!(), "ankole-pod-authorization-plans.json")
    )
  end

  defp set_root_role(actor, id, role) do
    assert :ok =
             Repo.transact_top_level(fn ->
               Nodes.lock_tree()

               if is_nil(role) do
                 Access.grants(principal_uid: actor.principal.uid, target_node_id: id)
                 |> Enum.each(fn grant ->
                   assert {:ok, _} = Ankole.AuthZ.Grants.delete_permission_grant(grant.id)
                 end)
               else
                 Access.put_role(%{principal_uid: actor.principal.uid}, "drive:**:#{id}:**", role)
               end
             end)
  end

  defp direct_grants(ids, uid, tenant_id, now) do
    {:ok, actions} = Access.actions("manage")

    for id <- ids, action <- actions do
      %{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        tenant_id: tenant_id,
        principal_uid: uid,
        target_node_id: id,
        target_scope: "container",
        resource_pattern: "drive:**:#{id}:**",
        action: action,
        condition: "true",
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp insert_rows(rows, Ankole.Pod.Page) do
    rows
    |> Stream.chunk_every(1_000)
    |> Enum.each(fn batch ->
      nodes =
        Enum.map(batch, fn page ->
          page
          |> Map.drop([:type, :title, :position])
          |> Map.merge(%{kind: page.type, name: page.title})
        end)

      properties =
        Enum.map(
          batch,
          &Map.take(&1, [:id, :tenant_id, :title, :position, :created_at, :updated_at])
        )

      insert_rows(nodes, Ankole.Files.Schemas.Node)
      insert_rows(properties, Ankole.Pod.Properties)
    end)
  end

  defp insert_rows(rows, table) do
    rows
    |> Stream.chunk_every(1_000)
    |> Enum.each(fn batch ->
      assert {count, nil} = Repo.insert_all(table, batch, timeout: 180_000)
      assert count == length(batch)
    end)
  end

  defp capture_directory(operation, parent_id) do
    {result, queries} = capture_queries(operation, :all)

    page_reads =
      Enum.filter(queries, fn query ->
        Regex.match?(~r/\b(?:FROM|JOIN)\s+"?pod_page_nodes"?\s/i, query.sql) and
          not matches_query?(query.sql, :graph)
      end)

    # A child listing also validates its single parent. There is one retrieval
    # for the directory, with no second query to load the selected page IDs.
    assert length(page_reads) == if(is_nil(parent_id), do: 1, else: 2),
           inspect(Enum.map(page_reads, & &1.sql), pretty: true)

    assert [query] = Enum.filter(page_reads, &matches_query?(&1.sql, :directory))
    {result, query}
  end

  defp capture_query(operation, :search) do
    {result, queries} = capture_queries(operation, :search)

    queries =
      Enum.map(queries, fn query ->
        [_, branch] = Regex.run(~r/pod_search:(title|name|body)/, query.sql)
        Map.put(query, :branch, branch)
      end)

    assert Enum.sort(Enum.map(queries, & &1.branch)) == ["body", "name", "title"]
    {result, queries}
  end

  defp capture_query(operation, kind) do
    {result, queries} = capture_queries(operation, kind)
    assert [query] = queries
    {result, query}
  end

  defp capture_queries(operation, kind) do
    reference = make_ref()
    observer = self()

    :ok =
      :telemetry.attach(
        reference,
        [:ankole, :repo, :query],
        fn _, measurements, metadata, _ ->
          if Process.get(@capture_key) == reference and matches_query?(metadata.query, kind) do
            {:ok, result} = metadata.result

            send(
              observer,
              {reference,
               %{
                 sql: metadata.query,
                 params: metadata.params,
                 affected_rows: result.num_rows,
                 query_ms: native_ms(measurements.query_time),
                 queue_ms: native_ms(Map.get(measurements, :queue_time, 0)),
                 decode_ms: native_ms(Map.get(measurements, :decode_time, 0))
               }}
            )
          end
        end,
        nil
      )

    Process.put(@capture_key, reference)

    try do
      result = operation.()

      queries = received_queries(reference, [])
      assert queries != [], "Production #{kind} SQL did not reach PostgreSQL"
      {result, queries}
    after
      Process.delete(@capture_key)
      :telemetry.detach(reference)
    end
  end

  defp received_queries(reference, queries) do
    receive do
      {^reference, query} -> received_queries(reference, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp matches_query?(sql, :directory),
    do:
      String.contains?(sql, ~s(FROM "pod_page_nodes" AS)) and String.contains?(sql, "LIMIT") and
        not String.contains?(sql, "similarity(")

  defp matches_query?(sql, :search),
    do:
      String.contains?(sql, ~s(FROM "pod_page_nodes" AS)) and String.contains?(sql, "LIMIT") and
        String.contains?(sql, "similarity(")

  defp matches_query?(sql, :graph), do: String.contains?(sql, "all_anchors AS (")

  defp matches_query?(sql, :reanchor),
    do: String.contains?(sql, "WITH RECURSIVE affected_children AS")

  defp matches_query?(_sql, :all), do: true

  defp native_ms(native), do: System.convert_time_unit(native, :native, :nanosecond) / 1_000_000

  defp assert_dataset!(tenant_id) do
    assert Repo.query!(
             "SELECT count(*), count(*) FILTER (WHERE is_acl_anchor) FROM drive_nodes WHERE tenant_id = $1::text::uuid AND parent_id IS NOT NULL",
             [tenant_id]
           ).rows == [[@page_count, @anchor_count]]

    assert Repo.query!(
             "SELECT count(*) FROM permission_grants WHERE tenant_id = $1::text::uuid AND source_node_id IS NOT NULL",
             [tenant_id]
           ).rows == [[@userset_count]]
  end

  defp directory_validator(expected) do
    expected_ids = MapSet.new(Enum.map(expected, & &1.id))

    fn result ->
      assert {:ok, %{pages: actual, next_cursor: nil}} = result
      assert MapSet.new(Enum.map(actual, & &1.id)) == expected_ids
      length(actual)
    end
  end

  defp benchmark(sql_workloads, domain_workloads, output \\ evidence_path()) do
    before = host_load()
    File.write!(output <> ".samples.jsonl", "")

    Enum.each(1..@warmups, fn _ ->
      Enum.each(sql_workloads, &sql_sample/1)
      Enum.each(domain_workloads, &domain_sample/1)
    end)

    rounds =
      for round <- 1..@rounds do
        samples =
          for sample <- 1..@samples_per_round do
            work =
              Enum.map(sql_workloads, &{:sql, &1}) ++ Enum.map(domain_workloads, &{:domain, &1})

            offset = rem(round + sample, length(work))
            {head, tail} = Enum.split(work, offset)

            Enum.map(tail ++ head, fn
              {:sql, workload} ->
                Map.merge(sql_sample(workload), %{round: round, sample: sample})

              {:domain, workload} ->
                Map.merge(domain_sample(workload), %{round: round, sample: sample})
            end)
          end
          |> List.flatten()

        IO.puts("Pod latency round #{round}/#{@rounds} complete")

        File.write!(
          output <> ".samples.jsonl",
          Jason.encode!(%{round: round, host: host_load(), samples: samples}) <> "\n",
          [:append]
        )

        samples
      end

    samples = List.flatten(rounds)

    summaries =
      for {mode, workloads} <- [sql: sql_workloads, domain: domain_workloads], into: %{} do
        {mode,
         Map.new(workloads, fn workload ->
           selected = Enum.filter(samples, &(&1.mode == mode and &1.name == workload.name))
           distribution = distribution(Enum.map(selected, & &1.elapsed_ms))

           per_round =
             for round <- 1..@rounds do
               selected
               |> Enum.filter(&(&1.round == round))
               |> Enum.map(& &1.elapsed_ms)
               |> distribution()
               |> Map.put(:round, round)
             end

           targets =
             for percentile <- [:p95, :p99], Map.has_key?(workload, percentile), into: %{} do
               target = Map.fetch!(workload, percentile)

               {percentile,
                %{
                  target_ms: target,
                  measured_ms: distribution[percentile],
                  passed: distribution[percentile] < target
                }}
             end

           {workload.name,
            Map.merge(distribution, %{
              failures: 0,
              rows: selected |> Enum.map(& &1.rows) |> Enum.uniq(),
              rounds: per_round,
              round_p99_median_ms: distribution(Enum.map(per_round, & &1.p99)).p50,
              round_p99_range_ms: [
                Enum.min_by(per_round, & &1.p99).p99,
                Enum.max_by(per_round, & &1.p99).p99
              ],
              targets: targets
            })}
         end)}
      end

    profiles =
      Map.new(domain_workloads, fn workload ->
        started = System.monotonic_time()
        {result, queries} = capture_queries(workload.run, :all)
        wall_ms = native_ms(System.monotonic_time() - started)
        workload.validate.(result)
        if reset = Map.get(workload, :reset), do: reset.()

        encoded_queries = Enum.map(queries, &query_evidence/1)

        {workload.name,
         %{
           queries: encoded_queries,
           wall_ms: wall_ms,
           params_format: "Elixir inspect",
           query_count: length(queries),
           query_ms: Enum.sum(Enum.map(queries, & &1.query_ms))
         }}
      end)

    %{
      rounds: @rounds,
      samples_per_round: @samples_per_round,
      warmups_per_workload: @warmups,
      order:
        "Rotate SQL and domain workloads each sample. Restore the moved subtree outside each timed domain call.",
      percentile_method:
        "Nearest rank over all 100 successful samples per workload. Round summaries use 20 samples each.",
      environment: %{
        before: before,
        after: host_load(),
        mix_env: Mix.env(),
        schedulers_online: System.schedulers_online()
      },
      summaries: summaries,
      target_failures:
        for(
          {mode, workloads} <- summaries,
          {name, summary} <- workloads,
          {percentile, %{passed: false} = target} <- summary.targets,
          do: Map.merge(target, %{mode: mode, name: name, percentile: percentile})
        ),
      samples: samples,
      profiles: profiles,
      sql_plans: Map.new(sql_workloads, &{&1.name, explain(&1.query)})
    }
  end

  defp sql_sample(%{query: queries} = workload) when is_list(queries) do
    started = System.monotonic_time()
    plans = explain(queries)
    wire_ms = native_ms(System.monotonic_time() - started)

    branches =
      Enum.map(plans, fn plan ->
        %{
          name: plan["Search Branch"],
          rows: plan["Plan"]["Actual Rows"],
          elapsed_ms: plan["Execution Time"],
          planning_ms: plan["Planning Time"]
        }
      end)

    rows = Map.new(branches, &{&1.name, &1.rows})
    assert rows == workload.rows

    %{
      mode: :sql,
      name: workload.name,
      rows: rows,
      elapsed_ms: Enum.sum(Enum.map(branches, & &1.elapsed_ms)),
      planning_ms: Enum.sum(Enum.map(branches, & &1.planning_ms)),
      wire_ms: wire_ms,
      branches: branches
    }
  end

  defp sql_sample(workload) do
    started = System.monotonic_time()
    [plan] = explain(workload.query)
    wire_ms = native_ms(System.monotonic_time() - started)

    rows =
      if workload.name == :reanchor do
        node =
          Enum.find(
            plan_nodes(plan["Plan"]),
            &(&1["Node Type"] == "CTE Scan" and &1["Alias"] == "ac")
          )

        node["Actual Rows"] * node["Actual Loops"]
      else
        plan["Plan"]["Actual Rows"]
      end

    assert rows == workload.rows

    %{
      mode: :sql,
      name: workload.name,
      elapsed_ms: plan["Execution Time"],
      planning_ms: plan["Planning Time"],
      wire_ms: wire_ms,
      rows: rows
    }
  end

  defp domain_sample(workload) do
    started = System.monotonic_time()
    result = workload.run.()
    elapsed_ms = native_ms(System.monotonic_time() - started)
    rows = workload.validate.(result)
    if reset = Map.get(workload, :reset), do: reset.()
    %{mode: :domain, name: workload.name, elapsed_ms: elapsed_ms, rows: rows}
  end

  defp distribution(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    percentile = fn fraction -> Enum.at(sorted, ceil(count * fraction) - 1) end

    %{
      count: count,
      min: hd(sorted),
      max: List.last(sorted),
      p50: percentile.(0.5),
      p95: percentile.(0.95),
      p99: percentile.(0.99)
    }
  end

  defp host_load do
    {load, status} = System.cmd("uptime", [])
    {cores, core_status} = System.cmd("getconf", ["NPROCESSORS_ONLN"])

    %{
      uptime: String.trim(load),
      uptime_status: status,
      cpu_count: String.trim(cores),
      cpu_count_status: core_status
    }
  end

  defp query_evidence(queries) when is_list(queries), do: Enum.map(queries, &query_evidence/1)

  defp query_evidence(query),
    do: Map.update!(query, :params, &inspect(&1, limit: :infinity, printable_limit: :infinity))

  defp explain(queries) when is_list(queries) do
    Enum.flat_map(queries, fn query ->
      Enum.map(explain(query), &Map.put(&1, "Search Branch", query.branch))
    end)
  end

  defp explain(query) do
    {:error, plan} =
      Repo.transact(fn ->
        result =
          Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query.sql, query.params,
            timeout: 180_000
          )

        [[plan]] = result.rows
        Repo.rollback(plan)
      end)

    plan
  end

  defp plan_failures(name, [plan]) do
    nodes = plan_nodes(plan["Plan"])
    page_scans = Enum.filter(nodes, &(&1["Relation Name"] in ["drive_nodes", "pages"]))
    full_scans = Enum.filter(page_scans, &(&1["Node Type"] in ["Seq Scan", "Parallel Seq Scan"]))
    common = if full_scans == [], do: [], else: ["pages full scan #{inspect(full_scans)}"]

    required =
      case name do
        :graph ->
          []

        :targeted ->
          anchors = Enum.filter(nodes, &(&1["CTE Name"] == "all_anchors"))

          []
          |> mismatch(
            Enum.any?(page_scans, fn scan ->
              scan["Index Name"] in ["drive_nodes_pkey"] and
                scan["Actual Rows"] > 0
            end),
            "targeted dependencies must read pages through their tenant/id key"
          )
          |> mismatch(
            anchors != [] and Enum.all?(anchors, &(&1["Actual Rows"] <= 3)),
            "a one-Userset target must materialize only its target, source, and public-root anchors"
          )

        :reanchor ->
          traversal = Enum.filter(nodes, &(&1["Index Name"] == "drive_nodes_parent_index"))

          updates =
            Enum.filter(
              nodes,
              &(&1["Index Name"] == "drive_nodes_pkey" and &1["Alias"] == "target")
            )

          []
          |> mismatch(
            length(traversal) >= 2 and
              Enum.all?(traversal, &(&1["Node Type"] == "Index Only Scan")),
            "recursive child traversal must use drive_nodes_parent_index Index Only Scan"
          )
          |> mismatch(
            updates != [] and
              Enum.any?(updates, &(&1["Actual Rows"] > 0 and &1["Actual Loops"] > 0)),
            "nonempty UPDATE must use drive_nodes_pkey"
          )

        _ ->
          []
          |> mismatch(
            Enum.any?(
              nodes,
              &(&1["Index Name"] == "drive_nodes_live_children_index" and
                  &1["Node Type"] == "Index Only Scan" and &1["Actual Rows"] > 0)
            ),
            "directory must use drive_nodes_live_children_index Index Only Scan"
          )
      end

    common ++ required
  end

  defp mismatch(failures, true, _message), do: failures
  defp mismatch(failures, false, message), do: failures ++ [message]

  defp plan_nodes(node), do: [node | Enum.flat_map(node["Plans"] || [], &plan_nodes/1)]

  defp cleanup_dataset!(tenant) do
    Repo.checkout(
      fn ->
        Repo.with_tenant(tenant.id, fn ->
          assert {:ok, _} = Ankole.Tenants.delete(tenant)
          job = %Oban.Job{args: %{"tenant_id" => tenant.id}}

          Enum.reduce_while(1..3_600, nil, fn _, _ ->
            case Ankole.Tenants.Jobs.Delete.run(job) do
              :ok -> {:halt, :ok}
              {:snooze, _} -> {:cont, nil}
              error -> flunk("Plan dataset cleanup failed #{inspect(error)}")
            end
          end)

          refute Repo.get(Ankole.Tenants.Tenant, tenant.id)

          assert Repo.query!(
                   "SELECT (SELECT count(*) FROM drive_nodes WHERE tenant_id = $1::text::uuid), (SELECT count(*) FROM permission_grants WHERE tenant_id = $1::text::uuid)",
                   [tenant.id]
                 ).rows == [[0, 0]]

          if File.exists?(evidence_path()) do
            evidence = evidence_path() |> File.read!() |> Jason.decode!()

            if evidence["tenant_id"] == tenant.id do
              evidence =
                Map.put(evidence, "cleanup", %{
                  tenant_removed: true,
                  pages_remaining: 0,
                  grants_remaining: 0,
                  lifecycle: "Ankole.Tenants.Jobs.Delete.run/1"
                })

              File.write!(evidence_path(), Jason.encode!(evidence, pretty: true))
            end
          end
        end)
      end,
      timeout: 1_800_000
    )
  end
end
