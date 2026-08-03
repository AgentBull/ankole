defmodule Ankole.SignalsGateway.ActorRuntime.Jobs.EnqueueDailySessionResets do
  @moduledoc """
  Control-plane cron job that appends due `session.reset_due` actor events.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.Logging
  alias Ankole.Principals
  alias Ankole.SignalsGateway.ActorRuntime.Jobs.MaintainCodexLogs2

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform()
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform do
    case ActorRuntime.enqueue_daily_session_resets() do
      {:ok, result} ->
        enqueue_codex_logs2_maintenance(result)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_codex_logs2_maintenance(%{boundary_at: boundary_at}) do
    boundary_at = DateTime.to_iso8601(boundary_at)

    Principals.list_active_agents()
    |> Enum.map(& &1.agent.uid)
    |> Enum.each(fn agent_uid ->
      %{"agent_uid" => agent_uid, "boundary_at" => boundary_at}
      |> MaintainCodexLogs2.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logging.warning(
            "signals_gateway.codex_logs2_daily_maintenance_enqueue_failed",
            "Codex logs daily maintenance could not be enqueued",
            %{agent_uid: agent_uid, boundary_at: boundary_at, reason: inspect(reason)}
          )
      end
    end)
  end

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status(:ok), do: :ok
  defp result_status({:error, _reason}), do: :error
end
