defmodule Ankole.Brain.Jobs.EmbedPendingBlocks do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit =
      case Map.get(args, "limit") do
        value when is_integer(value) and value > 0 -> value
        _value -> 50
      end

    case Brain.embed_pending_blocks(limit) do
      {:ok, _count} -> :ok
      {:unavailable, _reason} -> :ok
    end
  end
end
