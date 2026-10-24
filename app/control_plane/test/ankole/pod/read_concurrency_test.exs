defmodule Ankole.Pod.ReadConcurrencyTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Database, Pages}

  setup %{tenant: tenant} do
    owner = human_fixture().principal
    viewer = human_fixture().principal

    for actor <- [owner, viewer] do
      assert {:ok, _} =
               AuthZ.create_permission_grant(%{
                 principal_uid: actor.uid,
                 resource_pattern: "tenant_console:**",
                 action: "update"
               })
    end

    {:ok, group} = Access.space_group()
    for grant <- Access.grants(group_id: group.id), do: AuthZ.delete_permission_grant(grant.id)
    [grant] = Access.grants(principal_uid: viewer.uid)

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Repo.delete_all(
          from j in Oban.Job, where: fragment("?->>'tenant_id' = ?", j.args, ^tenant.id)
        )

        for table <-
              (Ankole.Tenants.Jobs.Delete.tenant_tables() -- ["principals"]) ++ ["principals"] do
          Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1::text::uuid", [tenant.id])
        end

        Repo.delete!(tenant)
      end)
    end)

    %{owner: owner, viewer: viewer, grant: grant}
  end

  test "a move rechecks group authority after its initial destination check", ctx do
    revoker = prepare_revocation(:membership, ctx)

    {:ok, source} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Source"})

    {:ok, destination} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Destination"})

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, _ ->
        if Process.get(:move_authorization_count) != nil and
             String.contains?(meta.query, "all_anchors AS") do
          count = Process.get(:move_authorization_count) + 1
          Process.put(:move_authorization_count, count)

          if count == 2 do
            send(parent, {:destination_checked, self()})
            receive do: (:continue -> :ok)
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    mover =
      Task.async(
        Repo.bind_tenant(fn ->
          Process.put(:move_authorization_count, 0)

          Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.viewer.uid), source.id, %{
            parent_id: destination.id
          })
        end)
      )

    assert_receive {:destination_checked, pid}, 5_000
    assert {:ok, _} = Repo.transact(fn -> revoker.() end)
    send(pid, :continue)
    assert {:error, :forbidden} = Task.await(mover, 5_000)
    assert {:ok, %{parent_id: nil}} = Pages.fetch(source.id)
  end

  for revocation <- [:wildcard, :membership] do
    test "a multi-page read keeps its snapshot across #{revocation} revocation and new titles",
         ctx do
      revoker = prepare_revocation(unquote(revocation), ctx)

      pages =
        for index <- 1..3 do
          {:ok, page} =
            Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
              title: "Public title #{index}"
            })

          page
        end

      public_titles = Map.new(pages, &{&1.id, &1.title})
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, meta, _ ->
          if Process.get(:pause_anchor_read) == true and
               String.contains?(meta.query, "all_anchors AS") do
            Process.delete(:pause_anchor_read)
            send(parent, {:snapshot_ready, self()})
            receive do: (:continue -> :ok)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      reader =
        Task.async(
          Repo.bind_tenant(fn ->
            Process.put(:pause_anchor_read, true)
            Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(ctx.viewer.uid), nil)
          end)
        )

      assert_receive {:snapshot_ready, pid}, 5_000
      assert {:ok, _} = Repo.transact(fn -> revoker.() end)

      for page <- pages do
        assert {:ok, _} =
                 Pages.update(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
                   title: "Revoked secret"
                 })
      end

      assert {:ok, _} =
               Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
                 title: "New secret"
               })

      send(pid, :continue)
      assert {:ok, %{pages: results}} = Task.await(reader, 5_000)
      assert length(results) == 3
      assert Map.new(results, &{&1.id, &1.title}) == public_titles

      assert {:ok, %{pages: []}} =
               Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(ctx.viewer.uid), nil)

      assert {:ok, {"repeatable read", "on"}} =
               Repo.transact_repeatable_read_only(fn ->
                 [[level]] = Repo.query!("SHOW transaction_isolation").rows
                 [[readonly]] = Repo.query!("SHOW transaction_read_only").rows
                 {:ok, {level, readonly}}
               end)
    end
  end

  for operation <- [:query, :copy], revocation <- [:wildcard, :membership] do
    test "#{operation} checks #{revocation} revocation after waiting for the table lock", ctx do
      operation = unquote(operation)
      revoker = prepare_revocation(unquote(revocation), ctx)

      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "database"})

      {:ok, table} =
        Database.create_table(
          Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
          page.id,
          %{}
        )

      field = hd(Database.fields(table.id))
      parent = self()

      writer =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.transact(fn ->
              {:ok, _} = revoker.()

              {:ok, _} =
                Database.write_records_in_tx(
                  Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                  table.id,
                  %{
                    creates: [%{data: %{field.id => "Revoked secret"}}]
                  }
                )

              send(parent, {:secret_uncommitted, backend_pid()})
              receive do: (:commit -> {:ok, :written})
            end)
          end)
        )

      assert_receive {:secret_uncommitted, writer_pid}, 5_000

      reader =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.checkout(fn ->
              send(parent, {:reader_started, backend_pid()})
              read_operation(operation, ctx.viewer.uid, table.id)
            end)
          end)
        )

      assert_receive {:reader_started, reader_pid}, 5_000
      assert_blocked_by(reader_pid, writer_pid)
      send(writer.pid, :commit)
      assert {:ok, :written} = Task.await(writer, 5_000)
      assert {:error, :forbidden} = Task.await(reader, 5_000)

      assert {:ok, %{records: [record]}} =
               Database.query(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                 table.id,
                 %{}
               )

      assert record["data"][field.id] == "Revoked secret"
    end
  end

  test "Page state writes check revocation after the Page lock", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Page state"})

    parent = self()

    writer =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn ->
            {:ok, _} = AuthZ.Grants.delete_permission_grant(ctx.grant.id)

            {:ok, _} =
              Pages.update_in_tx(
                Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                page.id,
                %{title: "Revoked"}
              )

            send(parent, {:page_locked, backend_pid()})
            receive do: (:commit -> {:ok, :written})
          end)
        end)
      )

    assert_receive {:page_locked, writer_pid}, 5_000

    mutation =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:state_started, backend_pid()})

            Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.viewer.uid), page.id, %{
              favorite: true
            })
          end)
        end)
      )

    assert_receive {:state_started, state_pid}, 5_000

    try do
      assert_blocked_by(state_pid, writer_pid)
    after
      send(writer.pid, :commit)
      assert {:ok, :written} = Task.await(writer, 5_000)
    end

    assert {:error, :forbidden} = Task.await(mutation, 5_000)

    refute Repo.get_by(Ankole.Pod.PageUserState,
             principal_uid: ctx.viewer.uid,
             page_id: page.id
           )
  end

  test "an Agent tree write takes the tree lock before turn locks while Agent deletion waits",
       ctx do
    drivers = Ankole.SessionsCase.driver_pids()

    worker_provider =
      worker_provider_fixture(%{provider_id: "pod-tree-worker-#{Ecto.UUID.generate()}"})

    agent =
      Ankole.SessionsCase.agent_fixture(%{worker_provider_id: worker_provider.provider_id}).principal

    assert {:ok, %{"provider_id" => model_provider_id}} =
             Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "primary")

    on_exit(fn ->
      Ankole.SessionsCase.stop_new_drivers(drivers)

      Repo.with_tenant(ctx.tenant.id, fn ->
        delete_agent_fixture_rows(agent.uid, worker_provider.provider_id)
      end)

      assert {:ok, _} = Ankole.AgentWorkers.Providers.delete(worker_provider.provider_id)
      refute Repo.get(Ankole.AgentWorkers.Providers.Provider, worker_provider.id)
      assert {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(model_provider_id)
      assert {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(model_provider_id)

      assert {:error, :not_found} =
               Ankole.AIGateway.ProviderConfigs.fetch_provider(model_provider_id)
    end)

    route = "pod-tree-concurrency-#{System.unique_integer([:positive])}"
    {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    assert {:ok, _} = Ankole.Sessions.Admission.admit(signal, signal)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    assert {:ok, _} =
             Pages.space_agent(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               agent.uid,
               "edit"
             )

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, _ ->
        if Process.get(:pause_tree_write) == true and
             String.contains?(meta.query, "pg_advisory_xact_lock") do
          Process.delete(:pause_tree_write)
          send(parent, {:tree_locked, self(), backend_pid()})
          receive do: (:continue -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    writer =
      Task.async(
        Repo.bind_tenant(fn ->
          Process.put(:pause_tree_write, true)

          Pages.create(
            Ankole.PrincipalsFixtures.actor_fixture(agent.uid),
            %{title: "Agent page"},
            {ref, agent.uid}
          )
        end)
      )

    assert_receive {:tree_locked, writer_pid, backend}, 5_000

    deletion =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:delete_started, backend_pid()})
            Ankole.Principals.delete_agent(agent.uid)
          end)
        end)
      )

    assert_receive {:delete_started, deleter_backend}, 5_000
    assert_blocked_by(deleter_backend, backend)
    send(writer_pid, :continue)
    assert {:ok, %{title: "Agent page"}} = Task.await(writer, 10_000)
    assert {:ok, _} = Task.await(deletion, 10_000)
  end

  defp prepare_revocation(:wildcard, ctx),
    do: fn -> AuthZ.Grants.delete_permission_grant(ctx.grant.id) end

  defp prepare_revocation(:membership, ctx) do
    assert {:ok, _} = AuthZ.delete_permission_grant(ctx.grant.id)

    assert {:ok, group} =
             AuthZ.create_principal_group(%{name: "table-readers", display_name: "Table readers"})

    assert {:ok, _} = AuthZ.add_principal_to_group(ctx.viewer.uid, group.id)

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               group_id: group.id,
               resource_pattern: "tenant_console:**",
               action: "update"
             })

    fn ->
      AuthZ.Store.remove_principal_from_group(
        ctx.viewer.uid,
        group.id,
        AuthZ.Root.admin_group_name()
      )
    end
  end

  defp read_operation(:query, uid, id),
    do: Database.query(Ankole.PrincipalsFixtures.actor_fixture(uid), id, %{})

  defp read_operation(:copy, uid, id),
    do: Database.copy_table(Ankole.PrincipalsFixtures.actor_fixture(uid), id, %{})

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp assert_blocked_by(waiter, blocker),
    do: await_blocker(waiter, blocker, System.monotonic_time(:millisecond) + 5_000)

  defp await_blocker(waiter, blocker, deadline) do
    [[blocked]] =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter]).rows

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend #{waiter} did not wait for #{blocker}")

      true ->
        Process.sleep(5)
        await_blocker(waiter, blocker, deadline)
    end
  end
end
