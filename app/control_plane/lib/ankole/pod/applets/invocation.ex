defmodule Ankole.Pod.Applets.Invocation do
  @moduledoc "Owns one function invocation and its cancellable capability processes."

  alias Ankole.FunctionRuntime.AppletClient
  alias Ankole.Pod.Applets.Capabilities
  alias Ankole.Repo

  @supervisor Ankole.Pod.AppletTaskSupervisor
  # Calls beyond this many in flight wait in arrival order until a running call finishes.
  @max_concurrent_calls 64

  def start(source, context, limits, authority, opts \\ []) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(
        @supervisor,
        Repo.bind_tenant(fn ->
          run(owner, source, context, limits, authority, opts)
        end)
      )

    {:ok, task}
  end

  def await(task) do
    {_execution, outcome} = await_execution(task)
    {:ok, outcome}
  end

  def await_execution(task) do
    try do
      Task.await(task, :infinity)
    catch
      :exit, _ -> {:aborted, failed()}
    end
  end

  def cancel(task) do
    send(task.pid, :cancel)
    :ok
  end

  defp run(owner, source, context, limits, authority, opts) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)
    started = System.monotonic_time(:millisecond)
    deadline = Keyword.get(limits, :deadline, started + Keyword.get(limits, :timeout_ms, 60_000))

    {:ok, handle, run_id} = AppletClient.start(source, context, limits, deadline, authority)

    host_context =
      case Keyword.get(opts, :authentication_ref) do
        auth_ref when is_binary(auth_ref) and auth_ref != "" ->
          context
          |> Map.put("deadline", deadline)
          |> Map.put("authentication_ref", auth_ref)

        _ ->
          Map.put(context, "deadline", deadline)
      end

    state = %{
      handle: handle,
      run_id: run_id,
      owner_monitor: monitor,
      client_monitor: Process.monitor(handle),
      context: host_context,
      authority: authority,
      tasks: %{},
      waiting: :queue.new(),
      deadline: deadline
    }

    try do
      outcome = receive_loop(state)
      finish_outcome(context, started, outcome)
    after
      AppletClient.cancel(handle)
      Process.demonitor(state.client_monitor, [:flush])
      Process.demonitor(monitor, [:flush])
    end
  end

  defp finish_outcome(context, started, {execution, outcome}) do
    outcome = normalize_error(outcome)
    log_outcome(context, started, outcome)

    outcome =
      if context["principal"]["kind"] == "agent" or is_map(context["run"]),
        do: outcome,
        else: Map.drop(outcome, ["logs", "debug"])

    {execution, outcome}
  end

  defp normalize_error(%{"status" => status, "body" => %{"error" => error}} = outcome)
       when is_integer(status) and status >= 400 and is_map(error),
       do: put_in(outcome, ["body", "error"], Map.put_new(error, "details", nil))

  defp normalize_error(outcome), do: outcome

  defp receive_loop(state) do
    %{
      handle: handle,
      run_id: run_id,
      owner_monitor: owner_monitor,
      client_monitor: client_monitor,
      tasks: tasks
    } = state

    receive do
      {:applet_runtime, ^run_id, :call, call_id, operation, args} ->
        receive_loop(start_call(state, {call_id, operation, args}))

      {ref, result} when is_map_key(tasks, ref) ->
        {task, call_id} = Map.fetch!(tasks, ref)
        Process.demonitor(task.ref, [:flush])
        AppletClient.reply(handle, call_id, result)
        receive_loop(finish_call(state, ref))

      {:DOWN, ^owner_monitor, :process, _, _} ->
        cancel_invocation(state)
        exit(:normal)

      :cancel ->
        cancel_invocation(state)
        exit(:normal)

      {:DOWN, ^client_monitor, :process, _, _} ->
        stop_tasks(tasks)
        {:aborted, failed()}

      {:EXIT, pid, reason} ->
        if Enum.any?(tasks, fn {_, {task, _}} -> task.pid == pid end) or reason == :normal do
          receive_loop(state)
        else
          cancel_invocation(state)
          exit(reason)
        end

      {:DOWN, ref, :process, _, _} when is_map_key(tasks, ref) ->
        {_task, call_id} = Map.fetch!(tasks, ref)
        AppletClient.reply(handle, call_id, Capabilities.error(:handler_error))
        receive_loop(finish_call(state, ref))

      {:applet_runtime, ^run_id, :done, {execution, outcome}} ->
        stop_tasks(tasks)
        {execution, outcome}
    after
      max(0, state.deadline - System.monotonic_time(:millisecond)) ->
        cancel_invocation(state)

        # The client reports before it exits, so a call that expired before `start` stays rejected.
        receive do
          {:applet_runtime, ^run_id, :done, {:rejected, _outcome} = rejected} -> rejected
        after
          0 ->
            {:aborted,
             %{
               "status" => 504,
               "body" => %{
                 "error" => %{
                   "code" => "handler_timeout",
                   "message" => "Applet invocation timed out",
                   "details" => nil
                 }
               },
               "logs" => []
             }}
        end
    end
  end

  defp start_call(state, call) when map_size(state.tasks) >= @max_concurrent_calls,
    do: %{state | waiting: :queue.in(call, state.waiting)}

  defp start_call(state, {call_id, operation, args}) do
    task =
      Task.async(
        Repo.bind_tenant(fn ->
          Capabilities.call(state.context, state.authority, operation, args)
        end)
      )

    %{state | tasks: Map.put(state.tasks, task.ref, {task, call_id})}
  end

  defp finish_call(state, ref) do
    state = %{state | tasks: Map.delete(state.tasks, ref)}

    case :queue.out(state.waiting) do
      {{:value, call}, waiting} -> start_call(%{state | waiting: waiting}, call)
      {:empty, _waiting} -> state
    end
  end

  defp cancel_invocation(state) do
    AppletClient.cancel(state.handle)
    stop_tasks(state.tasks)

    receive do
      {:DOWN, ref, :process, _, _} when ref == state.client_monitor -> :ok
    after
      1_000 ->
        Task.Supervisor.terminate_child(Ankole.FunctionRuntime.Tasks, state.handle)
    end
  end

  defp stop_tasks(tasks),
    do: Enum.each(tasks, fn {_ref, {task, _id}} -> Task.shutdown(task, :brutal_kill) end)

  defp log_outcome(context, started, outcome) do
    metadata = %{
      tenant_id: Repo.tenant_id!(),
      page_id: context["applet"]["pageId"],
      revision: context["applet"]["revision"],
      route: context["actionKey"] || context["method"] <> " " <> context["path"],
      duration_ms: System.monotonic_time(:millisecond) - started,
      status: outcome["status"]
    }

    Ankole.Logging.info("pod.applet.completed", "Applet invocation completed", metadata)

    Enum.each(outcome["logs"] || [], fn log ->
      Ankole.Logging.info(
        "pod.applet.console",
        log["message"] || "",
        Map.put(metadata, :console_level, log["level"])
      )
    end)
  end

  defp failed,
    do: %{
      "status" => 500,
      "body" => %{
        "error" => %{"code" => "handler_error", "message" => "handler_error", "details" => nil}
      },
      "logs" => []
    }
end
