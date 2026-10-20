defmodule AnkoleWeb.AgentWorkerController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the Worker of each Agent: its lifecycle state, its
  connection facts, and the latest reason that the backend gave.
  """

  use AnkoleWeb, :controller

  action_fallback AnkoleWeb.ConsoleErrors
  use OpenAPISpex.ControllerSpecs

  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentComputerWorkerListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Workers"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List the Worker of each Agent",
    responses: [
      ok: {"Workers", "application/json", AgentComputerWorkerListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agent_workers", "read") do
      json(conn, %{workers: Enum.map(Ankole.AgentWorkers.list(), &worker_json/1)})
    end
  end

  defp worker_json(worker) do
    %{
      agent_uid: worker.agent_uid,
      provider_id: worker.provider_id,
      state: worker.state,
      generation: worker.generation,
      image: worker.image,
      capacity: worker.capacity || %{},
      load: worker.load || %{},
      last_worker_heartbeat_at: iso8601(worker.last_worker_heartbeat_at),
      state_changed_at: iso8601(worker.state_changed_at),
      drain_reason: worker.drain_reason,
      last_error: worker.last_error
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
