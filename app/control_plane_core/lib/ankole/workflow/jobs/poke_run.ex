defmodule Ankole.Workflow.Jobs.PokeRun do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :conversations,
    max_attempts: 5,
    unique: [keys: [:run_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  def enqueue(run_id) do
    case Oban.insert(new(%{run_id: run_id})) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def run(%Oban.Job{args: %{"run_id" => id}}), do: Ankole.Workflow.RunServer.poke(id)
end
