defmodule AnkoleWeb.OIDCClientController do
  @moduledoc """
  Console REST API for operator-managed OIDC Clients.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.OIDC
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientSecretResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientUpdateRequest

  tags(["OIDC Clients"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List OIDC Clients",
    responses: [
      ok: {"OIDC Clients", "application/json", OIDCClientListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create an OIDC Client",
    request_body: {"OIDC Client", "application/json", OIDCClientCreateRequest, required: true},
    responses: [
      created: {"OIDC Client and one-time secret", "application/json", OIDCClientSecretResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid OIDC Client", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"OIDC Client", "application/json", OIDCClientResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"OIDC Client fields", "application/json", OIDCClientUpdateRequest, required: true},
    responses: [
      ok: {"OIDC Client", "application/json", OIDCClientResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid OIDC Client", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Deleted OIDC Client", "application/json", OIDCClientResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:rotate_secret,
    summary: "Rotate a confidential OIDC Client secret",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"OIDC Client and one-time secret", "application/json", OIDCClientSecretResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Public Client", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_clients", "read") do
      json(conn, %{oidc_clients: OIDC.list_clients()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_clients", "update"),
         {:ok, result} <- OIDC.create_client(conn.body_params) do
      conn
      |> no_store()
      |> put_status(201)
      |> json(%{oidc_client: result.client, client_secret: result.client_secret})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "read"),
         {:ok, client} <- OIDC.get_client(id) do
      json(conn, %{oidc_client: OIDC.projection(client)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "update"),
         {:ok, client} <- OIDC.update_client(id, conn.body_params) do
      json(conn, %{oidc_client: client})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "delete"),
         {:ok, client} <- OIDC.delete_client(id) do
      json(conn, %{oidc_client: client})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def rotate_secret(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "update"),
         {:ok, result} <- OIDC.rotate_secret(id) do
      conn
      |> no_store()
      |> json(%{oidc_client: result.client, client_secret: result.client_secret})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp id_param(params) do
    case Map.get(params, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :not_found}
    end
  end

  defp error(conn, :forbidden), do: render_error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: render_error(conn, 404, "not_found", "OIDC Client was not found")

  defp error(conn, :public_client) do
    render_error(conn, 409, "public_client", "public Clients do not have a secret")
  end

  defp error(conn, :client_type_immutable) do
    render_error(conn, 409, "client_type_immutable", "OIDC Client type cannot be changed")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    render_error(
      conn,
      422,
      "validation_failed",
      "OIDC Client validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason)
       when reason in [
              :invalid_request_body,
              :invalid_allowed_group_ids,
              :allowed_group_required,
              :unknown_group
            ] do
    render_error(conn, 422, "validation_failed", validation_message(reason))
  end

  defp error(conn, {:invalid_model_alias, alias_name, _reason}) do
    render_error(
      conn,
      422,
      "validation_failed",
      "allowed model alias #{inspect(alias_name)} is invalid"
    )
  end

  defp error(conn, {:invalid_model_aliases, _reason}) do
    render_error(conn, 422, "validation_failed", "allowed_models must be an object")
  end

  defp error(conn, reason) do
    ConsoleErrors.unexpected(conn, "oidc.client_api.unexpected_error", reason)
  end

  defp validation_message(:invalid_request_body), do: "request body must be an object"
  defp validation_message(:invalid_allowed_group_ids), do: "allowed_group_ids is invalid"

  defp validation_message(:allowed_group_required),
    do: "ai_gateway.write requires an allowed group"

  defp validation_message(:unknown_group), do: "an allowed group does not exist"

  defp render_error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
