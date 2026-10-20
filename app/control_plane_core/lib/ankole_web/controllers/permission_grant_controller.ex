defmodule AnkoleWeb.PermissionGrantController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for AuthZ permission grants owned by Principals or groups.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias AnkoleWeb.AuthZJSON
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantUpdateRequest

  tags(["AuthZ"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:create,
    summary: "Create one permission grant for a Principal or a group",
    request_body:
      {"Permission grant", "application/json", PermissionGrantCreateRequest, required: true},
    responses: [
      ok: {"Permission grant", "application/json", PermissionGrantResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one permission grant",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Permission grant", "application/json", PermissionGrantResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update one permission grant",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Permission grant", "application/json", PermissionGrantUpdateRequest, required: true},
    responses: [
      ok: {"Permission grant", "application/json", PermissionGrantResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete one permission grant",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Permission grant", "application/json", PermissionGrantResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "permission_grants", "update"),
         {:ok, attrs} <- create_attrs(conn.body_params),
         {:ok, grant} <- AuthZ.create_permission_grant(attrs) do
      json(conn, %{permission_grant: AuthZJSON.grant_json(grant)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "permission_grant:#{id}", "read"),
         {:ok, grant} <- AuthZ.get_permission_grant(id) do
      json(conn, %{permission_grant: AuthZJSON.grant_json(grant)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "permission_grant:#{id}", "update"),
         {:ok, grant} <- AuthZ.get_permission_grant(id),
         {:ok, attrs} <- update_attrs(grant, conn.body_params),
         {:ok, updated} <- AuthZ.update_permission_grant(grant, attrs) do
      json(conn, %{permission_grant: AuthZJSON.grant_json(updated)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, id} <- id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "permission_grant:#{id}", "delete"),
         {:ok, grant} <- AuthZ.get_permission_grant(id),
         :ok <- reject_page_action(grant.action),
         {:ok, grant} <- AuthZ.delete_permission_grant(id) do
      json(conn, %{permission_grant: AuthZJSON.grant_json(grant)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp create_attrs(attrs) when is_map(attrs) do
    attrs =
      Map.take(attrs, [
        :principal_uid,
        :group_name,
        :resource_pattern,
        :action,
        :condition,
        :description
      ])

    with :ok <- reject_page_action(Map.get(attrs, :action)) do
      {:ok, attrs}
    end
  end

  defp create_attrs(_attrs), do: {:error, {:missing, "permission_grant"}}

  defp update_attrs(%Grant{} = grant, attrs) when is_map(attrs) do
    attrs = Map.take(attrs, [:resource_pattern, :action, :condition, :description])

    with :ok <- reject_page_action(Map.get(attrs, :action)),
         :ok <- keep_grant_shape(grant, attrs) do
      {:ok, attrs}
    end
  end

  defp update_attrs(_grant, _attrs), do: {:ok, %{}}

  defp reject_page_action(action) do
    if action in Ankole.Pod.Access.page_actions(),
      do: {:error, {:reserved_action, action}},
      else: :ok
  end

  # A page grant keeps the resource pattern and condition that the Pod wrote, so
  # an update can change only its description.
  defp keep_grant_shape(%Grant{action: action}, attrs) do
    if action in Ankole.Pod.Access.page_actions() do
      case Enum.filter([:resource_pattern, :action, :condition], &Map.has_key?(attrs, &1)) do
        [] -> :ok
        fields -> {:error, {:page_grant_shape, fields}}
      end
    else
      :ok
    end
  end

  defp id_param(params) do
    case Map.get(params, :id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "id"}}
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found) do
    error(conn, 404, "not_found", "permission grant or owner group was not found")
  end

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, {:reserved_action, action}) do
    error(conn, 422, "validation_failed", "action is reserved for the Pod", [
      %{
        path: "action",
        kind: "reserved",
        message: "#{action} is written by the Pod, not by this interface"
      }
    ])
  end

  defp error(conn, {:page_grant_shape, fields}) do
    error(
      conn,
      422,
      "validation_failed",
      "a page grant keeps its resource pattern and condition",
      Enum.map(fields, &%{path: to_string(&1), kind: "immutable"})
    )
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    error(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_permission_grant", "permission grant request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
