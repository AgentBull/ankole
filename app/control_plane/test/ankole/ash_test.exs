defmodule Ankole.AshTest do
  @moduledoc "Checks the Ash foundation: helpers, transaction owners, code interfaces, and tenancy."
  use Ankole.DataCase, async: false

  require Ash.Query

  alias Ankole.Errors.Invalid.Stale
  alias Ecto.Adapters.SQL
  alias TenantIsolationFixture.{Domain, Flag, Note, Probe}

  setup do
    for statement <- [
          """
          CREATE TEMP TABLE ash_tenant_probes (
            id uuid PRIMARY KEY, tenant_id uuid NOT NULL, global_key text NOT NULL UNIQUE,
            value text, note text, status text NOT NULL DEFAULT 'queued'
          ) ON COMMIT DROP
          """,
          "CREATE UNIQUE INDEX ash_tenant_probes_calculated_key_index ON ash_tenant_probes ((global_key || '/identity'))",
          "CREATE TEMP TABLE ash_site_probes (id uuid PRIMARY KEY, value text NOT NULL, data jsonb) ON COMMIT DROP",
          """
          CREATE TEMP TABLE ash_tenant_flags (
            id uuid PRIMARY KEY, tenant_id uuid NOT NULL, key text NOT NULL,
            flag boolean NOT NULL DEFAULT false
          ) ON COMMIT DROP
          """,
          "CREATE TEMP TABLE ash_tenant_notes (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, body text) ON COMMIT DROP"
        ],
        do: SQL.query!(Repo, statement)

    :ok
  end

  test "resource actions use the caller's transaction and generic actions own theirs" do
    for action <- Ash.Resource.Info.actions(Probe) do
      case action.type do
        :action ->
          assert action.transaction?

        type when type in [:create, :update, :destroy] ->
          refute action.transaction?
          assert action.error_handler == {Ankole.Errors, :shape, []}

        :read ->
          :ok
      end
    end

    finish = Ash.Resource.Info.action(Probe, :finish)
    refute finish.require_atomic? or finish.atomic_upgrade?
    assert Ash.Resource.Info.action(Probe, :set_note).require_atomic?
  end

  test "update_atomic changes one current row and gives Stale when no row matches" do
    {:ok, row} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "atomic"})

    assert {:ok, %{note: "record"}} = Ankole.Ash.update_atomic(row, :set_note, %{note: "record"})

    assert {:ok, %{note: "query"}} =
             Probe
             |> Ash.Query.filter(global_key == "atomic")
             |> Ankole.Ash.update_atomic(:set_note, %{note: "query"})

    other = create_tenant()

    result =
      Repo.with_tenant(other.id, fn ->
        Ankole.Ash.update_atomic(row, :set_note, %{note: "foreign"})
      end)

    assert {:error, %Ash.Error.Invalid{errors: [%Stale{resource: Probe}]}} = result
    assert Ankole.Errors.reason(result) == {:error, :stale}
    assert Repo.get!(Probe, row.id).note == "query"
  end

  test "update_where and destroy_where give the rows they changed" do
    for key <- ["a", "b", "c"], do: Ankole.Ash.create(Probe, :upsert_global, %{global_key: key})

    assert {:ok, updated} =
             Probe
             |> Ash.Query.filter(global_key in ["a", "b"])
             |> Ankole.Ash.update_where(:touch, %{value: "touched"})

    assert updated |> Enum.map(& &1.global_key) |> Enum.sort() == ["a", "b"]
    assert Enum.all?(updated, &(&1.value == "touched"))

    assert {:ok, []} =
             Probe
             |> Ash.Query.filter(global_key == "missing")
             |> Ankole.Ash.update_where(:touch, %{value: "never"})

    assert {:error, %Ash.Error.Invalid{}} =
             Ankole.Ash.update_where(Probe, :touch, %{unknown: "input"})

    assert {:ok, [%{global_key: "c"}]} =
             Probe |> Ash.Query.filter(global_key == "c") |> Ankole.Ash.destroy_where(:remove)

    assert Repo.aggregate(Probe, :count) == 2
  end

  test "insert_if_absent tells whether it created the row" do
    attrs = %{global_key: "once", value: "first"}
    assert {:ok, first, :created} = Ankole.Ash.insert_if_absent(Probe, :insert_once, attrs)

    assert {:ok, again, :existing} =
             Ankole.Ash.insert_if_absent(Probe, :insert_once, %{attrs | value: "second"})

    assert {again.id, again.value} == {first.id, "first"}
    other = create_tenant()

    assert {:error, %Ash.Error.Invalid{errors: [%Stale{}]}} =
             Repo.with_tenant(other.id, fn ->
               Ankole.Ash.insert_if_absent(Probe, :insert_once, attrs)
             end)
  end

  test "a locked Ash read gives its lock identity to the lock-order check" do
    id = Ankole.Ecto.UUIDv7.autogenerate()
    signals = Ankole.Signals.Signal |> Ash.Query.filter(id == ^id) |> Ash.Query.lock(:for_update)

    principals =
      Ankole.Principals.Principal
      |> Ash.Query.filter(uid == "lock-order-probe")
      |> Ash.Query.lock(:for_update)

    # A failed read in a transaction rolls back that transaction.
    assert {:error, %Ash.Error.Unknown{} = missing} =
             Repo.transact(fn -> Ankole.Ash.read(signals) end)

    assert Exception.message(missing) =~ "explicit lock_identity"

    assert {:ok, :checked} =
             Repo.transact(fn ->
               assert {:ok, []} = Ankole.Ash.read(signals, lock_identity: {"signals", id})

               assert {:ok, nil} =
                        Ankole.Ash.read_one(signals, lock_identity: {:rows, "signals", :id})

               assert Ankole.LockOrder.identity(nil) == nil
               {:ok, :checked}
             end)

    assert {:error, %Ash.Error.Unknown{} = order} =
             Repo.transact(fn ->
               {:ok, []} = Ankole.Ash.read(signals, lock_identity: {"signals", id})
               Ankole.Ash.read(principals, lock_identity: {"principals", "lock-order-probe"})
             end)

    assert Exception.message(order) =~ "work lock order violation"
  end

  test "domain code interfaces read the process tenant" do
    assert {:ok, row} = Domain.upsert_global_probe(%{global_key: "define"})
    assert row.tenant_id == Repo.tenant_id!()
    assert {:ok, [%{id: id}]} = Domain.list_probes()
    assert id == row.id
    assert {:ok, %{id: ^id}} = Domain.get_probe(row.id)
    assert {:ok, [%{id: ^id}]} = Domain.list_probes(query: [filter: [global_key: "define"]])
    assert {:ok, []} = Domain.list_probes(query: [filter: [global_key: "other"]])

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, []} = Domain.list_probes()
      assert {:ok, nil} = Domain.get_probe(row.id)
    end)

    assert {:ok, []} = Domain.list_site_probes()

    Repo.without_tenant(fn ->
      assert {:error, %Ash.Error.Invalid{}} = Domain.list_probes()
      assert {:ok, []} = Domain.list_site_probes()
    end)
  end

  test "a define cannot replace the tenant default options" do
    assert_raise Spark.Error.DslError, ~r/Ankole.Ash.default_options/, fn ->
      Code.compile_string("""
      defmodule Ankole.DomainDefaultsProbe#{System.unique_integer([:positive])} do
        use Ankole.Ash.Domain

        resources do
          resource TenantIsolationFixture.SiteProbe do
            define :list_site_probes, action: :read, default_options: [authorize?: true]
          end
        end
      end
      """)
    end
  end

  test "a generic action runs only as the top-level call" do
    assert {:ok, 0} = Ankole.Ash.run_action(Probe, :count_rows, %{})

    assert_raise Ash.Error.Framework, ~r/must run at the top level/, fn ->
      Repo.transact(fn -> Ankole.Ash.run_action(Probe, :count_rows, %{}) end)
    end
  end

  test "after_commit publishes only after a committed generic action" do
    assert {:ok, %Probe{global_key: "committed"}} = Domain.commit_note("committed", :commit)
    assert_received {:published, "committed", false}
    assert Repo.get_by(Probe, global_key: "committed")

    result = Domain.commit_note("rejected", :reject)
    assert {:error, %Ash.Error.Invalid{}} = result
    assert Ankole.Errors.reason(result) == {:error, :rejected_after_write}
    refute Repo.get_by(Probe, global_key: "rejected")

    assert_raise Ash.Error.Unknown, ~r/failed after its write/, fn ->
      Domain.commit_note("raised", :raise)
    end

    refute Repo.get_by(Probe, global_key: "raised")
    refute_received {:published, _key, _in_transaction?}
  end

  test "a no_attributes? relationship filter scopes both resources to the tenant" do
    {:ok, probe} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "flagged"})
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      {:ok, _foreign} = Ankole.Ash.create(Flag, :create, %{key: "flagged", flag: true})
    end)

    query = Ash.Query.filter(Probe, exists(marker, flag == true))
    {result, [sql]} = capture_sql(fn -> Ankole.Ash.read(query) end)
    assert {:ok, []} = result

    aliases =
      ~r/"(ash_tenant_probes|ash_tenant_flags)" AS (\w+)/
      |> Regex.scan(sql, capture: :all_but_first)
      |> Map.new(fn [table, name] -> {table, name} end)

    assert Map.keys(aliases) |> Enum.sort() == ["ash_tenant_flags", "ash_tenant_probes"]

    for {_table, name} <- aliases,
        do: assert(sql =~ ~s(#{name}."tenant_id"), "#{name} has no tenant condition: #{sql}")

    {:ok, _own} = Ankole.Ash.create(Flag, :create, %{key: "flagged", flag: true})
    assert {:ok, [%{id: id}]} = Ankole.Ash.read(query)
    assert id == probe.id
  end

  test "an Ankole.Schema table gets and filters by the process tenant" do
    assert Note.__tenancy__() == :tenant
    assert {:ok, note} = Repo.insert(%Note{body: "tenant note"})
    assert note.tenant_id == Repo.tenant_id!()
    assert [%Note{body: "tenant note"}] = Repo.all(Note)

    other = create_tenant()
    assert Repo.with_tenant(other.id, fn -> Repo.all(Note) end) == []

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(fn -> Repo.all(Note) end)
    end
  end

  test "the database clock is read through the Repo" do
    assert %DateTime{} = before = Repo.now!()
    assert DateTime.compare(Repo.now!(), before) in [:gt, :eq]
  end

  defp capture_sql(fun) do
    test = self()
    handler = "ash-test-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata.query =~ "ash_tenant_probes", do: send(test, {:sql, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, collect_sql([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_sql(found) do
    receive do
      {:sql, sql} -> collect_sql([sql | found])
    after
      0 -> Enum.reverse(found)
    end
  end
end
