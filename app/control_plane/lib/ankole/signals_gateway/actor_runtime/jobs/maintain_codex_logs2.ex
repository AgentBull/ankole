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
  @response_statuses ~w(deleted database_missing skipped_runtime_active)

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

  # Codex state shards are Worker-local, and the control plane does not track
  # which workers hold one for this Agent, so maintenance reaches every ready
  # worker. A worker without a shard deletes nothing and reports that. Every
  # worker is asked even when an earlier one fails, because stopping at the first
  # failure would leave the shards behind it unmaintained for as long as that one
  # worker stays unreachable. The run reports the failures it collected.
  defp request_maintenance(job_id, agent_uid) do
    request = %FabricProto.CodexLogs2DailyMaintenanceRequest{agent_uid: agent_uid}

    case WorkerPool.ready_worker_routes() do
      [] ->
        {:error, :no_worker_available}

      routes ->
        routes
        |> Enum.reduce(%{workers: 0, deleted_files: [], failures: []}, fn route, acc ->
          case maintain_worker(job_id, agent_uid, route, request) do
            {:ok, deleted_files} ->
              %{
                acc
                | workers: acc.workers + 1,
                  deleted_files: acc.deleted_files ++ deleted_files
              }

            {:error, reason} ->
              %{acc | failures: acc.failures ++ [%{route: route, reason: inspect(reason)}]}
          end
        end)
        |> then(&{:ok, &1})
    end
  end

  defp maintain_worker(job_id, agent_uid, route, request) do
    with {:ok, payload} <-
           Broker.request_rpc(
             route,
             "codex_logs2.daily_maintenance",
             encode(request),
             timeout_ms: @rpc_timeout_ms,
             request_id: "codex-logs2-daily-#{job_id}-#{route}"
           ),
         {:ok, response} <- FabricProto.CodexLogs2DailyMaintenanceResponse.decode(payload),
         :ok <- validate_response_status(response.status) do
      {:ok, response.deleted_files || []}
    else
      {:error, reason} ->
        Logging.warning(
          "signals_gateway.codex_logs2_daily_maintenance_worker_failed",
          "Codex logs daily maintenance could not reach one worker",
          %{agent_uid: agent_uid, route: route, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  defp validate_response_status(status) when status in @response_statuses, do: :ok
  defp validate_response_status(status), do: {:error, {:unexpected_codex_logs2_status, status}}

  defp log_result(agent_uid, boundary_at, {:ok, %{failures: [_first | _rest]} = summary}) do
    Logging.warning(
      "signals_gateway.codex_logs2_daily_maintenance_incomplete",
      "Codex logs daily maintenance completed on some workers only",
      %{
        agent_uid: agent_uid,
        boundary_at: boundary_at,
        workers: summary.workers,
        deleted_files: summary.deleted_files,
        failures: summary.failures
      }
    )
  end

  defp log_result(agent_uid, boundary_at, {:ok, summary}) do
    Logging.info(
      "signals_gateway.codex_logs2_daily_maintenance",
      "Codex logs daily maintenance completed",
      %{
        agent_uid: agent_uid,
        boundary_at: boundary_at,
        workers: summary.workers,
        deleted_files: summary.deleted_files
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
