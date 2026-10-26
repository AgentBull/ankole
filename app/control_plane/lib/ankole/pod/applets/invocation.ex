defmodule Ankole.Pod.Applets.Invocation do
  @moduledoc "Owns one function invocation and its cancellable capability processes."

  alias Ankole.FunctionRuntime.AppletClient
  alias Ankole.Pod.Applets.Capabilities
  alias Ankole.Repo

  @supervisor Ankole.Pod.AppletTaskSupervisor

  def start(source, context, limits, authority) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(
        @supervisor,
        Repo.bind_tenant(fn ->
          run(owner, source, context, limits, authority)
        end)
      )

    {:ok, task}
  end

  def await(task) do
    try do
      {:ok, Task.await(task, :infinity)}
    catch
      :exit, _ -> {:error, :handler_error}
    end
  end

  def cancel(task) do
    send(task.pid, :cancel)
    :ok
  end

  defp run(owner, source, context, limits, authority) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)
    started = System.monotonic_time(:millisecond)
    deadline = started + Keyword.get(limits, :timeout_ms, 60_000)

    {:ok, handle, run_id} = AppletClient.start(source, context, limits, deadline)

    state = %{
      handle: handle,
      run_id: run_id,
      owner_monitor: monitor,
      client_monitor: Process.monitor(handle),
      context: context,
      authority: authority,
      tasks: %{},
      deadline: deadline
    }

    try do
      outcome = state |> receive_loop() |> normalize_error()
      finish_outcome(context, started, outcome)
    after
      AppletClient.cancel(handle)
      Process.demonitor(state.client_monitor, [:flush])
      Process.demonitor(monitor, [:flush])
    end
  end

  defp finish_outcome(context, started, outcome) do
    log_outcome(context, started, outcome)

    if context["principal"]["kind"] == "agent",
      do: outcome,
      else: Map.drop(outcome, ["logs", "debug"])
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
        task =
          Task.async(
            Repo.bind_tenant(fn ->
              Capabilities.call(state.context, state.authority, operation, args)
            end)
          )

        receive_loop(%{
          state
          | tasks: Map.put(tasks, task.ref, {task, call_id})
        })

      {ref, result} when is_map_key(tasks, ref) ->
        {task, call_id} = Map.fetch!(tasks, ref)
        Process.demonitor(task.ref, [:flush])
        AppletClient.reply(handle, call_id, result)
        receive_loop(%{state | tasks: Map.delete(tasks, ref)})

      {:DOWN, ^owner_monitor, :process, _, _} ->
        cancel_invocation(state)
        exit(:normal)

      :cancel ->
        cancel_invocation(state)
        exit(:normal)

      {:DOWN, ^client_monitor, :process, _, _} ->
        stop_tasks(tasks)
        failed()

      {:EXIT, _, _} ->
        receive_loop(state)

      {:DOWN, ref, :process, _, _} when is_map_key(tasks, ref) ->
        {_task, call_id} = Map.fetch!(tasks, ref)
        AppletClient.reply(handle, call_id, Capabilities.error(:handler_error))
        receive_loop(%{state | tasks: Map.delete(tasks, ref)})

      {:applet_runtime, ^run_id, :done, outcome} ->
        stop_tasks(tasks)

        case outcome do
          %{"status" => _} -> outcome
          _ -> failed()
        end
    after
      max(0, state.deadline - System.monotonic_time(:millisecond)) ->
        cancel_invocation(state)

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
        }
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
      route: context["method"] <> " " <> context["path"],
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
