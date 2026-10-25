defmodule Ankole.FunctionRuntime.ProgramRunner do
  @moduledoc "Owns cancellable, deterministic program runs in the function runtime."
  use GenServer
  alias Ankole.FunctionRuntime.HTTP

  @type handle :: reference()
  @options [:timeout_ms, :max_pending_calls, :max_pending_bytes, :max_memo_bytes]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def new_handle(owner \\ self()), do: GenServer.call(__MODULE__, {:new, owner})
  def active_runs, do: GenServer.call(__MODULE__, :active_runs)

  def run(program, tools, memo), do: run(new_handle(), program, tools, memo, [])
  def run(handle, program, tools, memo), do: run(handle, program, tools, memo, [])

  def run(handle, program, tools, memo, options) do
    with {:ok, ^handle} <- start(handle, program, tools, memo, options), do: await(handle)
  end

  def start(handle, program, tools, memo, options \\ []) do
    with {:ok, options} <- validate_options(options) do
      request = Map.merge(%{program: program, tools: tools, memo: memo}, Map.new(options))
      GenServer.call(__MODULE__, {:start, handle, self(), request})
    end
  end

  def await(handle) do
    receive do
      {:program_runner, ^handle, result} -> result
    end
  end

  def cancel(handle), do: GenServer.call(__MODULE__, {:cancel, handle})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:new, owner}, _from, state) do
    handle = make_ref()

    entry = %{
      owner: Process.monitor(owner),
      caller: nil,
      task: nil,
      request_ref: nil,
      cancelled?: false
    }

    {:reply, handle, Map.put(state, handle, entry)}
  end

  def handle_call(:active_runs, _from, state),
    do: {:reply, Enum.count(state, fn {_, entry} -> entry.task != nil end), state}

  def handle_call({:start, handle, caller, request}, _from, state) do
    case state[handle] do
      %{task: nil, cancelled?: true} = entry ->
        Process.demonitor(entry.owner, [:flush])
        send(caller, {:program_runner, handle, {:ok, cancelled_outcome()}})
        {:reply, {:ok, handle}, Map.delete(state, handle)}

      %{task: nil} = entry ->
        observer = {self(), handle}

        task =
          Task.Supervisor.async_nolink(Ankole.FunctionRuntime.Tasks, fn ->
            execute(request, observer)
          end)

        entry = %{entry | task: task, caller: {caller, Process.monitor(caller)}}
        {:reply, {:ok, handle}, Map.put(state, handle, entry)}

      _ ->
        {:reply, {:error, "program handle is cancelled or already started"}, state}
    end
  end

  def handle_call({:cancel, handle}, _from, state) do
    state =
      case state[handle] do
        %{task: nil} = entry -> Map.put(state, handle, %{entry | cancelled?: true})
        _ -> finish(state, handle, {:ok, cancelled_outcome()}, true)
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:function_runtime_request, handle, request_ref}, state) do
    case state[handle] do
      nil ->
        Finch.cancel_async_request(request_ref)
        {:noreply, state}

      entry ->
        {:noreply, Map.put(state, handle, %{entry | request_ref: request_ref})}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state, fn {_, entry} -> entry.task && entry.task.ref == ref end) do
      {handle, _} -> {:noreply, finish(state, handle, result, false)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    handles =
      for {handle, entry} <- state,
          entry.owner == ref or (not is_nil(entry.caller) and elem(entry.caller, 1) == ref) or
            (not is_nil(entry.task) and entry.task.ref == ref),
          do: handle

    {:noreply, Enum.reduce(handles, state, &finish(&2, &1, {:error, "program_cancelled"}, true))}
  end

  defp finish(state, handle, result, stop?) do
    case Map.pop(state, handle) do
      {nil, _} ->
        state

      {entry, state} ->
        Process.demonitor(entry.owner, [:flush])

        if entry.caller do
          {caller, monitor} = entry.caller
          Process.demonitor(monitor, [:flush])
          send(caller, {:program_runner, handle, result})
        end

        if stop? and entry.request_ref, do: Finch.cancel_async_request(entry.request_ref)

        if entry.task do
          Process.demonitor(entry.task.ref, [:flush])
          if stop?, do: Task.shutdown(entry.task, :brutal_kill)
        end

        state
    end
  end

  defp execute(request, observer) do
    timeout = Map.get(request, :timeout_ms, 30_000) + 5_000

    with {:ok, 200, body} <- HTTP.request(:post, "/v1/program/run", request, timeout, observer),
         {:ok, outcome} <- Torque.decode(body) do
      {:ok,
       %{
         status: status(outcome["status"]),
         output: Enum.map(outcome["output"] || [], &%{kind: &1["kind"], value: &1["value"]}),
         pending_calls:
           Enum.map(
             outcome["pending_calls"] || [],
             &%{namespace: &1["namespace"], name: &1["name"], arguments: &1["arguments"]}
           ),
         error: outcome["error"],
         error_code: outcome["error_code"]
       }}
    else
      {:error, :function_runtime_unavailable} ->
        {:ok, failed_outcome("program_runtime_busy", "program runtime concurrency limit reached")}

      {:ok, 503, _} ->
        {:ok, failed_outcome("program_runtime_busy", "program runtime concurrency limit reached")}

      {:error, :function_runtime_timeout} ->
        {:ok, failed_outcome("program_timeout", "program execution timed out")}

      other ->
        {:error, inspect(other)}
    end
  end

  defp cancelled_outcome do
    failed_outcome("program_cancelled", "program_cancelled")
  end

  defp failed_outcome(code, message),
    do: %{status: :failed, output: [], pending_calls: [], error: message, error_code: code}

  defp status("completed"), do: :completed
  defp status("pending"), do: :pending
  defp status(_), do: :failed

  defp validate_options(options) do
    case Keyword.validate(options, @options) do
      {:ok, options} ->
        {:ok, options}

      {:error, unsupported} ->
        {:error,
         "unsupported program run options: #{Enum.map_join(unsupported, ", ", &inspect/1)}"}
    end
  end
end
