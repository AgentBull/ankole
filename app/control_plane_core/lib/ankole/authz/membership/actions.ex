defmodule Ankole.AuthZ.Membership.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AuthZ.Membership`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:sync_external_directory_memberships, input, _context) do
    Ankole.Repo
    |> Ankole.AuthZ.Store.sync_external_directory_group_memberships(
      input.arguments.provider,
      input.arguments.principal_uid,
      input.arguments.external_ids,
      input.arguments.opts
    )
    |> Ankole.Errors.wrap()
  end
end
