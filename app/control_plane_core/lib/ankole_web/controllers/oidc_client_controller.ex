defmodule AnkoleWeb.OIDCClientController do
  @moduledoc """
  Console REST API for the OIDC Client secret and the login sources of the
  client policy. The `/api/v2` JSON:API serves the other OIDC Client routes.
  """

  use AnkoleWeb, :controller

  action_fallback(:fallback)
  use OpenApiSpex.ControllerSpecs

  alias Ankole.OIDC
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientSecretResponse

  tags(["OIDC Clients"])
  security([%{"consoleSession" => []}])

  plug(OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer
  )

  operation(:login_sources,
    operation_id: "oidcLoginSources",
    summary: "List authentication sources for OIDC Client policy",
    responses: [
      ok: {"Sources", "application/json", AnkoleWeb.Schemas.ConsoleAPI.OIDCLoginSources},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def login_sources(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_clients", "read"),
         {:ok, configured} <- Ankole.IdentityProviders.list_configured_providers() do
      sources =
        Enum.map(configured, &Map.take(&1, ["provider_id", "enabled"])) ++
          Enum.map(Ankole.IdentityProviders.SiteSources.providers(), fn source ->
            %{"provider_id" => source["provider_id"], "enabled" => true}
          end)

      json(conn, %{sources: sources})
    end
  end

  operation(:rotate_secret,
    summary: "Rotate a confidential OIDC Client secret",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"OIDC Client and one-time secret", "application/json", OIDCClientSecretResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def rotate_secret(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "update"),
         {:ok, result} <- OIDC.rotate_secret(id) do
      conn
      |> no_store()
      |> json(%{oidc_client: result.client, client_secret: result.client_secret})
    end
  end

  defp id_param(params) do
    case Map.get(params, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :not_found}
    end
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found),
    do: ConsoleErrors.not_found(conn, "OIDC Client was not found")

  defp error(conn, :public_client) do
    ConsoleErrors.render(conn, 409, "public_client", "public Clients do not have a secret")
  end

  defp error(conn, reason) do
    ConsoleErrors.unexpected(conn, "oidc.client_api.unexpected_error", reason)
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
