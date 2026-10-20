defmodule AnkoleWeb.ConsoleReadinessController do
  @moduledoc """
  Console REST API for the installation readiness snapshot.
  """

  alias OpenApiSpex, as: OpenAPISpex

  use AnkoleWeb, :controller

  action_fallback AnkoleWeb.ConsoleErrors
  use OpenAPISpex.ControllerSpecs

  alias Ankole.ConsoleReadiness
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Console"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:show,
    summary: "Read the console readiness snapshot",
    responses: [
      ok: {"Console readiness", "application/json", ConsoleReadinessResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def show(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "console_readiness", "read") do
      json(conn, ConsoleReadiness.snapshot())
    end
  end
end
