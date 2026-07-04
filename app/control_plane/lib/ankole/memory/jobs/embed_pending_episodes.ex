defmodule Ankole.Memory.Jobs.EmbedPendingEpisodes do
  @moduledoc """
  Embeds pending Memory episodes through the configured recall model agent.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = int_arg(args, "limit", 20)

    case Memory.embed_pending_episodes(limit) do
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
