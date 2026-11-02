defmodule Ankole.Pod.Jobs.CompactSpreadsheet do
  @moduledoc """
  Writes a spreadsheet page's pending operations into its `.xlsx` file.

  `Ankole.Pod.Spreadsheets` keeps one pending wakeup per page: each commit
  moves it to the idle deadline, and a full log or the last editor leaving
  moves it to now.
  """
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"page_id" => id}}), do: Ankole.Pod.Spreadsheets.flush_if_dirty(id)
end
