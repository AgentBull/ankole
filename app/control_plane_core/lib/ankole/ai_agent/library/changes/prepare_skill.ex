defmodule Ankole.AIAgent.Library.Changes.PrepareSkill do
  @moduledoc false
  use Ash.Resource.Change
  alias Ankole.AIAgent.Library.SourceReader

  @impl true
  def change(changeset, _opts, _context) do
    with {:ok, name} <-
           SourceReader.normalize_skill_name(Ash.Changeset.get_attribute(changeset, :skill_name)),
         {:ok, path} <-
           SourceReader.normalize_virtual_path(
             Ash.Changeset.get_attribute(changeset, :relative_path)
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:skill_name, name)
      |> Ash.Changeset.force_change_attribute(:relative_path, path)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Ankole.Ash.DomainError.exception(reason: reason))
    end
  end
end
