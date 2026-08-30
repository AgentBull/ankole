defmodule AnkoleWeb.IdentityMappingRequestController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for manual identity mappings.

  Lists signal senders that resolved to no Principal, binds one to a chosen
  Principal, and maps a known platform account proactively.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Principals.MappingRequests
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingBindRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingRequestListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingWriteRequest

  tags(["Identity Mappings"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List pending identity mapping requests",
    responses: [
      ok: {"Pending mapping requests", "application/json", IdentityMappingRequestListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:bind,
    summary: "Bind one pending mapping request to a principal",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Bind target", "application/json", IdentityMappingBindRequest, required: true},
    responses: [
      ok: {"Bound identity", "application/json", IdentityMappingResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid bind target", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Dismiss one pending mapping request",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Dismissed", "application/json", IdentityMappingRequestListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create_mapping,
    summary: "Map a provider subject to a principal proactively",
    request_body:
      {"Identity mapping", "application/json", IdentityMappingWriteRequest, required: true},
    responses: [
      ok: {"Bound identity", "application/json", IdentityMappingResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid mapping", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_mapping_requests", "read") do
      json(conn, %{
        identity_mapping_requests: Enum.map(MappingRequests.list_requests(), &request_json/1)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def bind(conn, %{id: id}) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_mapping_requests", "update"),
         {:ok, principal_uid} <- body_text(conn, :principal_uid),
         {:ok, %{identity: identity}} <- MappingRequests.bind_request(id, principal_uid) do
      json(conn, %{identity_mapping: identity_json(identity)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, %{id: id}) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_mapping_requests", "update"),
         {:ok, _request} <- MappingRequests.delete_request(id) do
      json(conn, %{
        identity_mapping_requests: Enum.map(MappingRequests.list_requests(), &request_json/1)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_mapping(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_mapping_requests", "update"),
         {:ok, principal_uid} <- body_text(conn, :principal_uid),
         {:ok, provider} <- body_text(conn, :provider),
         {:ok, external_id} <- body_text(conn, :external_id),
         {:ok, identity} <-
           MappingRequests.bind_subject(principal_uid, %{
             provider: provider,
             external_id: external_id
           }) do
      json(conn, %{identity_mapping: identity_json(identity)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp request_json(request) do
    %{
      id: request.id,
      provider: request.provider,
      external_id: request.external_id,
      display_name: request.display_name,
      email: request.email,
      mobile: request.mobile,
      metadata: request.metadata,
      first_seen_at: DateTime.to_iso8601(request.inserted_at),
      last_seen_at: DateTime.to_iso8601(request.updated_at)
    }
  end

  defp identity_json(identity) do
    %{
      principal_uid: identity.principal_uid,
      provider: identity.provider,
      external_id: identity.external_id
    }
  end

  defp body_text(conn, key) do
    case Map.get(conn.body_params, key, Map.get(conn.body_params, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_param, key}}
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: error(conn, 404, "not_found", "mapping request was not found")

  defp error(conn, :principal_not_found),
    do: error(conn, 422, "invalid_principal", "principal was not found")

  defp error(conn, :not_human),
    do: error(conn, 422, "invalid_principal", "identities bind to human principals only")

  defp error(conn, :principal_disabled),
    do: error(conn, 422, "invalid_principal", "principal is disabled")

  defp error(conn, :platform_subject_already_bound),
    do: error(conn, 409, "subject_already_bound", "provider subject is already bound")

  defp error(conn, {:missing_param, field}),
    do: error(conn, 422, "invalid_request", "#{field} is required")

  defp error(conn, %Ecto.Changeset{}),
    do: error(conn, 422, "invalid_request", "mapping is invalid")

  defp error(conn, reason),
    do: error(conn, 500, "internal_error", "unexpected error: #{inspect(reason)}")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
