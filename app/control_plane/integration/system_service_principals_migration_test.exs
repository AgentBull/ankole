defmodule Ankole.SystemServicePrincipalsMigrationTest.Repo do
  use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
end

defmodule Ankole.SystemServicePrincipalsMigrationTest do
  use ExUnit.Case, async: false
  alias Ankole.SystemServicePrincipalsMigrationTest.Repo
  @moduletag timeout: 120_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @previous 20_261_031_160_300
  @version 20_261_101_000_000

  setup do
    connection =
      Ankole.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options, :types])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(connection)
    database = "ankole_system_services_#{System.system_time(:microsecond)}"
    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)

    start_supervised!(
      {Repo, Keyword.merge(connection, database: database, pool_size: 4, log: false)}
    )

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(connection)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    Ecto.Migrator.run(Repo, @migrations, :up, to: @previous, log: false)
    :ok
  end

  test "existing tenants receive fixed system services and repeated migration does not duplicate them" do
    a = tenant!("service-a")
    b = tenant!("service-b")
    migrate!()
    migrate!()

    for tenant <- [a, b] do
      assert [["ankole_brain", "system"], ["system", "system"]] =
               Repo.query!(
                 "SELECT uid,type::text FROM principals WHERE tenant_id=$1 ORDER BY uid",
                 [tenant]
               ).rows
    end

    assert [[nil]] =
             Repo.query!("SELECT to_regclass('principals_one_system_per_tenant_index')").rows
  end

  test "a conflicting Principal stops the migration and preserves the original row and index" do
    a = tenant!("service-collision")

    Repo.query!(
      "INSERT INTO principals(tenant_id,uid,type,membership,display_name,inserted_at,updated_at) VALUES($1,'ankole_brain','human','member','Existing person',now(),now())",
      [a]
    )

    assert_raise Postgrex.Error, ~r/unique_violation/, fn -> migrate!() end

    assert [["human", "Existing person"]] =
             Repo.query!(
               "SELECT type::text,display_name FROM principals WHERE tenant_id=$1 AND uid='ankole_brain'",
               [a]
             ).rows

    assert [["principals_one_system_per_tenant_index"]] =
             Repo.query!("SELECT to_regclass('principals_one_system_per_tenant_index')::text").rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM schema_migrations WHERE version=$1", [@version]).rows
  end

  test "retired reset jobs are cancelled while completed history and other jobs survive" do
    migrate!()
    worker = "Ankole.Sessions.Jobs.EnqueueDailySessionResets"

    for state <- ~w(available scheduled retryable executing completed cancelled discarded) do
      Repo.query!(
        "INSERT INTO oban_jobs(queue,worker,state,args) VALUES('default',$1,$2::oban_job_state,'{}')",
        [worker, state]
      )
    end

    Repo.query!(
      "INSERT INTO oban_jobs(queue,worker,state,args) VALUES('default','Ankole.Sessions.Jobs.EnsureDriver','available','{}')"
    )

    Ecto.Migrator.run(Repo, @migrations, :up, to: 20_261_101_010_000, log: false)

    assert [["cancelled", 5], ["completed", 1], ["discarded", 1]] ==
             Repo.query!(
               "SELECT state::text,count(*) FROM oban_jobs WHERE worker=$1 GROUP BY state ORDER BY state::text",
               [worker]
             ).rows

    assert [[4]] ==
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker=$1 AND cancelled_at IS NOT NULL",
               [worker]
             ).rows

    assert [["available"]] ==
             Repo.query!(
               "SELECT state::text FROM oban_jobs WHERE worker='Ankole.Sessions.Jobs.EnsureDriver'"
             ).rows
  end

  defp tenant!(slug) do
    id = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

    Repo.query!(
      "INSERT INTO tenants(id,slug,display_name,base_db_id,inserted_at,updated_at) VALUES($1,$2,$2,'migration',now(),now())",
      [id, slug]
    )

    Repo.query!(
      "INSERT INTO principals(tenant_id,uid,type,display_name,inserted_at,updated_at) VALUES($1,'system','system','System',now(),now())",
      [id]
    )

    id
  end

  defp migrate!, do: Ecto.Migrator.run(Repo, @migrations, :up, to: @version, log: false)
end
