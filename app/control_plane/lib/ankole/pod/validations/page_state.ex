defmodule Ankole.Pod.Validations.PageState do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    parent = Ash.Changeset.get_attribute(changeset, :parent_id)
    owner = Ash.Changeset.get_attribute(changeset, :private_owner_uid)
    deleted = Ash.Changeset.get_attribute(changeset, :deleted_at)
    purge = Ash.Changeset.get_attribute(changeset, :purge_started_at)

    cond do
      parent && owner ->
        {:error, field: :private_owner_uid, message: "belongs to a root page only"}

      purge && is_nil(deleted) ->
        {:error, field: :purge_started_at, message: "requires a deleted page"}

      true ->
        :ok
    end
  end
end
