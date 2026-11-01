defmodule Ankole.Pod.BasesContractTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.Pod.{Bases, BaseRecord, BaseTable, Pages}

  @limits %{
    "query_rows" => 1000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }
  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    Ankole.AppConfigure.Cache.clear_for_test()
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", @limits)
    human = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{type: "base"})

    {:ok, table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(human.uid), page.id, %{
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

  test "a committed Principal rename repairs physical Base references after a storage failure",
       ctx do
    actor = actor_fixture(ctx.human)
    {:ok, user} = Bases.create_field(actor, ctx.table.id, %{name: "Owner", type: "user"})

    {:ok, %{records: [record]}} =
      Bases.write_records(actor, ctx.table.id, %{
        creates: [%{data: %{user.id => [ctx.uid]}}]
      })

    {:ok, _} =
      Bases.create_field(actor, ctx.table.id, %{
        name: "Related",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    assert {:ok, %{table: %{storage_mode: :physical}}} = Bases.get_table(actor, ctx.table.id)
    shard = Ankole.Pod.BaseRepo.shard!()
    physical = Ankole.Pod.BaseRepo.table(ctx.table.id)
    [schema, name] = String.split(physical, ".")
    parked = "\"rename_repair_fixture\""

    Ankole.Pod.BaseRepo.with_shard(shard, fn ->
      Ankole.Pod.BaseRepo.query!("ALTER TABLE #{physical} RENAME TO #{parked}", [])
    end)

    try do
      assert {:ok, %{principal: renamed, base_repair_error: error}} =
               Ankole.Principals.rename(ctx.uid, "renamed-base-owner@example.com")

      assert is_binary(error)
      assert {:error, :not_found} = Ankole.Principals.get_principal(ctx.uid)
      assert renamed.uid == "renamed-base-owner@example.com"
    after
      Ankole.Pod.BaseRepo.with_shard(shard, fn ->
        Ankole.Pod.BaseRepo.query!("ALTER TABLE #{schema}.#{parked} RENAME TO #{name}", [])
      end)
    end

    new_uid = "renamed-base-owner@example.com"

    assert {:ok, [_changed]} =
             Bases.repair_principal_references(Repo.tenant_id!(), ctx.uid, new_uid)

    new_actor = actor_fixture(new_uid)

    assert {:ok, %{records: [repaired]}} =
             Bases.query(new_actor, ctx.table.id, %{ids: [record.id]})

    assert repaired["data"][user.id] == [new_uid]
    assert repaired["created_by"] == to_string(Ankole.ActorRef.from_actor(new_actor))
    assert repaired["updated_by"] == to_string(Ankole.ActorRef.from_actor(new_actor))
    assert {:ok, []} = Bases.repair_principal_references(Repo.tenant_id!(), ctx.uid, new_uid)
    assert {:ok, %{records: [same]}} = Bases.query(new_actor, ctx.table.id, %{ids: [record.id]})
    assert same == repaired
  end

  test "physical record and aggregate queries enforce the tenant statement timeout", ctx do
    actor = actor_fixture(ctx.uid)

    assert {:ok, _} =
             Bases.create_field(actor, ctx.table.id, %{
               name: "Related",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    assert {:ok, %{table: %{storage_mode: :physical}}} = Bases.get_table(actor, ctx.table.id)
    aggregate = %{metrics: [%{operation: "count", alias: "count"}]}
    assert {:ok, _} = Bases.query(actor, ctx.table.id, %{})
    assert {:ok, _} = Bases.aggregate(actor, ctx.table.id, aggregate)

    assert {:ok, _} =
             Ankole.AppConfigure.put_tenant_by_key(
               "pod.base.limits",
               Map.put(@limits, "statement_timeout_ms", 50)
             )

    parent = self()
    shard = Ankole.Pod.BaseRepo.shard!()
    table = Ankole.Pod.BaseRepo.table(ctx.table.id)

    holder =
      Task.async(
        Repo.bind_tenant(fn ->
          Ankole.Pod.BaseRepo.with_shard(shard, fn ->
            Ankole.Pod.BaseRepo.transact(fn ->
              Ankole.Pod.BaseRepo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE", [])
              send(parent, :physical_table_locked)

              receive do
                :release -> {:ok, :released}
              end
            end)
          end)
        end)
      )

    assert_receive :physical_table_locked, 5_000

    try do
      for operation <- [:query, :aggregate] do
        task =
          Task.async(
            Repo.bind_tenant(fn ->
              case operation do
                :query -> Bases.query(actor, ctx.table.id, %{})
                :aggregate -> Bases.aggregate(actor, ctx.table.id, aggregate)
              end
            end)
          )

        try do
          result = Task.yield(task, 2_000)

          case operation do
            :query ->
              assert {:ok, {:error, {:invalid_query, message}}} = result
              assert message =~ "statement timeout"

            :aggregate ->
              assert {:ok, {:error, :invalid_query}} = result
          end
        after
          Task.shutdown(task, :brutal_kill)
        end
      end
    after
      send(holder.pid, :release)
      assert {:ok, :released} = Task.await(holder, 5_000)
    end

    assert {:ok, _} = Bases.query(actor, ctx.table.id, %{})
    assert {:ok, _} = Bases.aggregate(actor, ctx.table.id, aggregate)
  end

  test "independent writers merge different fields and one stale same-field writer is rejected",
       ctx do
    {:ok, amount} =
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Amount",
        type: "number"
      })

    {:ok, note} =
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Note",
        type: "text"
      })

    {:ok, %{records: [record]}} =
      Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        creates: [%{data: %{amount.id => 1, note.id => "before"}}]
      })

    patches = [%{amount.id => 2}, %{note.id => "after"}]

    results =
      concurrent(ctx.tenant.id, patches, fn patch ->
        Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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
    current = Repo.get_by!(BaseRecord, table_id: ctx.table.id, id: record.id)
    assert current.data == %{amount.id => 2, note.id => "after"}

    results =
      concurrent(ctx.tenant.id, [3, 4], fn value ->
        Bases.write_records(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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
        "pod.base.limits",
        Map.put(@limits, "statement_timeout_ms", 15_000)
      )

    owner = self()

    assert {:ok, tasks} =
             Repo.transact(fn repo ->
               table =
                 repo.one!(from t in BaseTable, where: t.id == ^ctx.table.id, lock: "FOR UPDATE")

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
                               Bases.query(
                                 Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
                                 ctx.table.id,
                                 %{}
                               )

                             :write ->
                               Bases.write_records(
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
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Amount",
        type: "number"
      })

    {:ok, tag} =
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Group",
        type: "select",
        config: %{"options" => Enum.map(0..9, &%{"id" => "g#{&1}", "name" => "Group #{&1}"})}
      })

    {:ok, total} =
      Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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
    |> Enum.each(&Repo.insert_all(BaseRecord, &1))

    table = Repo.get!(BaseTable, ctx.table.id)

    Ankole.Pod.PagesFixtures.update_record!(table, :commit_write, %{
      delta: 100_000,
      inserted: 100_000
    })

    assert {:ok, _} =
             Bases.create_field(actor_fixture(ctx.uid), ctx.table.id, %{
               name: "Parent",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    assert {:ok, %{mode: "remote"}} = Bases.get_table(actor_fixture(ctx.uid), ctx.table.id)

    {filter_us, {:ok, filtered}} =
      :timer.tc(fn ->
        Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          filter: %{conditions: [%{field_id: tag.id, operator: "is", value: "g2"}]},
          page_size: 200
        })
      end)

    assert length(filtered.records) == 200

    {sort_us, {:ok, sorted}} =
      :timer.tc(fn ->
        Bases.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
          sort: [%{field_id: amount.id, direction: "desc"}],
          page_size: 200
        })
      end)

    assert hd(sorted.records)["data"][amount.id] == 100_000

    {aggregate_us, {:ok, aggregate}} =
      :timer.tc(fn ->
        Bases.aggregate(Ankole.PrincipalsFixtures.actor_fixture(ctx.uid), ctx.table.id, %{
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
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.uid),
               ctx.table.id,
               %{
                 creates: [%{data: %{amount.id => 1}}]
               }
             )

    assert Repo.aggregate(from(r in BaseRecord, where: r.table_id == ^ctx.table.id), :count) == 0

    assert {:ok, %{table: %{record_count: 100_000}}} =
             Bases.get_table(actor_fixture(ctx.uid), ctx.table.id)

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
                     AND wait_event_type = 'Lock' AND query LIKE '%base_tables%'
                     AND pg_blocking_pids(pid) && $2::integer[]
                   """,
                   [backends, [holder | backends]]
                 )

               blocked == length(backends)
             end)
  end

  test "physical writes do not wait for an inline writer on the same page", ctx do
    {:ok, physical} = Bases.create_table(actor_fixture(ctx.uid), ctx.page.id, %{name: "Physical"})

    {:ok, _} =
      Bases.create_field(actor_fixture(ctx.uid), physical.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => physical.id}
      })

    assert {:ok, :written} =
             Repo.transact(fn ->
               Repo.one!(
                 from(t in BaseTable, where: t.id == ^ctx.table.id, lock: "FOR NO KEY UPDATE")
               )

               writer =
                 Task.async(fn ->
                   Repo.with_tenant(ctx.tenant.id, fn ->
                     Bases.write_records(actor_fixture(ctx.uid), physical.id, %{
                       creates: [%{data: %{}}]
                     })
                   end)
                 end)

               assert {:ok, _} = Task.await(writer, 5_000)
               {:ok, :written}
             end)
  end

  test "an inline write completes while a physical writer waits on the same page", ctx do
    actor = actor_fixture(ctx.uid)
    {:ok, physical} = Bases.create_table(actor, ctx.page.id, %{name: "Physical"})

    {:ok, _} =
      Bases.create_field(actor, physical.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => physical.id}
      })

    base_repo = Ankole.Pod.BaseRepo

    base_repo.with_shard(ctx.tenant.base_db_id, fn ->
      assert {:ok, writer} =
               base_repo.transact(fn ->
                 [[holder]] = base_repo.query!("SELECT pg_backend_pid()", []).rows

                 base_repo.query!(
                   "SELECT table_id FROM #{base_repo.states()} WHERE table_id=$1::text::uuid FOR UPDATE",
                   [physical.id]
                 )

                 writer =
                   Task.async(fn ->
                     Repo.with_tenant(ctx.tenant.id, fn ->
                       Bases.write_records(actor, physical.id, %{creates: [%{data: %{}}]})
                     end)
                   end)

                 assert {:ok, true} =
                          wait_until(deadline(5_000), fn ->
                            base_repo.query!("SELECT pg_stat_clear_snapshot()", [])

                            [[waiting]] =
                              base_repo.query!(
                                "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))",
                                [holder]
                              ).rows

                            waiting
                          end)

                 assert {:ok, _} =
                          Bases.write_records(actor, ctx.table.id, %{creates: [%{data: %{}}]})

                 assert Task.yield(writer, 0) == nil
                 {:ok, writer}
               end)

      assert {:ok, _} = Task.await(writer, 5_000)
    end)
  end

  test "slow DDL exceeds the shard deadline and leaves a usable unchanged table", ctx do
    actor = actor_fixture(ctx.uid)

    {:ok, _} =
      Bases.create_field(actor, ctx.table.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    {:ok, field} = Bases.create_field(actor, ctx.table.id, %{name: "Value", type: "text"})
    {:ok, before} = Bases.get_table(actor, ctx.table.id)
    base_repo = Ankole.Pod.BaseRepo

    base_repo.with_shard(ctx.tenant.base_db_id, fn ->
      base_repo.query!(
        """
        CREATE FUNCTION test_base_slow_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF current_query() LIKE '%tbl_#{base_repo.hex(ctx.table.id)}%' THEN PERFORM pg_sleep(4); END IF;
        END $$
        """,
        []
      )

      base_repo.query!(
        "CREATE EVENT TRIGGER test_base_slow_ddl ON ddl_command_start WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION test_base_slow_ddl()",
        []
      )

      try do
        result =
          try do
            Ankole.Files.Access.write(
              nil,
              fn ->
                Ankole.Pod.Bases.Schema.update_field_in_tx(actor, field.id, %{
                  type: "number",
                  version: field.version
                })
              end,
              timeout: 3_000
            )
          rescue
            error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
          end

        assert {:error, _} = result
      after
        base_repo.query!("DROP EVENT TRIGGER test_base_slow_ddl", [])
        base_repo.query!("DROP FUNCTION test_base_slow_ddl()", [])
      end
    end)

    assert {:ok, after_timeout} = Bases.get_table(actor, ctx.table.id)
    assert after_timeout == before

    assert {:ok, _} =
             Bases.update_field(actor, field.id, %{type: "number", version: field.version})

    assert {:ok, _} =
             Bases.write_records(actor, ctx.table.id, %{creates: [%{data: %{field.id => 42}}]})
  end

  test "view edits succeed while a shard reader holds the link relation", ctx do
    actor = actor_fixture(ctx.uid)

    {:ok, link} =
      Bases.create_field(actor, ctx.table.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    Ankole.Pod.BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      assert {:ok, :checked} =
               Ankole.Pod.BaseRepo.transact(fn ->
                 Ankole.Pod.BaseRepo.query!(
                   "SELECT src_id,dst_id FROM #{Ankole.Pod.BaseRepo.edge(link.config["edge_table"])}",
                   []
                 )

                 writer =
                   Task.async(fn ->
                     Repo.with_tenant(ctx.tenant.id, fn ->
                       assert {:ok, view} =
                                Bases.create_view(actor, ctx.table.id, %{
                                  name: "Work",
                                  type: "grid"
                                })

                       assert {:ok, saved} =
                                Bases.update_view(actor, view.id, %{
                                  version: view.version,
                                  name: "Current work"
                                })

                       Bases.delete_view(actor, saved.id, saved.version)
                     end)
                   end)

                 assert {:ok, _} = Task.await(writer, 10_000)
                 {:ok, :checked}
               end)
    end)
  end

  test "a blocked physical DDL rolls back its control-plane field definition", ctx do
    {:ok, _} =
      Bases.create_field(actor_fixture(ctx.uid), ctx.table.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    {:ok, text} =
      Bases.create_field(actor_fixture(ctx.uid), ctx.table.id, %{name: "Value", type: "text"})

    Ankole.Pod.BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      assert {:ok, :checked} =
               Ankole.Pod.BaseRepo.transact(fn ->
                 Ankole.Pod.BaseRepo.query!(
                   "LOCK TABLE #{Ankole.Pod.BaseRepo.table(ctx.table.id)} IN ACCESS SHARE MODE",
                   []
                 )

                 writer =
                   Task.async(fn ->
                     Repo.with_tenant(ctx.tenant.id, fn ->
                       try do
                         Bases.update_field(actor_fixture(ctx.uid), text.id, %{
                           type: "number",
                           version: text.version
                         })
                       rescue
                         error in Postgrex.Error -> {:error, error.postgres.code}
                       end
                     end)
                   end)

                 assert {:error, :lock_not_available} = Task.await(writer, 10_000)
                 {:ok, :checked}
               end)
    end)

    assert Enum.find(Bases.fields(ctx.table.id), &(&1.id == text.id)).type == :text
    assert {:ok, _} = Bases.query(actor_fixture(ctx.uid), ctx.table.id, %{})
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
