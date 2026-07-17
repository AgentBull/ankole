defmodule AnkoleWeb.PrincipalController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for selecting active Principals across operator surfaces.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AuthZ
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias AnkoleWeb.AuthZJSON
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalResponse

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

  operation(:show,
    summary: "Read one principal",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal", "application/json", PrincipalResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:groups,
    summary: "List the static Principal groups one Principal belongs to",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal groups", "application/json", PrincipalGroupListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:grants,
    summary: "List permission grants owned directly by one Principal",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Permission grants", "application/json", PermissionGrantListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principals", "read") do
      json(conn, %{principals: Enum.map(Principals.list_active_principals(), &principal_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "read"),
         {:ok, principal} <- Principals.get_principal(uid) do
      json(conn, %{principal: principal_json(principal)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def groups(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}:groups", "read"),
         {:ok, groups} <- AuthZ.list_principal_group_memberships(uid) do
      summaries = AuthZ.summarize_principal_groups()

      json(conn, %{
        principal_groups: Enum.map(groups, &AuthZJSON.group_json(&1, summaries))
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def grants(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}:grants", "read"),
         {:ok, grants} <- AuthZ.list_principal_grants(uid) do
      json(conn, %{permission_grants: Enum.map(grants, &AuthZJSON.grant_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp uid_param(params) do
    case Map.get(params, :uid, Map.get(params, "uid")) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "uid"}}
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

  defp error(conn, :not_found),
    do: ConsoleErrors.render(conn, 404, "not_found", "principal was not found")

  defp error(conn, {:missing, key}),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "#{key} is required")

  defp error(conn, reason),
    do:
      ConsoleErrors.render(conn, 422, "invalid_principal", "principal request is invalid", [
        %{reason: inspect(reason)}
      ])
end
