defmodule Ankole.AuthZ.ExternalBinding.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AuthZ.ExternalBinding`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:upsert_binding, input, _context) do
    Ankole.AuthZ.Store.upsert_external_binding(Ankole.Repo, input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end
end
