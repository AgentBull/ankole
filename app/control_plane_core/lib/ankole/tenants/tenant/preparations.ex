defmodule Ankole.Tenants.Tenant.Preparations do
  @moduledoc """
  Runs the preparations of `Ankole.Tenants.Tenant` that call domain code.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, context), do: action(query.action.name, query, context)

  defp action(:privileged, query, _context) do
    case Ankole.Tenants.privileged_id() do
      {:ok, id} -> Ash.Query.filter(query, id == ^id)
      _missing -> Ash.Query.filter(query, false)
    end
  end
end
