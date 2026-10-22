defmodule Ankole.Principals.Changes.RevokeHuman do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    principal = changeset.data

    changeset
    |> Ash.Changeset.force_change_attribute(:status, :disabled)
    |> Ash.Changeset.force_change_attribute(
      :access_version,
      principal.access_version + if(principal.status == :active, do: 1, else: 0)
    )
    |> Ash.Changeset.force_change_attribute(
      :access_revoked_at,
      if(principal.status == :active, do: DateTime.utc_now(), else: principal.access_revoked_at)
    )
  end
end
