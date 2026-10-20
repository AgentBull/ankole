defmodule Ankole.Pod.Applets.Invocation do
  @moduledoc "Owns one native isolate and its cancellable capability processes."

  alias Ankole.Kernel.AppletRuntime
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

    with {:ok, handle, run_id} <- AppletRuntime.start(source, context, limits) do
      try do
        outcome =
          receive_loop(handle, run_id, monitor, context, authority, %{}) |> normalize_error()

        log_outcome(context, started, outcome)

        if context["principal"]["kind"] == "agent",
          do: outcome,
          else: Map.drop(outcome, ["logs", "debug"])
      after
        AppletRuntime.cancel(handle)
      end
    else
      _ -> failed()
    end
  end

  defp normalize_error(%{"status" => status, "body" => %{"error" => error}} = outcome)
       when is_integer(status) and status >= 400 and is_map(error),
       do: put_in(outcome, ["body", "error"], Map.put_new(error, "details", nil))

  defp normalize_error(outcome), do: outcome

  defp receive_loop(handle, run_id, owner_monitor, context, authority, tasks) do
    receive do
      {:applet_runtime, ^run_id, :call, call_id, operation, args_json} ->
        task =
          Task.async(
            Repo.bind_tenant(fn ->
              with {:ok, args} <- Torque.decode(args_json) do
                Capabilities.call(context, authority, operation, args)
              else
                _ -> Capabilities.error(:invalid_request)
              end
            end)
          )

        receive_loop(
          handle,
          run_id,
          owner_monitor,
          context,
          authority,
          Map.put(tasks, task.ref, {task, call_id})
        )

      {ref, result} when is_map_key(tasks, ref) ->
        {task, call_id} = Map.fetch!(tasks, ref)
        Process.demonitor(task.ref, [:flush])
        AppletRuntime.reply(handle, call_id, result)
        receive_loop(handle, run_id, owner_monitor, context, authority, Map.delete(tasks, ref))

      {:DOWN, ^owner_monitor, :process, _pid, _reason} ->
        stop_tasks(tasks)
        AppletRuntime.cancel(handle)
        exit(:normal)

      :cancel ->
        stop_tasks(tasks)
        AppletRuntime.cancel(handle)
        exit(:normal)

      {:EXIT, _pid, _reason} ->
        receive_loop(handle, run_id, owner_monitor, context, authority, tasks)

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(tasks, ref) ->
        {_task, call_id} = Map.fetch!(tasks, ref)
        AppletRuntime.reply(handle, call_id, Capabilities.error(:handler_error))
        receive_loop(handle, run_id, owner_monitor, context, authority, Map.delete(tasks, ref))

      {:applet_runtime, ^run_id, :done, outcome_json} ->
        stop_tasks(tasks)

        case Torque.decode(outcome_json) do
          {:ok, %{"status" => _} = outcome} -> outcome
          _ -> failed()
        end
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
