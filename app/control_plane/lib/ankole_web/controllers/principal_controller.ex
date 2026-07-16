defmodule AnkoleWeb.PrincipalController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for selecting active Principals across operator surfaces.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalListResponse

  tags(["Principals"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List active principals",
    responses: [
      ok: {"Principals", "application/json", PrincipalListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principals", "read") do
      json(conn, %{principals: Enum.map(Principals.list_active_principals(), &principal_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp principal_json(%Principal{} = principal) do
    %{
      uid: principal.uid,
      type: Atom.to_string(principal.type),
      status: Atom.to_string(principal.status),
      display_name: principal.display_name,
      avatar_url: principal.avatar_url,
      inserted_at: DateTime.to_iso8601(principal.inserted_at),
      updated_at: DateTime.to_iso8601(principal.updated_at)
    }
  end

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")
end
