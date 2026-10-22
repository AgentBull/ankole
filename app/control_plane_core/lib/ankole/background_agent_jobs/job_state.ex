defmodule Ankole.BackgroundAgentJobs.JobState do
  @moduledoc """
  Status policy and wait clocks for a BackgroundAgentJob.
  """

  require Ash.Query
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @type status :: :queued | :running | :waiting_on_user | :succeeded | :failed | :stopped

  @type transition_action ::
          :claim_attempt
          | :claim_continuation
          | :worker_report
          | :requeue
          | :external_complete
          | :fail_admission
          | :fail_turn
          | :stop
          | :stop_human_work

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

  @spec transition(transition_action(), status(), status()) ::
          {:ok, status()} | {:error, {:invalid_status_transition, status(), status()}}
  def transition(action, current, next)
      when is_atom(action) and is_atom(current) and is_atom(next) do
    if transition_allowed?(action, current, next) do
      {:ok, next}
    else
      {:error, {:invalid_status_transition, current, next}}
    end
  end

  @spec transition_allowed?(transition_action(), status(), status()) :: boolean()
  def transition_allowed?(action, current, next)
      when is_atom(action) and is_atom(current) and is_atom(next) do
    Ankole.BackgroundAgentJobs.Schemas.Job
    |> AshStateMachine.Info.state_machine_transitions(action)
    |> Enum.any?(&(current in List.wrap(&1.from) and next in List.wrap(&1.to)))
  end

  @doc "Touches a locked Job and returns its current persisted facts."
  def touch_in_tx(%Job{} = job, at), do: update_clock_in_tx(job, :touch, %{at: at})

  @doc "Keeps the first Worker wait clock, including writes from older snapshots."
  def begin_worker_wait_in_tx(%Job{} = job, at),
    do: update_clock_in_tx(job, :begin_worker_wait, %{at: at})

  @doc "Clears a Worker wait once and returns the current persisted Job."
  def clear_worker_wait_in_tx(%Job{} = job, at),
    do: update_clock_in_tx(job, :clear_worker_wait, %{at: at})

  defp update_clock_in_tx(%Job{id: id}, action, attrs) do
    Job
    |> Ash.Query.filter(id == ^id)
    |> Ankole.Ash.bulk_update(action, attrs,
      strategy: [:atomic],
      return_records?: true,
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success, records: [job]} ->
        {:ok, job}

      %Ash.BulkResult{status: :success, records: []} ->
        {:error, Ash.Error.Changes.StaleRecord.exception(resource: Job, filter: %{id: id})}

      %Ash.BulkResult{errors: errors} ->
        {:error, Ash.Error.to_error_class(errors)}
    end
  end
end
