defmodule AnkoleWeb.ControlPlanePluginController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for next-start Control Plane Plugin configuration.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.ControlPlanePlugins
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  @responses [
    ok: {"Control Plane Plugins", "application/json", ControlPlanePluginListResponse},
    default: {"Error", "application/json", ErrorEnvelope}
  ]

  tags(["Control Plane Plugins"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List active and next-start Control Plane Plugin state",
    responses: @responses
  )

  operation(:update,
    summary: "Configure one Control Plane Plugin for the next process start",
    request_body:
      {"Control Plane Plugin configuration", "application/json", ControlPlanePluginWriteRequest,
       required: true},
    responses: @responses
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "control_plane_plugins", "read"),
         {:ok, plugins} <- ControlPlanePlugins.list() do
      json(conn, %{control_plane_plugins: plugins})
    end
  end

  def update(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "control_plane_plugins", "update"),
         {:ok, id, enabled} <- body(conn.body_params),
         {:ok, plugins} <- ControlPlanePlugins.configure(id, enabled) do
      json(conn, %{control_plane_plugins: plugins})
    end
  end

  defp body(%{id: id, enabled: enabled}) when id != "", do: {:ok, id, enabled}
  defp body(_params), do: {:error, :invalid_control_plane_plugin_configuration}

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :control_plane_plugin_not_found) do
    ConsoleErrors.not_found(conn, "Control Plane Plugin was not found")
  end

  defp error(conn, reason) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "Control Plane Plugin configuration is invalid",
      [
        %{reason: inspect(reason)}
      ]
    )
  end
end
