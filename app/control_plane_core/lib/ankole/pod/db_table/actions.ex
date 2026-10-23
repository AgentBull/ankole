defmodule Ankole.Pod.DbTable.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Pod.DbTable`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_table, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.create_table_in_tx(a.uid, a.page_id, a.attrs)
    end)
  end

  defp action(:read_table, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Database.get_table_in_tx(a.uid, a.id))

  defp action(:query_records, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Database.query_in_tx(a.uid, a.id, a.attrs))

  defp action(:aggregate_records, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Database.aggregate_in_tx(a.uid, a.id, a.attrs))

  defp action(:write_records, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.write_records_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:copy_table, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Copy.table_in_tx(a.uid, a.id, a.attrs)
    end)
  end
end
