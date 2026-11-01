defmodule Ankole.Principals.Principal.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.Principal`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals.Principal

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:rename_human, input, _context) do
    Ankole.Principals.Rename.from_console(:human, input.arguments)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:update_human, input, _context) do
    Ankole.Principals.update_human_in_tx(input.arguments)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Principal)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:change_human_membership, input, _context) do
    Ankole.Principals.change_human_membership_in_tx(
      input.arguments.uid,
      input.arguments.membership
    )
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:create_member, input, _context) do
    with(
      {:ok, principal} <- Ankole.Principals.create_member_in_tx(input.arguments),
      do: {:ok, %{uid: principal.uid, email: principal.human_user.email}}
    )
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end
end
