defmodule Ankole.AIAgent.Library.Changes.PrepareLesson do
  @moduledoc false
  use Ash.Resource.Change
  alias Ankole.AIAgent.Library.{SkillLessons, SourceReader}

  @impl true
  def change(changeset, _opts, _context) do
    content = Ash.Changeset.get_attribute(changeset, :content)
    author_kind = Ash.Changeset.get_attribute(changeset, :author_kind)

    with :ok <- SkillLessons.validate_lesson_content(content, author_kind),
         {:ok, name} <-
           SourceReader.normalize_skill_name(Ash.Changeset.get_attribute(changeset, :skill_name)) do
      changeset
      |> Ash.Changeset.force_change_attribute(:content, String.trim(content))
      |> Ash.Changeset.force_change_attribute(:skill_name, name)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Ankole.Ash.DomainError.exception(reason: reason))
    end
  end
end
