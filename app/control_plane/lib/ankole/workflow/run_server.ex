defmodule Ankole.Workflow.RunServer do
  @moduledoc false

  use GenServer, restart: :temporary

  import Ecto.Query

  alias Ankole.Kernel.ProgramRunner
  alias Ankole.Repo
  alias Ankole.Workflow
  alias Ankole.Workflow.Program
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @max_pending_calls 1_024
  @max_pending_bytes 8 * 1_024 * 1_024
  @max_memo_bytes 8 * 1_024 * 1_024
  @runtime_busy_retry_ms :timer.seconds(30)
  @watchdog_interval_ms :timer.hours(1)
  @stale_after_seconds 3_600
  @tool_bindings [%{"namespace" => nil, "name" => "agent", "global_name" => "agent"}]

  @type state :: %{
          run_id: pos_integer(),
          runner: module() | function(),
          task_supervisor: GenServer.server(),
          replay: map() | nil,
          dirty: boolean(),
          cancelling: boolean(),
          retry_timer: {reference(), reference()} | nil,
          watchdog_timer: reference() | nil,
          runtime_busy_retry_ms: pos_integer(),
          watchdog_interval_ms: pos_integer(),
          stale_after_seconds: pos_integer()
        }

  @spec child_spec(pos_integer() | keyword()) :: Supervisor.child_spec()
  def child_spec(run_id) when is_integer(run_id), do: child_spec(run_id: run_id)

  def child_spec(opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(pos_integer() | keyword()) :: GenServer.on_start()
  def start_link(run_id) when is_integer(run_id), do: start_link(run_id: run_id)

  def start_link(opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = Keyword.get(opts, :name, via(run_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ensure_started(pos_integer(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(run_id, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_list(opts) do
    case ensure_started_with_status(run_id, opts) do
      {:ok, pid, _status} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_started_with_status(run_id, opts) do
    child_opts = Keyword.put(opts, :run_id, run_id)

    case DynamicSupervisor.start_child(
           Ankole.Workflow.RunSupervisor,
           {__MODULE__, child_opts}
         ) do
      {:ok, pid} -> {:ok, pid, :started}
      {:error, {:already_started, pid}} -> {:ok, pid, :existing}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:workflow_supervisor_unavailable, reason}}
  end

  @spec poke(pos_integer(), keyword()) :: :ok | {:error, term()}
  def poke(run_id, opts \\ []) do
    with {:ok, pid} <- ensure_started(run_id, opts) do
      GenServer.cast(pid, :poke)
    end
  end

  @spec cancel(pos_integer(), String.t(), keyword()) ::
          {:ok, %{run: struct(), running_session_ids: [String.t()]}} | {:error, term()}
  def cancel(run_id, agent_uid, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(agent_uid) and is_list(opts) do
    cancel_with_retry(run_id, agent_uid, opts, 1)
  end

  defp cancel_with_retry(run_id, agent_uid, opts, retries_left) do
    with {:ok, pid} <- ensure_started(run_id, opts) do
      case call_cancel(pid, agent_uid) do
        {:call_exit, _reason} when retries_left > 0 ->
          cancel_with_retry(run_id, agent_uid, opts, retries_left - 1)

        {:call_exit, _reason} ->
          cancel_without_server(run_id, agent_uid, opts)

        result ->
          result
      end
    end
  end

  defp call_cancel(pid, agent_uid) do
    GenServer.call(
      pid,
      {:cancel, agent_uid},
      :timer.seconds(30)
    )
  catch
    :exit, reason -> {:call_exit, reason}
  end

  defp cancel_without_server(run_id, agent_uid, opts) do
    case Workflow.cancel_in_storage(run_id, agent_uid) do
      {:ok, result} ->
        runner = Keyword.get(opts, :runner, ProgramRunner)
        _ = safe_cancel_runner(runner, program_run_id(run_id))
        Workflow.cleanup_terminal_transition({:ok, result})

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec whereis(pos_integer()) :: pid() | nil
  def whereis(run_id) do
    case Registry.lookup(Ankole.Workflow.Registry, run_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       run_id: Keyword.fetch!(opts, :run_id),
       runner: Keyword.get(opts, :runner, ProgramRunner),
       task_supervisor: Keyword.get(opts, :task_supervisor, Ankole.Workflow.ReplayTaskSupervisor),
       replay: nil,
       dirty: false,
       cancelling: false,
       retry_timer: nil,
       watchdog_timer: nil,
       runtime_busy_retry_ms:
         positive_option(opts, :runtime_busy_retry_ms, @runtime_busy_retry_ms),
       watchdog_interval_ms: positive_option(opts, :watchdog_interval_ms, @watchdog_interval_ms),
       stale_after_seconds: positive_option(opts, :stale_after_seconds, @stale_after_seconds)
     }}
  end

  @impl true
  def handle_cast(:poke, %{cancelling: true} = state), do: {:noreply, state}

  def handle_cast(:poke, %{replay: %{}} = state) do
    {:noreply, %{state | dirty: true}}
  end

  def handle_cast(:poke, state) do
    state = cancel_retry_timer(state)
    start_replay(state)
  end

  @impl true
  def handle_call({:cancel, agent_uid}, _from, state) do
    state = %{state | cancelling: true}

    case Workflow.cancel_in_storage(state.run_id, agent_uid) do
      {:ok, result} ->
        state = cancel_in_flight_replay(state)
        {:ok, result} = Workflow.cleanup_terminal_transition({:ok, result})

        case result.run.cleanup_completed_at do
          %DateTime{} ->
            {:stop, :normal, {:ok, result}, state}

          nil ->
            {:noreply, state} =
              schedule_retry(%{state | cancelling: false}, :terminal_cleanup_pending)

            {:reply, {:ok, result}, state}
        end

      {:error, :workflow_not_found} = error ->
        handle_hidden_cancel_miss(error, state)

      {:error, reason} ->
        state = %{state | cancelling: false}

        if is_nil(state.replay),
          do: {:stop, :normal, {:error, reason}, state},
          else: {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:workflow_replay_finished, ref, _result},
        %{replay: %{ref: ref}, dirty: true} = state
      ) do
    state = clear_replay(state)
    start_replay(%{state | dirty: false})
  end

  def handle_info({:workflow_replay_finished, ref, result}, %{replay: %{ref: ref}} = state) do
    state = clear_replay(state)
    handle_replay_result(result, state)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{replay: %{monitor: monitor}} = state
      ) do
    state = clear_replay(state, demonitor?: false)

    if state.cancelling do
      {:noreply, state}
    else
      schedule_retry(state, {:replay_task_down, reason})
    end
  end

  def handle_info(
        {:workflow_retry_replay, ref},
        %{retry_timer: {ref, _timer_ref}} = state
      ) do
    start_replay(%{state | retry_timer: nil})
  end

  def handle_info(
        {:workflow_watchdog, ref},
        %{watchdog_timer: ref, replay: %{}} = state
      ) do
    state = state |> Map.put(:watchdog_timer, nil) |> schedule_watchdog()
    {:noreply, state}
  end

  def handle_info({:workflow_watchdog, ref}, %{watchdog_timer: ref} = state) do
    state = %{state | watchdog_timer: nil}
    now = DateTime.utc_now(:microsecond)
    cutoff = DateTime.add(now, -state.stale_after_seconds, :second)

    case Workflow.reconcile_stale_tasks(state.run_id, cutoff, now)
         |> Workflow.cleanup_terminal_transition() do
      {:ok, %{run: %Run{status: "running"}, reconciled: reconciled}} ->
        state = schedule_watchdog(state)

        if reconciled > 0 do
          start_replay_or_dirty(state)
        else
          {:noreply, state}
        end

      {:ok, %{run: %Run{}} = result} ->
        finish_or_retry_terminal(result, state)

      {:error, :workflow_not_found} ->
        {:stop, :normal, state}

      {:error, reason} ->
        schedule_retry(state, {:watchdog_failed, reason})
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_in_flight_replay(state)
    :ok
  end

  defp start_replay(%{cancelling: true} = state), do: {:noreply, state}
  defp start_replay(%{replay: %{}} = state), do: {:noreply, %{state | dirty: true}}

  defp start_replay(state) do
    owner = self()
    ref = make_ref()
    run_id = state.run_id
    runner = state.runner

    task = fn ->
      result = replay_once(run_id, runner)
      send(owner, {:workflow_replay_finished, ref, result})
    end

    result =
      try do
        Task.Supervisor.start_child(state.task_supervisor, task, restart: :temporary)
      catch
        :exit, reason -> {:error, {:task_supervisor_exit, reason}}
      end

    case result do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        {:noreply, %{state | replay: %{ref: ref, pid: pid, monitor: monitor}, dirty: false}}

      {:error, :max_children} ->
        schedule_retry(state, :program_runtime_busy)

      {:error, reason} ->
        schedule_retry(state, {:program_runtime_unavailable, reason})
    end
  end

  defp replay_once(run_id, runner) do
    case load_replay_input(run_id) do
      {:ok, %{program: program, memo: memo, memo_length: memo_length}} ->
        outcome =
          run_id
          |> program_run_id()
          |> invoke_runner(runner, program, memo)

        {:snapshot, memo_length, outcome}

      {:terminal, status} ->
        {:terminal, status}

      {:cleanup_pending, %Run{} = run} ->
        case Workflow.cleanup_terminal_run(run) do
          {:ok, %Run{status: status}} -> {:terminal, status}
          {:error, reason} -> {:cleanup_failed, reason}
        end

      {:error, reason} ->
        {:unavailable, reason}
    end
  end

  defp load_replay_input(run_id) do
    Repo.transact(fn repo ->
      case repo.get(Run, run_id) do
        %Run{status: "running"} = run ->
          calls =
            AgentCall
            |> where([call], call.run_id == ^run.id)
            |> order_by([call], asc: call.call_seq)
            |> repo.all()

          with {:ok, program} <- Program.source(run) do
            {memo, memo_length} = Program.memo_prefix(calls)
            {:ok, %{program: program, memo: memo, memo_length: memo_length}}
          end

        %Run{cleanup_completed_at: nil} = run ->
          {:ok, {:cleanup_pending, run}}

        %Run{status: status} ->
          {:ok, {:terminal, status}}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
    |> case do
      {:ok, {:terminal, status}} -> {:terminal, status}
      {:ok, {:cleanup_pending, run}} -> {:cleanup_pending, run}
      result -> result
    end
  end

  defp invoke_runner(run_id, runner, program, memo) do
    options = [
      max_pending_calls: @max_pending_calls,
      max_pending_bytes: @max_pending_bytes,
      max_memo_bytes: @max_memo_bytes
    ]

    result =
      cond do
        is_atom(runner) ->
          apply(runner, :run, [run_id, program, @tool_bindings, memo, options])

        is_function(runner, 5) ->
          runner.(run_id, program, @tool_bindings, memo, options)

        true ->
          {:error, :invalid_workflow_program_runner}
      end

    case result do
      {:ok, %{status: status} = outcome} when status in [:pending, :completed, :failed] ->
        {:outcome, outcome}

      {:error, reason} ->
        failed_outcome("program_execution_failed", reason)

      other ->
        failed_outcome("program_execution_failed", {:invalid_runner_result, other})
    end
  rescue
    exception -> failed_outcome("program_execution_failed", Exception.message(exception))
  catch
    kind, reason -> failed_outcome("program_execution_failed", "#{kind}: #{inspect(reason)}")
  end

  defp failed_outcome(code, reason) do
    {:outcome,
     %{
       status: :failed,
       output: [],
       pending_calls: [],
       error: format_reason(reason),
       error_code: code
     }}
  end

  defp handle_replay_result({:terminal, _status}, state), do: {:stop, :normal, state}

  defp handle_replay_result({:cleanup_failed, reason}, state) do
    schedule_retry(state, {:terminal_cleanup_failed, reason})
  end

  defp handle_replay_result({:unavailable, reason}, state) do
    if reason == :workflow_not_found,
      do: {:stop, :normal, state},
      else: schedule_retry(state, {:replay_input_unavailable, reason})
  end

  defp handle_replay_result({:snapshot, memo_length, result}, state) do
    handle_snapshot_result(result, memo_length, state)
  end

  defp handle_replay_result(other, state) do
    schedule_retry(state, {:invalid_replay_result, other})
  end

  defp handle_snapshot_result({:outcome, %{status: :pending} = outcome}, memo_length, state) do
    case Workflow.commit_replay_pending(
           state.run_id,
           Map.get(outcome, :pending_calls, []),
           memo_length
         )
         |> Workflow.cleanup_terminal_transition() do
      {:ok, %{run: %Run{status: "running"}}} -> continue_or_wait(state)
      {:ok, %{run: %Run{}} = result} -> finish_or_retry_terminal(result, state)
      {:error, :workflow_replay_snapshot_changed} -> restart_stale_snapshot(state)
      {:error, reason} -> schedule_retry(state, {:pending_commit_failed, reason})
    end
  end

  defp handle_snapshot_result(
         {:outcome, %{status: :completed} = outcome},
         memo_length,
         state
       ) do
    case output_text(Map.get(outcome, :output, [])) do
      {:ok, result_text} ->
        case Workflow.complete_replay(state.run_id, result_text, memo_length)
             |> Workflow.cleanup_terminal_transition() do
          {:ok, %{run: %Run{status: "running"}}} ->
            continue_or_wait(state)

          {:ok, %{run: %Run{}} = result} ->
            finish_or_retry_terminal(result, state)

          {:error, :workflow_replay_snapshot_changed} ->
            restart_stale_snapshot(state)

          {:error, reason} ->
            fail_or_retry(state, "program_execution_failed", reason, memo_length)
        end

      {:error, reason} ->
        fail_or_retry(state, "program_execution_failed", reason, memo_length)
    end
  end

  defp handle_snapshot_result(
         {:outcome, %{status: :failed, error_code: error_code}},
         _memo_length,
         state
       )
       when error_code in ["program_runtime_busy", "program_run_id_conflict"] do
    schedule_retry(state, :program_runtime_busy)
  end

  defp handle_snapshot_result({:outcome, %{status: :failed} = outcome}, memo_length, state) do
    code = present_text(Map.get(outcome, :error_code)) || "program_execution_failed"
    summary = present_text(Map.get(outcome, :error)) || "Workflow program execution failed."
    fail_or_retry(state, code, summary, memo_length)
  end

  defp handle_snapshot_result(other, memo_length, state) do
    fail_or_retry(
      state,
      "program_execution_failed",
      {:invalid_replay_result, other},
      memo_length
    )
  end

  defp fail_or_retry(state, code, reason, memo_length) do
    case Workflow.fail_replay(state.run_id, code, format_reason(reason), memo_length)
         |> Workflow.cleanup_terminal_transition() do
      {:ok, %{run: %Run{status: "running"}}} -> continue_or_wait(state)
      {:ok, %{run: %Run{}} = result} -> finish_or_retry_terminal(result, state)
      {:error, :workflow_replay_snapshot_changed} -> restart_stale_snapshot(state)
      {:error, error} -> schedule_retry(state, {:failure_commit_failed, error})
    end
  end

  defp restart_stale_snapshot(state), do: start_replay(%{state | dirty: false})

  defp continue_or_wait(%{dirty: true} = state) do
    start_replay(%{state | dirty: false})
  end

  defp continue_or_wait(state), do: {:noreply, schedule_watchdog(state)}

  defp finish_or_retry_terminal(
         %{run: %Run{cleanup_completed_at: %DateTime{}}},
         state
       ),
       do: {:stop, :normal, state}

  defp finish_or_retry_terminal(%{run: %Run{}}, state),
    do: schedule_retry(state, :terminal_cleanup_pending)

  defp start_replay_or_dirty(%{replay: %{}} = state), do: {:noreply, %{state | dirty: true}}
  defp start_replay_or_dirty(state), do: start_replay(state)

  defp schedule_retry(state, _reason) do
    state = cancel_retry_timer(state)
    ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:workflow_retry_replay, ref}, state.runtime_busy_retry_ms)

    {:noreply, %{state | retry_timer: {ref, timer_ref}, dirty: false}}
  end

  defp schedule_watchdog(%{watchdog_timer: ref} = state) when is_reference(ref), do: state

  defp schedule_watchdog(state) do
    ref = make_ref()
    Process.send_after(self(), {:workflow_watchdog, ref}, state.watchdog_interval_ms)
    %{state | watchdog_timer: ref}
  end

  defp cancel_retry_timer(%{retry_timer: nil} = state), do: state

  defp cancel_retry_timer(%{retry_timer: {_ref, timer_ref}} = state) do
    Process.cancel_timer(timer_ref)
    %{state | retry_timer: nil}
  end

  defp clear_replay(state, opts \\ []) do
    if Keyword.get(opts, :demonitor?, true) do
      Process.demonitor(state.replay.monitor, [:flush])
    end

    %{state | replay: nil}
  end

  defp cancel_in_flight_replay(state) do
    _ = safe_cancel_runner(state.runner, program_run_id(state.run_id))

    case state.replay do
      %{pid: pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        %{state | replay: nil}

      nil ->
        state
    end
  end

  defp handle_hidden_cancel_miss(error, state) do
    state = %{state | cancelling: false}

    case durable_run_status(state.run_id) do
      {:ok, "running"} ->
        if is_nil(state.replay), do: GenServer.cast(self(), :poke)
        {:reply, error, state}

      {:ok, _terminal_status} ->
        {:stop, :normal, error, state}

      :missing ->
        {:stop, :normal, error, state}

      {:error, _reason} ->
        if is_nil(state.replay),
          do: {:stop, :normal, error, state},
          else: {:reply, error, state}
    end
  end

  defp durable_run_status(run_id) do
    case Repo.get(Run, run_id) do
      %Run{status: status} -> {:ok, status}
      nil -> :missing
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_cancel_runner(runner, run_id) when is_atom(runner) do
    if function_exported?(runner, :cancel, 1), do: apply(runner, :cancel, [run_id]), else: :ok
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_cancel_runner(_runner, _run_id), do: :ok

  defp output_text(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      %{kind: "text", value: value}, {:ok, output} when is_binary(value) ->
        {:cont, {:ok, [value | output]}}

      part, {:ok, _output} ->
        {:halt, {:error, {:invalid_program_output_part, part}}}
    end)
    |> case do
      {:ok, output} -> {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} = error -> error
    end
  end

  defp output_text(_parts), do: {:error, :invalid_program_output}

  defp program_run_id(run_id), do: "wf-" <> Integer.to_string(run_id)

  defp via(run_id), do: {:via, Registry, {Ankole.Workflow.Registry, run_id}}

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp present_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present_text(_value), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 20)
end
