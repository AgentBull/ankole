defmodule Ankole.SignalsGateway.ActorRuntime.Jobs.MaintainCodexLogs2 do
  @moduledoc """
  Best-effort daily maintenance for the Codex diagnostic log database.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      fields: [:worker, :args],
      keys: [:agent_uid, :boundary_at],
      period: 172_800
    ]

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool

  @rpc_timeout_ms 10_000
  @response_statuses ~w(deleted database_missing skipped_codex_running skipped_setup_busy)

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{
        id: job_id,
        args: %{"agent_uid" => agent_uid, "boundary_at" => boundary_at}
      })
      when is_binary(agent_uid) and agent_uid != "" and is_binary(boundary_at) and
             boundary_at != "" do
    result = request_maintenance(job_id, agent_uid)
    log_result(agent_uid, boundary_at, result)
    :ok
  end

  def perform(%Oban.Job{} = job) do
    Logging.warning(
      "signals_gateway.codex_logs2_daily_maintenance_invalid",
      "Codex logs daily maintenance has invalid arguments",
      %{job_id: job.id}
    )

    :ok
  end

  defp request_maintenance(job_id, agent_uid) do
    request = %FabricProto.CodexLogs2DailyMaintenanceRequest{agent_uid: agent_uid}

    WorkerPool.with_agent_file_worker_route(agent_uid, fn route ->
      with {:ok, payload} <-
             Broker.request_rpc(
               route,
               "codex_logs2.daily_maintenance",
               encode(request),
               timeout_ms: @rpc_timeout_ms,
               request_id: "codex-logs2-daily-#{job_id}"
             ),
           {:ok, response} <- FabricProto.CodexLogs2DailyMaintenanceResponse.decode(payload),
           :ok <- validate_response_status(response.status) do
        {:ok, response}
      end
    end)
  end

  defp validate_response_status(status) when status in @response_statuses, do: :ok
  defp validate_response_status(status), do: {:error, {:unexpected_codex_logs2_status, status}}

  defp log_result(agent_uid, boundary_at, {:ok, response}) do
    Logging.info(
      "signals_gateway.codex_logs2_daily_maintenance",
      "Codex logs daily maintenance completed",
      %{
        agent_uid: agent_uid,
        boundary_at: boundary_at,
        status: response.status,
        deleted_files: response.deleted_files,
        active_codex_processes: response.active_codex_processes
      }
    )
  end

  defp log_result(agent_uid, boundary_at, {:error, reason}) do
    Logging.warning(
      "signals_gateway.codex_logs2_daily_maintenance_failed",
      "Codex logs daily maintenance could not run",
      %{agent_uid: agent_uid, boundary_at: boundary_at, reason: inspect(reason)}
    )
  end

  defp encode(struct) do
    {iodata, _size} = struct.__struct__.encode!(struct)
    IO.iodata_to_binary(iodata)
  end
end
