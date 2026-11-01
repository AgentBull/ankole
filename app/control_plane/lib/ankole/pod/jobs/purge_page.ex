defmodule Ankole.Pod.Jobs.PurgePage do
  @moduledoc "Resumes physical Base table deletion before removing its metadata."
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"table_id" => id}}) do
    case Ankole.Pod.Bases.Delete.cleanup(id) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
