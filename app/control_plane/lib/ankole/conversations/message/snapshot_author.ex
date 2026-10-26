defmodule Ankole.Conversations.Message.SnapshotAuthor do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :origin) == :native and
         is_nil(Ash.Changeset.get_attribute(changeset, :author_display_name)) do
      uid = Ash.Changeset.get_attribute(changeset, :author_uid)

      case Ankole.Principals.get_principal(uid) do
        {:ok, principal} ->
          Ash.Changeset.change_attribute(
            changeset,
            :author_display_name,
            Ankole.Conversations.NativeRoom.display_name(principal)
          )

        _ ->
          changeset
      end
    else
      changeset
    end
  end
end
