defmodule Ankole.BackgroundAgentJobs.JobState do
  @moduledoc """
  Status values and allowed transitions for a BackgroundAgentJob.
  """

  @statuses ~w(queued running waiting_on_user succeeded failed stopped)
  @terminal_statuses ~w(succeeded failed stopped)
  @running_statuses ~w(running)
  @transitions %{
    "queued" => ~w(queued running succeeded failed stopped),
    "running" => ~w(running waiting_on_user succeeded failed stopped),
    "waiting_on_user" => ~w(waiting_on_user running succeeded failed stopped),
    "succeeded" => ~w(succeeded),
    "failed" => ~w(failed),
    "stopped" => ~w(stopped)
  }

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec running_statuses() :: [String.t()]
  def running_statuses, do: @running_statuses

  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next) when is_binary(current) and is_binary(next) do
    next in Map.get(@transitions, current, [])
  end
end
