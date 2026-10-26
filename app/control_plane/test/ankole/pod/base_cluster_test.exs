defmodule Ankole.Pod.BaseClusterTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.BaseCluster
  alias Ankole.Pod.{Bases, Pages}

  setup do
    config = Application.fetch_env!(:ankole, BaseCluster)
    on_exit(fn -> Application.put_env(:ankole, BaseCluster, config) end)
    %{config: config, shards: Keyword.fetch!(config, :databases)}
  end

  test "a Base pool can share the control-plane database without database creation", ctx do
    [[database]] = Repo.query!("SELECT current_database()", []).rows
    uri = URI.parse(hd(ctx.shards).url)

    shard = %{
      id: "base_default",
      url: URI.to_string(%{uri | path: "/" <> database}),
      pool_size: 2,
      stock_only: false
    }

    config =
      ctx.config
      |> Keyword.put(:databases, [shard | ctx.shards])
      |> Keyword.put(:create_databases, false)

    Application.put_env(:ankole, BaseCluster, config)
    {:ok, {_, children}} = BaseCluster.init([])
    start_supervised!(Enum.find(children, &(&1.id == shard.id)))
    {:ok, connection} = Postgrex.start_link(Ecto.Repo.Supervisor.parse_url(shard.url))

    try do
      Ankole.Pod.BaseRepo.with_shard(shard.id, fn ->
        assert [[^database]] = Ankole.Pod.BaseRepo.query!("SELECT current_database()", []).rows

        assert {:ok, :ok} =
                 Ankole.Pod.BaseRepo.transact(fn ->
                   Ankole.Pod.BaseRepo.ensure_schema!()
                   {:ok, :ok}
                 end)

        assert [[true]] =
                 Repo.query!("SELECT to_regclass($1) IS NOT NULL", [Ankole.Pod.BaseRepo.states()]).rows

        Ankole.Pod.BaseRepo.delete_tenant(shard.id)

        tenant = create_tenant(%{base_db_id: shard.id})

        Repo.with_tenant(tenant.id, fn ->
          try do
            actor = actor_fixture(human_fixture().principal.uid)
            {:ok, page} = Pages.create(actor, %{type: "base"})
            {:ok, %{tables: [table]}} = Bases.list_tables(actor, page.id)
            primary = Enum.find(Bases.fields(table.id), & &1.is_primary)

            assert {:ok, %{records: [record]}} =
                     Bases.write_records(actor, table.id, %{
                       creates: [%{data: %{primary.id => "Before promotion"}}]
                     })

            assert {:ok, _} =
                     Bases.create_field(actor, table.id, %{
                       name: "Related",
                       type: "link",
                       config: %{"table_id" => table.id}
                     })

            assert {:ok, %{mode: "local", table: %{storage_mode: :physical}}} =
                     Bases.get_table(actor, table.id)

            assert {:ok, _} =
                     Bases.write_records(actor, table.id, %{
                       updates: [
                         %{
                           id: record.id,
                           data: %{primary.id => "After promotion"},
                           expected_versions: record.versions
                         }
                       ]
                     })

            assert {:ok, %{records: [saved]}} = Bases.query(actor, table.id, %{ids: [record.id]})
            assert saved["data"][primary.id] == "After promotion"
          after
            assert {:ok, :ok} = Ankole.Pod.BaseRepo.delete_tenant(shard.id)
          end
        end)
      end)
    after
      stop_supervised!(shard.id)
      Postgrex.query!(connection, "DROP TABLE public._ankole_shard", [])
      GenServer.stop(connection)
    end
  end

  test "closed shards serve explicit assignments but do not receive automatic allocations", ctx do
    [open, vip | _] = ctx.shards
    shards = [%{open | stock_only: false}, %{vip | stock_only: true}]
    Application.put_env(:ankole, BaseCluster, Keyword.put(ctx.config, :databases, shards))

    for _ <- 1..20 do
      assert {:ok, id} = BaseCluster.allocate(Ecto.UUID.generate())
      assert id == open.id
    end

    assert {:ok, id} = BaseCluster.allocate(Ecto.UUID.generate(), vip.id)
    assert id == vip.id
    assert {:error, :unknown_base_db} = BaseCluster.allocate(Ecto.UUID.generate(), "missing")

    Application.put_env(
      :ankole,
      BaseCluster,
      Keyword.put(ctx.config, :databases, [%{vip | stock_only: true}])
    )

    assert {:error, :no_allocatable_base_db} = BaseCluster.allocate(Ecto.UUID.generate())
  end

  @tag capture_log: true
  test "an unavailable shard does not stop healthy pools and initializes when it reconnects",
       ctx do
    opts = Ecto.Repo.Supervisor.parse_url(hd(ctx.shards).url)
    {:ok, admin} = Postgrex.start_link(Keyword.put(opts, :database, "postgres"))
    name = "ankole_base_reconnect_" <> String.replace(Ecto.UUID.generate(), "-", "")
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{name}" TEMPLATE template0), [])
    uri = URI.parse(hd(ctx.shards).url)

    shard = %{
      hd(ctx.shards)
      | id: "base_reconnect",
        url: URI.to_string(%{uri | path: "/" <> name})
    }

    try do
      Postgrex.query!(admin, ~s(ALTER DATABASE "#{name}" ALLOW_CONNECTIONS false), [])

      config =
        ctx.config
        |> Keyword.put(:databases, ctx.shards ++ [shard])
        |> Keyword.put(:create_databases, false)

      Application.put_env(:ankole, BaseCluster, config)

      assert {:ok, {_, children}} = BaseCluster.init([])
      start_supervised!(Enum.find(children, &(&1.id == shard.id)))

      Ankole.Pod.BaseRepo.with_shard(hd(ctx.shards).id, fn ->
        assert [[1]] = Ankole.Pod.BaseRepo.query!("SELECT 1", []).rows
      end)

      Postgrex.query!(admin, ~s(ALTER DATABASE "#{name}" ALLOW_CONNECTIONS true), [])

      Ankole.Pod.BaseRepo.with_shard(shard.id, fn ->
        assert [["base_reconnect"]] =
                 Ankole.Pod.BaseRepo.query!(
                   "SELECT shard_id FROM public._ankole_shard",
                   [],
                   timeout: 10_000
                 ).rows
      end)
    after
      stop_supervised(shard.id)
      Postgrex.query!(admin, ~s|DROP DATABASE "#{name}" WITH (FORCE)|, [])
      GenServer.stop(admin)
    end
  end

  test "startup rejects an omitted assigned shard and a swapped URL", ctx do
    Application.put_env(:ankole, BaseCluster, Keyword.put(ctx.config, :databases, []))
    assert_raise RuntimeError, ~r/omits assigned shards/, fn -> BaseCluster.init([]) end
    [first, second | rest] = ctx.shards
    swapped = [%{first | url: second.url}, second | rest]
    Application.put_env(:ankole, BaseCluster, Keyword.put(ctx.config, :databases, swapped))
    assert_raise RuntimeError, ~r/identity mismatch/, fn -> BaseCluster.init([]) end
  end

  test "connection identity checks reject another shard without changing its identity", ctx do
    shard = hd(ctx.shards)
    {:ok, connection} = Postgrex.start_link(Ecto.Repo.Supervisor.parse_url(shard.url))

    try do
      assert :ok = BaseCluster.check_identity!(connection, shard.id)

      assert_raise RuntimeError, ~r/identity mismatch/, fn ->
        BaseCluster.check_identity!(connection, "wrong")
      end

      assert :ok = BaseCluster.check_identity!(connection, shard.id)
    after
      GenServer.stop(connection)
    end
  end

  test "startup rejects different database collations", ctx do
    shard = hd(ctx.shards)
    opts = Ecto.Repo.Supervisor.parse_url(shard.url)
    {:ok, connection} = Postgrex.start_link(Keyword.put(opts, :database, "postgres"))
    name = "ankole_base_locale_" <> String.replace(Ecto.UUID.generate(), "-", "")

    [[provider]] =
      Repo.query!(
        "SELECT datlocprovider::text FROM pg_database WHERE datname=current_database()",
        []
      ).rows

    other = if provider == "b", do: "libc", else: "builtin"

    Postgrex.query!(
      connection,
      ~s(CREATE DATABASE "#{name}" TEMPLATE template0 LOCALE_PROVIDER #{other} LOCALE 'C'),
      []
    )

    try do
      uri = URI.parse(shard.url)
      shards = [%{shard | url: URI.to_string(%{uri | path: "/" <> name})} | tl(ctx.shards)]
      Application.put_env(:ankole, BaseCluster, Keyword.put(ctx.config, :databases, shards))
      assert_raise RuntimeError, ~r/different collation/, fn -> BaseCluster.init([]) end
    after
      Postgrex.query!(connection, ~s(DROP DATABASE "#{name}"), [])
      GenServer.stop(connection)
    end
  end
end
