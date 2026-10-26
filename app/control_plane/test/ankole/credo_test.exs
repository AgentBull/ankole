Code.require_file("../../credo/append_in_loop.ex", __DIR__)
Code.require_file("../../credo/persistence_boundary.ex", __DIR__)
Code.require_file("../../credo/ash_boundary.ex", __DIR__)
Code.require_file("../../credo/raw_sql_tenant.ex", __DIR__)

defmodule Ankole.CredoTest do
  use ExUnit.Case, async: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:credo)
    :ok
  end

  test "the append gate finds growing accumulators, including nested namespace lists" do
    issues =
      issues("""
      defmodule Sample do
        def items(xs), do: Enum.reduce(xs, [], fn x, acc -> acc ++ [x] end)
        def nested(xs), do: Enum.reduce(xs, %{}, fn x, acc ->
          container = acc[x.name]
          Map.update!(container, :items, &(&1 ++ [x]))
        end)
      end
      """)

    assert length(issues) == 2
  end

  test "a one-time suffix and a fixed path prefix are not growing accumulators" do
    assert [] ==
             issues("""
             defmodule Sample do
               def suffix(xs, x), do: xs ++ [x]
               def paths(xs, path), do: Enum.reduce(xs, [], fn x, acc -> [path ++ [x] | acc] end)
               def linear(xs), do: Enum.reduce(xs, [], fn x, acc -> [x | acc] end) |> Enum.reverse()
             end
             """)
  end

  test "Ash mutations execute their filters and direct Ash, bulk actions, and hooks stay in the owners" do
    source = """
    defmodule Sample do
      update :finish do
        require_atomic?(true)
        filter(expr(status == :queued))
      end
      def direct(query), do: Ash.read!(query)
      def bulk(query), do: Ash.bulk_update(query, :finish, %{})
      def hook(changeset), do: Ash.Changeset.after_transaction(changeset, fn _, r -> r end)
    end
    """

    assert [_, _, _, _] = check(Ankole.Credo.AshBoundary, source, "sample.ex")

    assert [] ==
             check(
               Ankole.Credo.AshBoundary,
               """
               defmodule Sample do
                 update :finish do
                   require_atomic?(true)
                   change(filter(expr(status == :queued)))
                 end
                 read :queued do
                   filter(expr(status == :queued))
                 end
                 def direct(query), do: Ankole.Ash.read!(query)
                 def bulk(query), do: Ankole.Ash.bulk_update(query, :finish, %{})
               end
               """,
               "sample.ex"
             )
  end

  test "the persistence boundary allows a crossing only in a registered exception" do
    source = """
    defmodule Sample do
      alias Ankole.Repo

      def write(query) do
        Repo.transact(fn -> Repo.update_all(query, set: [value: 1]) end)
        Repo.one(from(row in query, lock: "FOR UPDATE"))
      end
    end
    """

    assert [_, _, _] = check(Ankole.Credo.AshBoundary, source, "sample.ex")

    assert [_] =
             check(
               Ankole.Credo.AshBoundary,
               "defmodule Sample, do: def(f(q), do: Ankole.Ash.read!(q))",
               "lib/ankole_web/sample.ex"
             )

    assert [_, _] =
             check(
               Ankole.Credo.AshBoundary,
               "defmodule Sample, do: def(f(q), do: Ash.read!(q))",
               "lib/ankole_web/sample.ex"
             )

    assert [] =
             check(
               Ankole.Credo.AshBoundary,
               String.replace(source, "Sample", "Ankole.Tenants.Jobs.Delete"),
               "sample.ex"
             )
  end

  test "raw SQL that reads a table binds the tenant or declares a site scope" do
    source = """
    defmodule Sample do
      alias Ankole.Repo
      def rows, do: Repo.query!("SELECT id FROM signals")
      def owned(id), do: Repo.query!("SELECT id FROM signals WHERE tenant_id = $1", [id])
      def clock, do: Repo.query!("SELECT clock_timestamp()")
    end
    """

    assert [_] = check(Ankole.Credo.RawSQLTenant, source, "sample.ex")

    site =
      String.replace(source, "alias Ankole.Repo", "alias Ankole.Repo\n  @raw_sql_scope :site")

    assert [] = check(Ankole.Credo.RawSQLTenant, site, "sample.ex")
  end

  defp check(check, source, path),
    do: source |> Credo.SourceFile.parse(path) |> check.run([])

  defp issues(source) do
    source |> Credo.SourceFile.parse("sample.ex") |> Ankole.Credo.AppendInLoop.run([])
  end
end
