defmodule AnkoleWeb.ConsoleReadinessController do
  @moduledoc """
  Console REST API for the installation readiness snapshot.
  """

  alias OpenApiSpex, as: OpenAPISpex

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.ConsoleReadiness
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Console"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:show,
    summary: "Read the console readiness snapshot",
    responses: [
      ok: {"Console readiness", "application/json", ConsoleReadinessResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  def show(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "console_readiness", "read") do
      json(conn, ConsoleReadiness.snapshot())
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")
end
