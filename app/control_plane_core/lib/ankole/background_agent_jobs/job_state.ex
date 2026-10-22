defmodule Ankole.BackgroundAgentJobs.JobState do
  @moduledoc """
  Status sets and wait clocks for a BackgroundAgentJob.

  The Job state machine is the one transition table. This module gives the
  status sets that read models and capacity checks use.
  """

  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @type status :: :queued | :running | :waiting_on_user | :succeeded | :failed | :stopped

  @terminal_statuses [:succeeded, :failed, :stopped]
  @running_statuses [:running]

  @spec statuses() :: [status()]
  def statuses,
    do: AshStateMachine.Info.state_machine_all_states(Ankole.BackgroundAgentJobs.Schemas.Job)

  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @spec running_statuses() :: [status()]
  def running_statuses, do: @running_statuses

  @spec cast_status(term()) :: {:ok, status()} | :error
  def cast_status(status) when is_atom(status) do
    if status in statuses(), do: {:ok, status}, else: :error
  end

  def cast_status(status) when is_binary(status) do
    statuses() |> Map.new(&{Atom.to_string(&1), &1}) |> Map.fetch(status)
  end

  def cast_status(_status), do: :error

  @doc "Touches a locked Job and returns its current persisted facts."
  def touch_in_tx(%Job{} = job, at), do: Ankole.Ash.update_atomic(job, :touch, %{at: at})

  @doc "Keeps the first Worker wait clock, including writes from older snapshots."
  def begin_worker_wait_in_tx(%Job{} = job, at),
    do: Ankole.Ash.update_atomic(job, :begin_worker_wait, %{at: at})

  @doc "Clears a Worker wait once and returns the current persisted Job."
  def clear_worker_wait_in_tx(%Job{} = job, at),
    do: Ankole.Ash.update_atomic(job, :clear_worker_wait, %{at: at})
end
