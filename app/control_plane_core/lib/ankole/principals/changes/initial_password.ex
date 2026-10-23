defmodule Ankole.Principals.Changes.InitialPassword do
  @moduledoc """
  Gives a local user action a generated one-time password and its hash.

  The hash is slow, so it is calculated before the action opens its
  transaction.
  """
  use Ash.Resource.Preparation

  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals.LocalCredential

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def prepare(input, _opts, _context) do
    Ash.ActionInput.before_transaction(input, fn input ->
      initial_password = LocalCredential.generate_initial_password()

      case LocalPassword.hash_password(initial_password) do
        {:ok, password_hash} ->
          input
          |> Ash.ActionInput.set_private_argument(:initial_password, initial_password)
          |> Ash.ActionInput.set_private_argument(:password_hash, password_hash)

        {:error, reason} ->
          {:error, Ankole.Errors.Invalid.Rejected.exception(reason: reason)}
      end
    end)
  end
end
