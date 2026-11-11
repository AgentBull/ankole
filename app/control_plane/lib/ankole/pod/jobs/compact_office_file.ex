defmodule Ankole.Pod.Jobs.CompactOfficeFile do
  @moduledoc """
  Writes an Office page's pending operations into its stored file.

  `Ankole.Pod.OfficeFiles` keeps one pending wakeup per page: each commit moves
  it to the idle deadline, and a full log, a media-bearing operation, or the
  last editor leaving moves it to now.
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
  def run(%Oban.Job{args: %{"page_id" => id}}), do: Ankole.Pod.OfficeFiles.flush_if_dirty(id)
end
