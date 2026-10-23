defmodule Ankole.AuthZ.Group.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AuthZ.Group`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AuthZ.Group

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:ensure_synced_member, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.ensure_synced_group_member_in_tx(
      input.arguments.group_attrs,
      input.arguments.principal_uid
    )
    |> case do
      :ok -> {:ok, :ensured}
      error -> Ankole.Errors.wrap(error)
    end
  end

  defp action(:delete_operator_group, input, _context) do
    Ankole.AuthZ.Store.delete_operator_group(Ankole.Repo, input.arguments.name)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end

  defp action(:list_members, input, _context) do
    input.arguments.name
    |> Ankole.AuthZ.effective_group_members()
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap()
  end

  defp action(:preview_computed_members, input, _context),
    do: input.arguments.condition |> Ankole.AuthZ.preview_members() |> Ankole.Errors.wrap()

  defp action(:add_member, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.add_principal_to_group(
      input.arguments.principal_uid,
      input.arguments.name,
      Ankole.AuthZ.Root.admin_group_name()
    )
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end

  defp action(:remove_member, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.remove_principal_from_group(
      input.arguments.principal_uid,
      input.arguments.name,
      Ankole.AuthZ.Root.admin_group_name()
    )
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Group)
    |> Ankole.Errors.wrap(&Ankole.AuthZ.describe_group_refusal/1)
  end

  defp action(:add_synced_member, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.add_synced_group_member(
      args.group_id,
      args.domain,
      args.principal_uid
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:remove_synced_member, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.remove_synced_group_member(
      args.group_id,
      args.domain,
      args.principal_uid
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:replace_static_members, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.replace_static_group_members(
      input.arguments.group_id,
      input.arguments.expected_domain,
      input.arguments.principal_uids
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:apply_static_member_delta, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.apply_static_group_member_delta(
      input.arguments.group_id,
      input.arguments.expected_domain,
      input.arguments.added_uids,
      input.arguments.removed_uids
    )
    |> Ankole.Errors.wrap()
  end
end
