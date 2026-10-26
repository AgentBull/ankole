defmodule Ankole.AIGateway.ProgramExecution do
  @moduledoc """
  Runs PTC jobs outside the response-stream owner.

  The task returns immutable outcomes only. `ResponseStream` remains the sole
  process that can advance the loop, emit events, or commit durable state.
  Execution handles exist before tasks start. Cancellation, owner exit,
  and task exit stop the function request even when they race with admission.
  """

  alias Ankole.AIGateway.HostedTools.Brain
  alias Ankole.FunctionRuntime.ProgramRunner

  @supervisor Ankole.AIGateway.ProgramTaskSupervisor
  @brain_supervisor Ankole.AIGateway.BrainTaskSupervisor

  @type handle :: %{
          required(:pid) => pid(),
          required(:ref) => reference(),
          required(:monitor) => reference(),
          required(:runtime_handles) => [ProgramRunner.handle()]
        }

  @spec start(pid(), [map()], keyword()) ::
          {:ok, handle()} | {:complete, [map()]} | {:error, term()}
  def start(owner, jobs, opts \\ []) when is_pid(owner) and is_list(jobs) do
    supervisor = Keyword.get(opts, :supervisor, default_supervisor(jobs))
    runner = Keyword.get(opts, :runner)

    cond do
      Enum.all?(jobs, &match?(%{preflight_outcome: %{}}, &1)) ->
        {:complete, run_jobs(jobs)}

      not Process.alive?(owner) ->
        {:error, :program_owner_unavailable}

      is_nil(runner) ->
        jobs = Enum.map(jobs, &prepare_runtime_job(&1, owner))
        handles = for %{runtime_handle: handle} <- jobs, do: handle
        launch(owner, supervisor, handles, fn -> run_jobs(jobs) end)

      is_function(runner, 3) ->
        launch(owner, supervisor, [], fn -> run_jobs(jobs, runner) end)

      true ->
        {:error, :invalid_program_runner}
    end
  end

  defp launch(owner, supervisor, handles, outcomes) do
    ref = make_ref()
    task = fn -> send(owner, {:program_execution, ref, outcomes.()}) end

    start_result =
      try do
        Task.Supervisor.start_child(supervisor, Ankole.Repo.bind_tenant(task),
          restart: :temporary
        )
      catch
        :exit, reason -> {:task_supervisor_exit, reason}
      end

    case start_result do
      {:ok, pid} ->
        {:ok, %{pid: pid, ref: ref, monitor: Process.monitor(pid), runtime_handles: handles}}

      {:error, :max_children} ->
        {:error, :program_runtime_busy}

      {:error, reason} ->
        {:error, {:program_runtime_unavailable, reason}}

      {:task_supervisor_exit, reason} ->
        {:error, {:program_runtime_unavailable, reason}}
    end
  end

  @doc "Cancels one admitted program task without affecting sibling executions."
  @spec cancel(handle() | nil) :: :ok
  def cancel(%{pid: pid, runtime_handles: handles}) when is_pid(pid) do
    Process.exit(pid, :kill)
    Enum.each(handles, &safe_cancel_run/1)
    :ok
  end

  def cancel(_handle), do: :ok

  defp brain_job?(%{kind: :brain}), do: true
  defp brain_job?(_job), do: false

  defp default_supervisor(jobs) do
    if jobs != [] and Enum.all?(jobs, &brain_job?/1), do: @brain_supervisor, else: @supervisor
  end

  defp safe_cancel_run(handle) do
    ProgramRunner.cancel(handle)
  catch
    kind, reason ->
      Ankole.Logging.warning(
        "ai_gateway.program_cancel.failed",
        "Program cancellation failed",
        Ankole.Logging.failure_fields(kind, reason, __STACKTRACE__)
      )

      :error
  end

  defp prepare_runtime_job(%{preflight_outcome: %{}} = job, _owner), do: job
  defp prepare_runtime_job(%{kind: :brain} = job, _owner), do: job

  defp prepare_runtime_job(%{code: _, runtime_bindings: _, memo: _} = job, owner),
    do: Map.put(job, :runtime_handle, ProgramRunner.new_handle(owner))

  defp prepare_runtime_job(job, _owner), do: job

  @doc false
  @spec run_jobs(
          [map()],
          (String.t(), [map()], [map()] -> {:ok, map()} | {:error, term()})
        ) :: [map()]
  def run_jobs(jobs, runner \\ &ProgramRunner.run/3)

  def run_jobs(jobs, runner) when is_list(jobs) and is_function(runner, 3) do
    Enum.map(jobs, fn job ->
      outcome =
        case job do
          %{preflight_outcome: %{} = outcome} ->
            outcome

          %{kind: :brain} = job ->
            Brain.run_job(job)

          %{code: code, runtime_bindings: bindings, memo: memo, runtime_handle: handle} ->
            safe_run(
              fn code, bindings, memo -> ProgramRunner.run(handle, code, bindings, memo) end,
              [code, bindings, memo]
            )

          %{code: code, runtime_bindings: bindings, memo: memo} ->
            safe_run(runner, [code, bindings, memo])

          _invalid ->
            failed("program_job_invalid", "program execution job is invalid")
        end

      %{call_id: Map.get(job, :call_id), outcome: outcome}
    end)
  end

  defp safe_run(runner, arguments) do
    case apply(runner, arguments) do
      {:ok, %{} = outcome} -> normalize_outcome(outcome)
      {:error, reason} -> failed("program_runtime_failed", reason)
      other -> failed("program_runtime_invalid_result", other)
    end
  rescue
    error -> failed("program_runtime_exception", Exception.message(error))
  catch
    kind, reason -> failed("program_runtime_#{kind}", reason)
  end

  defp normalize_outcome(%{status: status} = outcome)
       when status in [:completed, :pending, :failed] do
    %{
      status: status,
      output: list(Map.get(outcome, :output)),
      pending_calls: list(Map.get(outcome, :pending_calls)),
      error: Map.get(outcome, :error),
      error_code: Map.get(outcome, :error_code)
    }
  end

  defp normalize_outcome(outcome),
    do: failed("program_runtime_invalid_outcome", outcome)

  defp failed(code, reason) do
    %{
      status: :failed,
      output: [],
      pending_calls: [],
      error: format_reason(reason),
      error_code: code
    }
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
