defmodule Ankole.Principals.LocalCredential.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.LocalCredential`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:complete_forced_password_change, input, _context) do
    Ankole.Principals.complete_forced_password_change_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.password_hash,
      input.arguments.credential_version
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:put_password, input, _context) do
    Ankole.Principals.put_local_password_in_tx(
      Ankole.Repo,
      input.arguments.uid,
      input.arguments.password_hash,
      input.arguments.must_change_password
    )
    |> Ankole.Errors.wrap()
  end
end
