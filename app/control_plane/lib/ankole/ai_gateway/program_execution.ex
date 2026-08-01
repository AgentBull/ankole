defmodule Ankole.AIGateway.ProgramExecution do
  @moduledoc """
  Runs PTC jobs outside the response-stream owner.

  The task returns immutable outcomes only. `ResponseStream` remains the sole
  process that can advance the loop, emit events, or commit durable state.
  Native cancellation addresses a run after it enters V8. If task or owner
  death races before registration, the native watchdog bounds the lost slot.
  """

  alias Ankole.Kernel.ProgramRunner

  @supervisor Ankole.AIGateway.ProgramTaskSupervisor

  @type handle :: %{
          required(:pid) => pid(),
          required(:ref) => reference(),
          required(:monitor) => reference(),
          required(:run_id) => ProgramRunner.run_id()
        }

  @spec start(pid(), [map()], keyword()) ::
          {:ok, handle()} | {:complete, [map()]} | {:error, term()}
  def start(owner, jobs, opts \\ []) when is_pid(owner) and is_list(jobs) do
    supervisor = Keyword.get(opts, :supervisor, @supervisor)
    runner = Keyword.get(opts, :runner)

    cond do
      Enum.all?(jobs, &match?(%{preflight_outcome: %{}}, &1)) ->
        {:complete, run_jobs(jobs)}

      not Process.alive?(owner) ->
        {:error, :program_owner_unavailable}

      is_nil(runner) ->
        run_id = ProgramRunner.new_run_id()

        launch(owner, supervisor, run_id, fn ->
          run_jobs(jobs, fn code, bindings, memo ->
            ProgramRunner.run(run_id, code, bindings, memo)
          end)
        end)

      is_function(runner, 3) ->
        launch(owner, supervisor, ProgramRunner.new_run_id(), fn -> run_jobs(jobs, runner) end)

      true ->
        {:error, :invalid_program_runner}
    end
  end

  defp launch(owner, supervisor, run_id, outcomes) do
    ref = make_ref()
    task = fn -> send(owner, {:program_execution, ref, outcomes.()}) end

    start_result =
      try do
        Task.Supervisor.start_child(supervisor, task, restart: :temporary)
      catch
        :exit, reason -> {:task_supervisor_exit, reason}
      end

    case start_result do
      {:ok, pid} ->
        {:ok, %{pid: pid, ref: ref, monitor: Process.monitor(pid), run_id: run_id}}

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
  def cancel(%{pid: pid, run_id: run_id}) when is_pid(pid) and is_binary(run_id) do
    # The lookup can miss before the dirty NIF registers itself. Killing the
    # task closes that queueing window; the watchdog bounds the remaining race.
    _ = safe_cancel_run(run_id)
    Process.exit(pid, :kill)
    :ok
  end

  def cancel(_handle), do: :ok

  defp safe_cancel_run(run_id) do
    ProgramRunner.cancel(run_id)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc false
  @spec run_jobs(
          [map()],
          (String.t(), [String.t()], [map()] -> {:ok, map()} | {:error, term()})
        ) :: [map()]
  def run_jobs(jobs, runner \\ &ProgramRunner.run/3)

  def run_jobs(jobs, runner) when is_list(jobs) and is_function(runner, 3) do
    Enum.map(jobs, fn job ->
      outcome =
        case job do
          %{preflight_outcome: %{} = outcome} ->
            outcome

          %{code: code, binding_names: bindings, memo: memo} ->
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
