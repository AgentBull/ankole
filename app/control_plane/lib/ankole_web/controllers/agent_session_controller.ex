defmodule AnkoleWeb.AgentSessionController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for listing an agent's sessions.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SignalsGateway.ActorRuntime.SessionQueries
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSessionListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Sessions"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List sessions for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent sessions", "application/json", AgentSessionListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         :ok <- ConsolePolicy.authorize(conn, sessions_resource(agent_uid), "read") do
      json(conn, %{sessions: SessionQueries.list_agent_sessions(agent_uid)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp text_param(params, key) do
    atom_key = String.to_atom(key)

    value = Map.get(params, key) || Map.get(params, atom_key)

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp sessions_resource(agent_uid), do: "agent:#{agent_uid}:sessions"

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
