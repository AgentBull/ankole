defmodule Ankole.AuthZ.Grant.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AuthZ.Grant`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_permission_grant, input, _context) do
    Ankole.AuthZ.Grants.create_permission_grant(Ankole.Repo, input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:upsert_permission_grant, input, _context) do
    Ankole.AuthZ.Grants.upsert_permission_grant(Ankole.Repo, input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:delete_permission_grant, input, _context) do
    Ankole.AuthZ.Grants.delete_permission_grant(Ankole.Repo, input.arguments.id)
    |> Ankole.Errors.wrap()
  end

  defp action(:create_operator_grant, input, _context) do
    Ankole.AuthZ.Grants.create_operator_grant(Ankole.Repo, input.arguments)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Ankole.AuthZ.Group)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_operator_grant, input, _context) do
    Ankole.AuthZ.Grants.update_operator_grant(
      Ankole.Repo,
      input.arguments.id,
      Map.delete(input.arguments, :id)
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:delete_operator_grant, input, _context) do
    Ankole.AuthZ.Grants.delete_operator_grant(Ankole.Repo, input.arguments.id)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_permission_grant, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Grants.update_permission_grant(
      input.arguments.grant,
      input.arguments.attrs
    )
    |> Ankole.Errors.wrap()
  end
end
