defmodule Ankole.Brain.SearchPostgresTest do
  use ExUnit.Case, async: false

  setup do
    connection =
      Ankole.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options, :types])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(connection)
    database = "ankole_search_contract_#{System.system_time(:microsecond)}"
    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)
    db = start_supervised!({Postgrex, Keyword.put(connection, :database, database)})

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(connection)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    Postgrex.query!(db, "CREATE EXTENSION pg_search CASCADE", [])
    %{db: db}
  end

  test "generic BM25 plans preserve bound scope filters across scored index segments", %{db: db} do
    # Brain combines score() with scope filters outside the BM25 index. The
    # extension must retain solved parameters across every segment and row.
    # https://github.com/paradedb/paradedb/pull/6692
    Postgrex.query!(
      db,
      "CREATE TABLE search_contract (id bigint PRIMARY KEY, body text, scope text)",
      []
    )

    Postgrex.query!(
      db,
      """
      CREATE INDEX search_contract_idx ON search_contract USING bm25 (id, body)
      WITH (key_field='id', target_segment_count=16, mutable_segment_rows=0)
      """,
      []
    )

    for first <- [1, 501, 1001] do
      Postgrex.query!(
        db,
        """
        INSERT INTO search_contract
        SELECT g,
          repeat(CASE WHEN g % 4 = 0 THEN 'cobalt research ' ELSE 'graphite shipment ' END
            || md5(g::text) || ' ', 1 + g % 8),
          'scope-' || (g % 5)
        FROM generate_series($1::integer, $2::integer) g
        """,
        [first, first + 499]
      )
    end

    assert [[true]] =
             Postgrex.query!(
               db,
               "SELECT count(*) > 1 FROM paradedb.index_info('search_contract_idx')",
               []
             ).rows

    # Select the affected Base Scan path and reuse its parameterized plan.
    # Recall tests exercise the server's normal planner and parallel settings.
    Postgrex.query!(db, "SET max_parallel_workers_per_gather = 0", [])
    Postgrex.query!(db, "SET paradedb.enable_columnar_exec = false", [])
    Postgrex.query!(db, "SET plan_cache_mode = force_generic_plan", [])

    query =
      Postgrex.prepare!(db, "scoped_search", """
      SELECT id, pdb.score(id) > 0
      FROM search_contract WHERE body @@@ pdb.match($1) AND scope = $2 ORDER BY id
      """)

    plan =
      Postgrex.query!(db, "EXPLAIN EXECUTE scoped_search('cobalt', 'scope-1')", []).rows
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ "ParadeDB Base Scan"
    assert plan =~ "heap_filter"

    for scope <- [1, 3, 1] do
      expected = for id <- 1..1500, rem(id, 4) == 0 and rem(id, 5) == scope, do: [id, true]
      assert Postgrex.execute!(db, query, ["cobalt", "scope-#{scope}"]).rows == expected
    end

    assert [[generic, 0]] =
             Postgrex.query!(
               db,
               "SELECT generic_plans,custom_plans FROM pg_prepared_statements WHERE name='scoped_search'",
               []
             ).rows

    assert generic >= 3
  end
end
