defmodule Ankole.Brain.Jobs.EnqueueEpisodeSummaries do
  @moduledoc """
  Enqueues per-channel Brain episode summarization jobs.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = int_arg(args, "limit", 50)

    case Brain.enqueue_episode_summary_jobs(limit) do
      {:ok, _count} -> :ok
      {:unavailable, _reason} -> :ok
    end
  end

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end
end
