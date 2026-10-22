defmodule Ankole.Ash.RequireTransaction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ankole.Repo.in_transaction?(),
      do: changeset,
      else: Ash.Changeset.add_error(changeset, "transaction required")
  end
end
