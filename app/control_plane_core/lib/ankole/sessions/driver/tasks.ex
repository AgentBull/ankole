defmodule Ankole.Sessions.Driver.Tasks do
  @moduledoc "Starts, deduplicates and cancels disposable Session Driver tasks."
  alias Ankole.AIGateway
  alias Ankole.Sessions.{WorkerAcquisition, Worker, PendingCall}

  def task(data, kind, fun) do
    if (kind in [:worker_resolve, :worker_check, :worker_open] or match?({:worker_send, _}, kind)) and
         Enum.any?(data.tasks, fn {_ref, {active, _pid}} -> active == kind end) do
      data
    else
      task =
        Task.Supervisor.async_nolink(Ankole.Sessions.Tasks, Ankole.Repo.bind_tenant(fun))

      %{data | tasks: Map.put(data.tasks, task.ref, {kind, task.pid})}
    end
  end

  def clear_tasks(data),
    do: %{
      clear_tasks(data, fn _kind -> true end)
      | stream: nil,
        early_stream: []
    }

  def clear_tasks(data, discard?) do
    tasks =
      Enum.reduce(data.tasks, %{}, fn {ref, {kind, pid} = task}, retained ->
        if discard?.(kind) do
          Task.Supervisor.terminate_child(Ankole.Sessions.Tasks, pid)
          Process.demonitor(ref, [:flush])
          retained
        else
          Map.put(retained, ref, task)
        end
      end)

    %{data | tasks: tasks}
  end

  def cancel_current(data) do
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "conversation_interrupted")

    case WorkerAcquisition.row(data.turn.acquisition) do
      row when is_map(row) ->
        ids = PendingCall.on_worker(data.turn.pending)

        Task.Supervisor.start_child(
          Ankole.Sessions.Tasks,
          Ankole.Repo.bind_tenant(fn ->
            Worker.cancel(data.turn.run, row, ids)
          end)
        )

      _ ->
        :ok
    end

    Ankole.Sessions.Driver.Tasks.clear_tasks(data)
  end
end
