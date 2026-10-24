defmodule Ankole.AuthZ.Group.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AuthZ.Group`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AuthZ.Group

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:delete_operator_group, input, _context) do
    Ankole.AuthZ.Store.delete_operator_group(input.arguments.name)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end

  defp action(:list_members, input, _context) do
    input.arguments.name
    |> Ankole.AuthZ.effective_group_members_by_name()
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap()
  end

  defp action(:preview_computed_members, input, _context),
    do: input.arguments.condition |> Ankole.AuthZ.preview_members() |> Ankole.Errors.wrap()

  defp action(:add_member, input, _context) do
    Ankole.AuthZ.Store.add_principal_to_group_by_name(
      input.arguments.principal_uid,
      input.arguments.name,
      Ankole.AuthZ.Root.admin_group_name()
    )
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end

  defp action(:remove_member, input, _context) do
    Ankole.AuthZ.Store.remove_principal_from_group_by_name(
      input.arguments.principal_uid,
      input.arguments.name,
      Ankole.AuthZ.Root.admin_group_name()
    )
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end
end
