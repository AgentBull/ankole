defmodule Ankole.Pod.DatabaseContractTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.Pod.{Database, DbRecord, DbTable, Pages}

  @limits %{
    "local_rows" => 5000,
    "local_bytes" => 5_000_000,
    "query_rows" => 1000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }
  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    Ankole.AppConfigure.Cache.clear_for_test()
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", @limits)
    human = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{type: "database"})

    {:ok, table} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(human.uid), page.id, %{
        name: "Orders"
      })

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        {:ok, tenant} = Ankole.Tenants.get(tenant.id)
        {:ok, _} = Ankole.Tenants.delete(tenant)

        Enum.reduce_while(1..200, :pending, fn _, _ ->
          case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => tenant.id}}) do
            :ok -> {:halt, :ok}
            {:snooze, _} -> {:cont, :pending}
          end
        end)
      end)
    end)

    %{uid: human.uid, human: human, page: page, table: table}
  end

  test "independent writers merge different fields and one stale same-field writer is rejected",
       ctx do
    {:ok, amount} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Amount",
        type: "number"
      })

    {:ok, note} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Note",
        type: "text"
      })

    {:ok, %{records: [record]}} =
      Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 1, note.id => "before"}}]
      })

    patches = [%{amount.id => 2}, %{note.id => "after"}]

    results =
      concurrent(ctx.tenant.id, patches, fn patch ->
        Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          updates: [
            %{
              id: record.id,
              data: patch,
              expected_versions: Map.take(record.versions, Map.keys(patch))
            }
          ]
        })
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    current = Repo.get_by!(DbRecord, table_id: ctx.table.id, id: record.id)
    assert current.data == %{amount.id => 2, note.id => "after"}

    results =
      concurrent(ctx.tenant.id, [3, 4], fn value ->
        Database.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          updates: [
            %{id: record.id, data: %{amount.id => value}, expected_versions: %{amount.id => 2}}
          ]
        })
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:field_conflict, _}}, &1)) == 1
  end

  test "query and record writes return not found when purge deletes their table while they wait",
       ctx do
    {:ok, _} =
      Ankole.AppConfigure.put_tenant_by_key(
        "pod.database.limits",
        Map.put(@limits, "statement_timeout_ms", 15_000)
      )

    owner = self()

    assert {:ok, tasks} =
             Repo.transact(fn repo ->
               table =
                 repo.one!(from t in DbTable, where: t.id == ^ctx.table.id, lock: "FOR UPDATE")

               %{rows: [[holder]]} = repo.query!("SELECT pg_backend_pid()")

               tasks =
                 for operation <- [:query, :write], into: %{} do
                   task =
                     Task.async(fn ->
                       Repo.with_tenant(ctx.tenant.id, fn ->
                         # The operation owns its transaction on this checked-out connection.
                         Repo.checkout(fn ->
                           %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
                           send(owner, {:table_operation, operation, backend})

                           case operation do
                             :query ->
                               Database.query(
                                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                                 ctx.table.id,
                                 %{}
                               )

                             :write ->
                               Database.write_records(
                                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                                 ctx.table.id,
                                 %{
                                   creates: [%{data: %{}}]
                                 }
                               )
                           end
                         end)
                       end)
                     end)

                   {operation, task}
                 end

               backends =
                 for operation <- [:query, :write] do
                   assert_receive {:table_operation, ^operation, backend}, 5_000
                   backend
                 end

               assert MapSet.size(MapSet.new([holder | backends])) == 3
               assert_table_operations_blocked(backends, holder)
               repo.delete!(table)
               {:ok, tasks}
             end)

    for operation <- [:query, :write] do
      assert {:error, :not_found} = Task.await(Map.fetch!(tasks, operation), 10_000)
    end
  end

  @tag timeout: 120_000
  test "100000 rows use bounded SQL filter, sort, group, and aggregate and row 100001 rolls back",
       ctx do
    {:ok, amount} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Amount",
        type: "number"
      })

    {:ok, tag} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Group",
        type: "select",
        config: %{"options" => Enum.map(0..9, &%{"id" => "g#{&1}", "name" => "Group #{&1}"})}
      })

    {:ok, total} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Total",
        type: "formula",
        config: %{"source" => "[Amount] * 2"}
      })

    now = DateTime.utc_now(:microsecond)
    actor = Ankole.ActorRef.from_principal(ctx.human)

    1..100_000
    |> Stream.map(fn number ->
      %{
        tenant_id: ctx.tenant.id,
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        table_id: ctx.table.id,
        data: %{amount.id => number, tag.id => "g#{rem(number, 10)}"},
        versions: %{amount.id => 1, tag.id => 1},
        created_by: actor,
        updated_by: actor,
        created_at: now,
        updated_at: now
      }
    end)
    |> Stream.chunk_every(1000)
    |> Enum.each(&Repo.insert_all(DbRecord, &1))

    table = Repo.get!(DbTable, ctx.table.id)

    Ankole.Pod.PagesFixtures.update_record!(table, :commit_write, %{
      delta: 100_000,
      inserted: 100_000
    })

    {filter_us, {:ok, filtered}} =
      :timer.tc(fn ->
        Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          filter: %{conditions: [%{field_id: tag.id, operator: "is", value: "g2"}]},
          page_size: 200
        })
      end)

    assert length(filtered.records) == 200

    {sort_us, {:ok, sorted}} =
      :timer.tc(fn ->
        Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          sort: [%{field_id: amount.id, direction: "desc"}],
          page_size: 200
        })
      end)

    assert hd(sorted.records)["data"][amount.id] == 100_000

    {aggregate_us, {:ok, aggregate}} =
      :timer.tc(fn ->
        Database.aggregate(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          group_by: [%{field_id: tag.id}],
          metrics: [
            %{operation: "count", alias: "count"},
            %{operation: "sum", field_id: total.id, alias: "total"}
          ]
        })
      end)

    assert length(aggregate.groups) == 10
    assert Enum.all?(aggregate.groups, &(&1.metrics["count"] == 10_000))
    assert Enum.sum(Enum.map(aggregate.groups, & &1.metrics["total"])) == 10_000_100_000

    assert {:error, :record_limit} =
             Database.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{amount.id => 1}}]
               }
             )

    assert Repo.aggregate(from(r in DbRecord, where: r.table_id == ^ctx.table.id), :count) ==
             100_000

    IO.puts(
      "Pod 100000-row SQL milliseconds: " <>
        Torque.encode!(%{
          filter: filter_us / 1000,
          sort: sort_us / 1000,
          group_and_aggregate: aggregate_us / 1000
        })
    )
  end

  defp assert_table_operations_blocked(backends, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               Repo.query!("SELECT pg_stat_clear_snapshot()")

               %{rows: [[blocked]]} =
                 Repo.query!(
                   """
                   SELECT count(*) FROM pg_stat_activity
                   WHERE datname = current_database() AND pid = ANY($1::integer[])
                     AND wait_event_type = 'Lock' AND query LIKE '%db_tables%'
                     AND pg_blocking_pids(pid) && $2::integer[]
                   """,
                   [backends, [holder | backends]]
                 )

               blocked == length(backends)
             end)
  end

  defp concurrent(tenant, inputs, fun) do
    owner = self()

    tasks =
      Enum.map(inputs, fn input ->
        Task.async(fn ->
          Repo.with_tenant(tenant, fn ->
            send(owner, {:ready, self()})

            receive do
              :go -> fun.(input)
            end
          end)
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 20_000))
  end
end
