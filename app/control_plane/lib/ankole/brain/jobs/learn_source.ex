defmodule Ankole.Brain.Jobs.LearnSource do
  @moduledoc """
  Oban worker for one Source learning run.

  Uniqueness keeps one run per Source in flight, which serializes revision
  commits; each material commit checks the Source archive state and its
  previous revision under lock. A page run is unique per content version, so
  a file replaced while its previous version is still learning gets its own run. Learning runs here instead of the Console
  HTTP request because whole-content extraction of a large source takes
  many model calls.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:source_id, :page_id, :content_version],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  alias Ankole.Brain.SourceLearning

  @impl Ankole.Job
  def run(job) do
    if Ankole.Tenants.accepting_work?(Ankole.Repo.tenant_id!()), do: run_active(job), else: :ok
  end

  # A job enqueued before content versions names the page revision, which is
  # the content version of every page such a job can name.
  defp run_active(%Oban.Job{args: %{"page_id" => page_id} = args}) do
    case SourceLearning.learn_page(page_id, args["content_version"] || args["revision"]) do
      {:ok, _} -> :ok
      {:error, :stale_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_active(%Oban.Job{args: %{"source_id" => source_id}}) do
    case SourceLearning.learn(source_id) do
      {:ok, _report} -> :ok
      # Archived while queued: the run has nothing left to do.
      {:error, :source_archived} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_page(page_id, content_version) do
    %{"page_id" => page_id, "content_version" => content_version} |> new() |> Oban.insert()
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
