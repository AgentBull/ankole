defmodule Ankole.Brain.Schemas.MergeSuggestion.PageSummary do
  @moduledoc """
  Calculates the page summary of one slug of a merge suggestion.

  Option `:slug` names the slug attribute. A decided suggestion can name a
  page that no longer exists, so the summary resolves the slug through the
  redirect ladder and keeps only the slug of a missing page.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, opts, _context),
    do: Enum.map(records, &Ankole.Brain.Merge.page_summary(Map.fetch!(&1, opts[:slug])))
end
