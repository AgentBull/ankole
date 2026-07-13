defmodule Ankole.Brain.Jobs.EmbedPendingEpisodes do
  @moduledoc """
  Embeds pending Brain episodes through the configured dreaming model agent.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = int_arg(args, "limit", 20)

    case Brain.embed_pending_episodes(limit) do
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
