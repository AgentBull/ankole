Code.require_file("../../credo/append_in_loop.ex", __DIR__)
Code.require_file("../../credo/ash_actions.ex", __DIR__)

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

  test "Ash mutations execute their filters and bulk actions use the tenant facade" do
    source = """
    defmodule Sample do
      atomic_in_tx_update :finish do
        filter(expr(status == :queued))
      end
      def bulk(query), do: Ash.bulk_update(query, :finish, %{})
    end
    """

    assert [_, _] =
             source |> Credo.SourceFile.parse("sample.ex") |> Ankole.Credo.AshActions.run([])

    assert [] ==
             """
             defmodule Sample do
               atomic_in_tx_update :finish do
                 change(filter(expr(status == :queued)))
               end
               read :queued do
                 filter(expr(status == :queued))
               end
               def bulk(query), do: Ankole.Ash.bulk_update(query, :finish, %{})
             end
             """
             |> Credo.SourceFile.parse("sample.ex")
             |> Ankole.Credo.AshActions.run([])
  end

  defp issues(source) do
    source |> Credo.SourceFile.parse("sample.ex") |> Ankole.Credo.AppendInLoop.run([])
  end
end
