defmodule Ankole.Brain.Recall.Parallel do
  @moduledoc false

  @default_timeout 30_000

  @type outcome :: %{
          required(:results) => %{required(String.t()) => [term()]},
          required(:degraded_reasons) => [String.t()]
        }

  @spec run([{String.t(), (-> {:ok, [term()]} | {:error, term()})}], keyword()) :: outcome()
  def run(routes, opts \\ []) when is_list(routes) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    tasks =
      Enum.map(routes, fn {name, fun} ->
        {name, Task.Supervisor.async_nolink(Ankole.Brain.TaskSupervisor, fun)}
      end)

    yielded =
      tasks
      |> Enum.map(&elem(&1, 1))
      |> Task.yield_many(timeout)
      |> Map.new(fn {task, result} -> {task.ref, result} end)

    {results, degraded_reasons} =
      Enum.reduce(tasks, {%{}, []}, fn {name, task}, {results, degraded_reasons} ->
        {route_results, route_degraded} =
          route_outcome(name, task, Map.fetch!(yielded, task.ref))

        {
          Map.put(results, name, route_results),
          degraded_reasons ++ route_degraded
        }
      end)

    %{results: results, degraded_reasons: degraded_reasons}
  end

  defp route_outcome(name, task, nil) do
    Task.shutdown(task, :brutal_kill)
    {[], ["#{name} timed out"]}
  end

  defp route_outcome(_name, _task, {:ok, {:ok, results}}) when is_list(results),
    do: {results, []}

  defp route_outcome(name, _task, {:ok, {:error, reason}}),
    do: {[], ["#{name} unavailable: #{inspect(reason)}"]}

  defp route_outcome(name, _task, {:exit, reason}),
    do: {[], ["#{name} exited: #{inspect(reason)}"]}

  defp route_outcome(name, _task, {:ok, invalid}),
    do: {[], ["#{name} returned invalid result: #{inspect(invalid)}"]}
end
