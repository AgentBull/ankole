defmodule Ankole.Brain.Jobs.LearnSource do
  @moduledoc """
  Oban worker for one Source learning run.

  Uniqueness keeps one run per Source in flight, which serializes revision
  commits; the run's own final transaction re-checks the Source row for
  archive and revision races. Learning runs here instead of the Console
  HTTP request because whole-content extraction of a large source takes
  many model calls.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:source_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  alias Ankole.Brain.SourceLearning

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    case SourceLearning.learn(source_id) do
      {:ok, _report} -> :ok
      # Archived while queued: the run has nothing left to do.
      {:error, :source_archived} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enqueues one learning run for one Source.
  """
  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(source_id) do
    %{"source_id" => source_id}
    |> new()
    |> Oban.insert()
  end
end
