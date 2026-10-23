defmodule Ankole.Pod.DbView.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Pod.DbView`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_view, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.create_view_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:update_view, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.update_view_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:delete_view, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.delete_view_in_tx(a.uid, a.id, a.version)
    end)
  end
end
