defmodule Ankole.Pod.DbField.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Pod.DbField`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_field, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.create_field_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:update_field, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.update_field_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:delete_field, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Database.Schema.delete_field_in_tx(a.uid, a.id, a.version)
    end)
  end
end
