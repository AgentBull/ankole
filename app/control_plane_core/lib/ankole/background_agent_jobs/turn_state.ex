defmodule Ankole.BackgroundAgentJobs.TurnState do
  @moduledoc """
  Kinds, statuses, and allowed transitions for a background Agent Job Turn.
  """

  @kinds ~w(agent compaction)
  @statuses ~w(in_progress completed failed interrupted)
  @terminal_statuses ~w(completed failed interrupted)
  @transitions %{
    "in_progress" => @statuses,
    "completed" => ["completed"],
    "failed" => ["failed"],
    "interrupted" => ["interrupted"]
  }

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next) when is_binary(current) and is_binary(next) do
    next in Map.get(@transitions, current, [])
  end
end
