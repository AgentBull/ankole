defmodule BullX.Runtime.SupervisorTest do
  use ExUnit.Case, async: false

  test "omits AIAgent polling workers when disabled" do
    with_ai_agent_runtime_config([ambient_batch_worker: false, daily_reset_worker: false], fn ->
      child_ids = runtime_child_ids()

      refute BullX.AIAgent.AmbientBatchTaskSupervisor in child_ids
      refute BullX.AIAgent.AmbientBatchWorker in child_ids
      refute BullX.AIAgent.DailyResetWorker in child_ids
    end)
  end

  test "includes AIAgent polling workers by default" do
    with_ai_agent_runtime_config(nil, fn ->
      child_ids = runtime_child_ids()

      assert BullX.AIAgent.AmbientBatchTaskSupervisor in child_ids
      assert BullX.AIAgent.AmbientBatchWorker in child_ids
      assert BullX.AIAgent.DailyResetWorker in child_ids
    end)
  end

  defp runtime_child_ids do
    {:ok, {_flags, children}} = BullX.Runtime.Supervisor.init(:ok)

    Enum.map(children, & &1.id)
  end

  defp with_ai_agent_runtime_config(config, fun) do
    previous = Application.get_env(:bullx, :ai_agent_runtime)

    try do
      case config do
        nil -> Application.delete_env(:bullx, :ai_agent_runtime)
        value -> Application.put_env(:bullx, :ai_agent_runtime, value)
      end

      fun.()
    after
      restore_ai_agent_runtime_config(previous)
    end
  end

  defp restore_ai_agent_runtime_config(nil), do: Application.delete_env(:bullx, :ai_agent_runtime)

  defp restore_ai_agent_runtime_config(value),
    do: Application.put_env(:bullx, :ai_agent_runtime, value)
end
