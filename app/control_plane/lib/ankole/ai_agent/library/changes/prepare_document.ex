defmodule Ankole.AIAgent.Library.Changes.PrepareDocument do
  @moduledoc false
  use Ash.Resource.Change
  alias Ankole.AIAgent.Library.SourceReader

  @impl true
  def change(changeset, _opts, _context) do
    case SourceReader.normalize_virtual_path(Ash.Changeset.get_attribute(changeset, :path)) do
      {:ok, path} ->
        content = Ash.Changeset.get_attribute(changeset, :content) || ""

        changeset
        |> Ash.Changeset.force_change_attribute(:path, path)
        |> Ash.Changeset.force_change_attribute(:content_hash, SourceReader.hash(content))

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: reason)
        )
    end
  end
end
