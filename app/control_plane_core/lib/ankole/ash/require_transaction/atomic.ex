defmodule Ankole.Ash.RequireTransaction.Atomic do
  @moduledoc "Requires the caller's transaction for an atomic bulk action."
  use Ash.Resource.Change

  @impl true
  def atomic(_changeset, _opts, _context) do
    unless Ankole.Repo.in_transaction?(), do: raise(ArgumentError, "transaction required")
    :ok
  end
end
