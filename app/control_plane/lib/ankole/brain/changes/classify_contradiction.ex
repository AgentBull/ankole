defmodule Ankole.Brain.Changes.ClassifyContradiction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    verdict = Ash.Changeset.get_attribute(changeset, :verdict)
    confidence = Ash.Changeset.get_attribute(changeset, :confidence)

    state =
      if verdict != "no_contradiction" and is_number(confidence) and confidence >= 0.7,
        do: :open,
        else: :dismissed

    Ash.Changeset.force_change_attribute(changeset, :status, state)
  end
end
