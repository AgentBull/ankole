defmodule Ankole.Signals.Trigger do
  @moduledoc "Delivers a durable trigger to its Session or AutomationJob target."

  @spec deliver_in_tx(map(), map(), DateTime.t(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, {:signal, map()} | {:automation_job_run, map(), map() | nil}}
          | {:error, term()}
  def deliver_in_tx(%{automation_job_id: nil}, _payload, _now, append_signal) do
    with {:ok, signal} <- append_signal.(), do: {:ok, {:signal, signal}}
  end

  def deliver_in_tx(
        %{automation_job_id: id, agent_uid: agent_uid},
        payload,
        now,
        _append_signal
      ) do
    with {:ok, %{automation_job_run: run} = result} <-
           Ankole.AutomationJobs.enqueue_run_in_tx(id, agent_uid, payload, now: now) do
      {:ok, {:automation_job_run, run, Map.get(result, :signal)}}
    end
  end
end
