defmodule AnkoleWeb.AgentComputerWorkerController do
  @moduledoc """
  Console REST API for the agent computer worker registry.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.SignalsGateway
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.AgentComputerWorkerListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope

  tags(["Workers"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  operation(:index,
    summary: "List agent computer workers",
    responses: [
      ok: {"Workers", "application/json", AgentComputerWorkerListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agent_computer_workers", "read") do
      json(conn, %{data: Enum.map(SignalsGateway.list_workers(), &worker_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp worker_json(worker) do
    %{
      worker_id: worker.worker_id,
      status: worker.status,
      version: worker.version,
      capacity: worker.capacity || %{},
      load: worker.load || %{},
      last_worker_heartbeat_at: iso8601(worker.last_worker_heartbeat_at),
      started_at: iso8601(worker.started_at),
      stopped_at: iso8601(worker.stopped_at),
      stop_reason: worker.stop_reason,
      inserted_at: DateTime.to_iso8601(worker.inserted_at),
      updated_at: DateTime.to_iso8601(worker.updated_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
