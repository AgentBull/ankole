defmodule Ankole.Pod.ContentUserFlowTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{BaseField, BaseRecord, BaseTable, Page, Pages}
  alias Ankole.Pod.Jobs.PurgePage

  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    owner = human_fixture().principal

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        case Ankole.Tenants.get(tenant.id) do
          {:ok, value} ->
            {:ok, _} = Ankole.Tenants.delete(value)

            Enum.reduce_while(1..100, :pending, fn _, _ ->
              case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => tenant.id}}) do
                :ok -> {:halt, :ok}
                {:snooze, _} -> {:cont, :pending}
              end
            end)

          _ ->
            :ok
        end
      end)
    end)

    %{owner: owner}
  end

  test "two opposite moves commit one legal tree through independent database connections", ctx do
    {:ok, a} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, b} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    parent = self()

    tasks =
      for {id, destination} <- [{a.id, b.id}, {b.id, a.id}] do
        Task.async(fn ->
          Repo.with_tenant(ctx.tenant.id, fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), id, %{
                  parent_id: destination
                })
            end
          end)
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :cycle}, &1)) == 1
    a = Repo.get!(Page, a.id)
    b = Repo.get!(Page, b.id)
    refute a.parent_id == b.id and b.parent_id == a.id
  end

  @tag timeout: 180_000
  test "measures single-page authorization and visible listing across 1000 direct page shares",
       ctx do
    reader = human_fixture().principal

    pages =
      for index <- 1..1000 do
        {:ok, page} =
          Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
            title: "Shared #{index}",
            private_owner_uid: ctx.owner.uid
          })

        {:ok, _} =
          Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
            grants: [%{principal_uid: reader.uid, role: "view"}]
          })

        page
      end

    assert Repo.aggregate(
             from(grant in Ankole.AuthZ.Grant,
               where: grant.principal_uid == ^reader.uid and grant.action == "page_view"
             ),
             :count
           ) == 1000

    page = List.last(pages)

    {authorize_us, authorized} =
      :timer.tc(fn ->
        Pages.authorize(Ankole.PrincipalsFixtures.actor_fixture(reader.uid), page.id, "page_view")
      end)

    assert {:ok, %{id: id}} = authorized
    assert id == page.id

    {list_us, result} =
      :timer.tc(fn -> Pages.list(Ankole.PrincipalsFixtures.actor_fixture(reader.uid)) end)

    assert {:ok, visible} = result
    assert MapSet.new(visible, & &1.id) == MapSet.new(pages, & &1.id)

    IO.puts(
      "Pod AuthZ measurement: shared_pages=1000 authorize_ms=#{Float.round(authorize_us / 1000, 3)} visible_list_ms=#{Float.round(list_us / 1000, 3)} visible_count=#{length(visible)}"
    )
  end

  test "a failed purge resumes after committed shard cleanup and blocks restoration", ctx do
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, database} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: root.id,
        type: "base"
      })

    table =
      Ankole.Pod.PagesFixtures.create_record!(BaseTable, :create_in_tx, %{
        page_id: database.id,
        name: "Orders",
        position: "U"
      })

    Ankole.Pod.PagesFixtures.create_record!(BaseField, :create_in_tx, %{
      table_id: table.id,
      name: "Title",
      position: "U",
      type: :text,
      is_primary: true
    })

    now = DateTime.utc_now(:microsecond)
    actor = Ankole.ActorRef.from_principal(ctx.owner)

    rows =
      for _ <- 1..1005,
          do: %{
            id: Ankole.Kernel.gen_uuid_v7(),
            tenant_id: ctx.tenant.id,
            table_id: table.id,
            data: %{},
            versions: %{},
            created_by: actor,
            updated_by: actor,
            created_at: now,
            updated_at: now
          }

    Repo.insert_all(BaseRecord, rows)
    Ankole.Pod.PagesFixtures.update_record!(table, :commit_write, %{delta: 1005, inserted: 1005})

    assert {:ok, _} =
             Ankole.Pod.Bases.create_field(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               table.id,
               %{name: "Related", type: "link", config: %{"table_id" => table.id}}
             )

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)
    root = Repo.get!(Page, root.id)
    Ankole.Pod.PagesFixtures.update_record!(root, :begin_purge)

    Repo.query!("""
    CREATE FUNCTION test_pod_purge_interrupt() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'injected purge interruption after shard cleanup'; END $$
    """)

    Repo.query!(
      "CREATE TRIGGER test_pod_purge_interrupt BEFORE DELETE ON base_fields FOR EACH ROW EXECUTE FUNCTION test_pod_purge_interrupt()"
    )

    try do
      # The purge returns the failed batch to Oban, which retries the job.
      assert {:error, %Ash.Error.Unknown{} = error} =
               PurgePage.perform(%Oban.Job{
                 args: %{"tenant_id" => ctx.tenant.id, "page_id" => root.id}
               })

      assert [%Ash.Error.Unknown.UnknownError{error: native_error}] = error.errors

      assert native_error ==
               "** (Postgrex.Error) ERROR P0001 (raise_exception) injected purge interruption after shard cleanup"

      assert Repo.aggregate(BaseRecord, :count) == 0
      assert Repo.get!(BaseTable, table.id).deleting_at

      Ankole.Pod.BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
        assert [[nil]] =
                 Ankole.Pod.BaseRepo.query!("SELECT to_regclass($1)::text", [
                   Ankole.Pod.BaseRepo.table(table.id)
                 ]).rows
      end)

      assert {:error, :not_found} =
               Ankole.Pod.Bases.query(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                 table.id,
                 %{}
               )

      assert Repo.get(Page, root.id)

      assert {:error, :cannot_restore} =
               Pages.restore(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)
    after
      Repo.query!("DROP TRIGGER IF EXISTS test_pod_purge_interrupt ON base_fields")
      Repo.query!("DROP FUNCTION IF EXISTS test_pod_purge_interrupt()")
    end

    assert :ok =
             PurgePage.perform(%Oban.Job{
               args: %{"tenant_id" => ctx.tenant.id, "page_id" => root.id}
             })

    assert is_nil(Repo.get(Page, root.id))
    assert is_nil(Repo.get(Page, database.id))
    assert Repo.aggregate(BaseTable, :count) == 0

    assert :ok =
             PurgePage.perform(%Oban.Job{
               args: %{"tenant_id" => ctx.tenant.id, "page_id" => root.id}
             })
  end
end
