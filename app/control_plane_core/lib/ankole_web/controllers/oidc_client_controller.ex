defmodule AnkoleWeb.OIDCClientController do
  @moduledoc """
  Console REST API for operator-managed OIDC Clients.
  """

  use AnkoleWeb, :controller

  action_fallback(:fallback)
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
  security([%{"consoleSession" => []}])

  plug(OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer
  )

  operation(:index,
    summary: "List OIDC Clients",
    responses: [
      ok: {"OIDC Clients", "application/json", OIDCClientListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
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

  operation(:create,
    summary: "Create an OIDC Client",
    request_body: {"OIDC Client", "application/json", OIDCClientCreateRequest, required: true},
    responses: [
      created: {"OIDC Client and one-time secret", "application/json", OIDCClientSecretResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"OIDC Client", "application/json", OIDCClientResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"OIDC Client fields", "application/json", OIDCClientUpdateRequest, required: true},
    responses: [
      ok: {"OIDC Client", "application/json", OIDCClientResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete an OIDC Client",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Deleted OIDC Client", "application/json", OIDCClientResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:rotate_secret,
    summary: "Rotate a confidential OIDC Client secret",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"OIDC Client and one-time secret", "application/json", OIDCClientSecretResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:logout_deliveries,
    summary: "List Back-Channel Logout deliveries",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Logout deliveries", "application/json",
         AnkoleWeb.Schemas.HumanAccessAPI.LogoutDeliveriesResponse}
    ]
  )

  operation(:retry_logout,
    summary: "Retry a Back-Channel Logout delivery",
    parameters: [
      id: [in: :path, type: :string, required: true],
      delivery_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    responses: [
      ok:
        {"Logout deliveries", "application/json",
         AnkoleWeb.Schemas.HumanAccessAPI.LogoutDeliveriesResponse}
    ]
  )

  def logout_deliveries(conn, %{id: id}) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "read") do
      deliveries(conn, id)
    end
  end

  def retry_logout(conn, %{id: id, delivery_id: delivery_id}) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "update"),
         true <- Enum.any?(OIDC.Logout.deliveries(id), &(&1.delivery.id == delivery_id)),
         {:ok, _} <- OIDC.Logout.retry(delivery_id) do
      deliveries(conn, id)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliveries(conn, id) do
    rows =
      Enum.map(OIDC.Logout.deliveries(id), fn %{delivery: d, principal_uid: uid} ->
        d
        |> Map.take([
          :id,
          :session_id,
          :status,
          :attempt_count,
          :last_attempt_at,
          :next_attempt_at,
          :delivered_at,
          :deadline,
          :last_error
        ])
        |> Map.put(:principal_uid, uid)
      end)

    json(conn, Ankole.JSON.plain(%{deliveries: rows}))
  end

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_clients", "read") do
      json(conn, %{oidc_clients: OIDC.list_clients()})
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "oidc_clients", "update"),
         {:ok, result} <- OIDC.create_client(conn.body_params) do
      conn
      |> no_store()
      |> put_status(201)
      |> json(%{oidc_client: result.client, client_secret: result.client_secret})
    end
  end

  def show(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "read"),
         {:ok, client} <- OIDC.get_client(id) do
      json(conn, %{oidc_client: OIDC.projection(client)})
    end
  end

  def update(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "update"),
         {:ok, client} <- OIDC.update_client(id, conn.body_params) do
      json(conn, %{oidc_client: client})
    end
  end

  def delete(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "oidc_client:#{id}", "delete"),
         {:ok, client} <- OIDC.delete_client(id) do
      json(conn, %{oidc_client: client})
    end
  end

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

  defp fallback(conn, failure),
    do:
      ConsoleErrors.fallback(conn, failure, &error/2,
        validation: {"validation_failed", "OIDC Client validation failed"}
      )

  defp error(conn, :not_found),
    do: ConsoleErrors.not_found(conn, "OIDC Client was not found")

  defp error(conn, :public_client) do
    ConsoleErrors.render(conn, 409, "public_client", "public Clients do not have a secret")
  end

  defp error(conn, :client_type_immutable) do
    ConsoleErrors.render(conn, 409, "client_type_immutable", "OIDC Client type cannot be changed")
  end

  defp error(conn, reason)
       when reason in [
              :invalid_request_body,
              :invalid_allowed_group_ids,
              :invalid_identity_provider_ids,
              :unknown_identity_provider,
              :allowed_group_required,
              :unknown_group
            ] do
    ConsoleErrors.render(conn, 422, "validation_failed", validation_message(reason))
  end

  defp error(conn, {:invalid_model_alias, alias_name, _reason}) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "allowed model alias #{inspect(alias_name)} is invalid"
    )
  end

  defp error(conn, {:invalid_model_aliases, _reason}) do
    ConsoleErrors.render(conn, 422, "validation_failed", "allowed_models must be an object")
  end

  defp error(conn, reason) do
    ConsoleErrors.unexpected(conn, "oidc.client_api.unexpected_error", reason)
  end

  defp validation_message(:invalid_identity_provider_ids),
    do: "allowed_identity_provider_ids is invalid"

  defp validation_message(:unknown_identity_provider),
    do: "An allowed identity provider does not exist"

  defp validation_message(:invalid_request_body), do: "request body must be an object"
  defp validation_message(:invalid_allowed_group_ids), do: "allowed_group_ids is invalid"

  defp validation_message(:allowed_group_required),
    do: "ai_gateway.write requires an allowed group"

  defp validation_message(:unknown_group), do: "an allowed group does not exist"

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
