defmodule AnkoleWeb.AuthZGroupController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for AuthZ Principal groups, memberships, and group grants.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AuthZ
  alias AnkoleWeb.AuthZJSON
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ComputedMemberPreviewRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupMemberListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupUpdateRequest

  tags(["AuthZ"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List Principal groups",
    responses: [
      ok: {"Principal groups", "application/json", PrincipalGroupListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create one operator Principal group",
    request_body:
      {"Principal group", "application/json", PrincipalGroupCreateRequest, required: true},
    responses: [
      ok: {"Principal group", "application/json", PrincipalGroupResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one Principal group",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal group", "application/json", PrincipalGroupResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update mutable fields of one Principal group",
    parameters: [name: [in: :path, type: :string, required: true]],
    request_body:
      {"Principal group", "application/json", PrincipalGroupUpdateRequest, required: true},
    responses: [
      ok: {"Principal group", "application/json", PrincipalGroupResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete one operator Principal group without grants",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal group", "application/json", PrincipalGroupResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:members,
    summary: "List effective members of one Principal group",
    description:
      "Static groups return stored memberships. Computed groups return the members " <>
        "evaluated from their condition.",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal group members", "application/json", PrincipalGroupMemberListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:add_member,
    summary: "Add one Principal to a static operator group",
    parameters: [
      name: [in: :path, type: :string, required: true],
      principal_uid: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Principal group members", "application/json", PrincipalGroupMemberListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:remove_member,
    summary: "Remove one Principal from a static operator group",
    parameters: [
      name: [in: :path, type: :string, required: true],
      principal_uid: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Principal group members", "application/json", PrincipalGroupMemberListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:grants,
    summary: "List permission grants owned by one Principal group",
    parameters: [name: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Permission grants", "application/json", PermissionGrantListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:preview_computed_members,
    summary: "Preview active Principals matching a computed group condition",
    request_body:
      {"Computed member preview", "application/json", ComputedMemberPreviewRequest,
       required: true},
    responses: [
      ok: {"Principal group members", "application/json", PrincipalGroupMemberListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principal_groups", "read") do
      summaries = AuthZ.summarize_principal_groups()

      json(conn, %{
        principal_groups:
          Enum.map(AuthZ.list_principal_groups(), &AuthZJSON.group_json(&1, summaries))
      })
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principal_groups", "update"),
         {:ok, attrs} <- create_attrs(conn.body_params),
         {:ok, group} <- AuthZ.create_principal_group(attrs) do
      json(conn, %{principal_group: AuthZJSON.group_json(group)})
    end
  end

  def show(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}", "read"),
         {:ok, group} <- AuthZ.get_principal_group(name) do
      json(conn, %{
        principal_group: AuthZJSON.group_json(group, AuthZ.summarize_principal_groups())
      })
    end
  end

  def update(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}", "update"),
         {:ok, group} <- AuthZ.get_principal_group(name),
         {:ok, updated} <- AuthZ.update_principal_group(group, update_attrs(conn.body_params)) do
      json(conn, %{
        principal_group: AuthZJSON.group_json(updated, AuthZ.summarize_principal_groups())
      })
    end
  end

  def delete(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}", "delete"),
         {:ok, group} <- AuthZ.delete_principal_group(name) do
      json(conn, %{principal_group: AuthZJSON.group_json(group)})
    end
  end

  def members(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}:members", "read"),
         {:ok, members} <- group_members(name) do
      json(conn, %{principal_group_members: Enum.map(members, &AuthZJSON.member_json/1)})
    end
  end

  def add_member(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         {:ok, principal_uid} <- principal_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}:members", "update"),
         {:ok, _membership} <- AuthZ.add_principal_to_group(principal_uid, name),
         {:ok, members} <- group_members(name) do
      json(conn, %{principal_group_members: Enum.map(members, &AuthZJSON.member_json/1)})
    end
  end

  def remove_member(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         {:ok, principal_uid} <- principal_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}:members", "update"),
         {:ok, :deleted} <- AuthZ.remove_principal_from_group(principal_uid, name),
         {:ok, members} <- group_members(name) do
      json(conn, %{principal_group_members: Enum.map(members, &AuthZJSON.member_json/1)})
    end
  end

  def grants(conn, params) do
    with {:ok, name} <- ConsoleParams.text(params, :name),
         :ok <- ConsolePolicy.authorize(conn, "principal_group:#{name}:grants", "read"),
         {:ok, grants} <- AuthZ.list_group_grants(name) do
      json(conn, %{permission_grants: Enum.map(grants, &AuthZJSON.grant_json/1)})
    end
  end

  def preview_computed_members(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principal_groups", "read"),
         {:ok, condition} <- condition_param(conn.body_params),
         {:ok, members} <- AuthZ.preview_computed_group_members(condition) do
      json(conn, %{principal_group_members: Enum.map(members, &AuthZJSON.member_json/1)})
    end
  end

  defp group_members(name) do
    case AuthZ.list_group_members(name) do
      {:ok, members} -> {:ok, members}
      {:error, :computed_group} -> computed_group_members(name)
      {:error, reason} -> {:error, reason}
    end
  end

  defp computed_group_members(name) do
    with {:ok, group} <- AuthZ.get_principal_group(name) do
      AuthZ.preview_computed_group_members(group.computed_condition)
    end
  end

  defp create_attrs(attrs) when is_map(attrs) do
    {:ok,
     attrs
     |> Map.take([:name, :display_name, :kind, :computed_condition, :description])}
  end

  defp create_attrs(_attrs), do: {:error, {:missing, "principal_group"}}

  defp update_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.take([:display_name, :computed_condition, :description])
  end

  defp update_attrs(_attrs), do: %{}

  defp principal_uid_param(params) do
    case Map.get(params, :principal_uid) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "principal_uid"}}
    end
  end

  defp condition_param(attrs) when is_map(attrs) do
    case attrs do
      %{condition: condition} when is_binary(condition) -> {:ok, condition}
      _attrs -> {:error, {:missing, "condition"}}
    end
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found) do
    ConsoleErrors.not_found(conn, "principal group, principal, or membership was not found")
  end

  defp error(conn, :built_in_group) do
    ConsoleErrors.render(
      conn,
      409,
      "built_in_group",
      "built-in groups cannot be modified or deleted"
    )
  end

  defp error(conn, :computed_group) do
    ConsoleErrors.render(
      conn,
      409,
      "computed_group",
      "computed group membership is derived from its condition"
    )
  end

  defp error(conn, :group_domain_mismatch) do
    ConsoleErrors.render(
      conn,
      409,
      "group_domain_mismatch",
      "group membership is managed by directory sync"
    )
  end

  defp error(conn, :group_has_grants) do
    ConsoleErrors.render(
      conn,
      409,
      "group_has_grants",
      "delete the group's permission grants first"
    )
  end

  defp error(conn, :last_admin_member) do
    ConsoleErrors.render(
      conn,
      409,
      "last_admin_member",
      "the admin group must keep at least one member"
    )
  end

  defp error(conn, :last_active_human_admin) do
    ConsoleErrors.render(
      conn,
      409,
      "last_active_human_admin",
      "the installation must keep one active human admin"
    )
  end

  defp error(conn, :not_human) do
    ConsoleErrors.render(
      conn,
      409,
      "not_human",
      "only active human Principals can join the admin group"
    )
  end

  defp error(conn, :principal_disabled) do
    ConsoleErrors.render(
      conn,
      409,
      "principal_disabled",
      "disabled Principals cannot join the admin group"
    )
  end

  defp error(conn, {:missing, key}) do
    ConsoleErrors.required_field(conn, key)
  end

  defp error(conn, %module{} = error) when module in [Ash.Changeset, Ash.Error.Invalid] do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "request is invalid",
      ConsoleErrors.changeset_details(error)
    )
  end

  defp error(conn, reason) when is_binary(reason) do
    ConsoleErrors.render(conn, 422, "validation_failed", reason)
  end

  defp error(conn, reason) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_principal_group",
      "principal group request is invalid",
      [
        %{reason: inspect(reason)}
      ]
    )
  end
end
