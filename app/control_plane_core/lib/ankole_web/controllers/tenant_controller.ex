defmodule AnkoleWeb.TenantController do
  @moduledoc "Site administrator access to the tenant lifecycle owner."
  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenApiSpex.ControllerSpecs
  alias Ankole.Tenants
  alias AnkoleWeb.{ConsoleErrors, ConsolePolicy}
  alias AnkoleWeb.Schemas.TenantAPI
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Tenants"])
  security([%{"consoleSession" => []}])
  plug OpenApiSpex.Plug.CastAndValidate, render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List tenants",
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.ListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create a tenant",
    request_body: {"Tenant request", "application/json", TenantAPI.CreateRequest, required: true},
    responses: [
      created: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update a tenant",
    parameters: [
      tenant_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    request_body: {"Tenant request", "application/json", TenantAPI.UpdateRequest, required: true},
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Start tenant deletion",
    parameters: [
      tenant_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    responses: [
      accepted: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:suspend,
    summary: "Suspend new work in a tenant",
    parameters: [
      tenant_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:resume,
    summary: "Resume work in a tenant",
    parameters: [
      tenant_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:privileged,
    summary: "Read the privileged tenant",
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:transfer,
    summary: "Transfer site administration",
    request_body:
      {"Tenant request", "application/json", TenantAPI.TransferRequest, required: true},
    responses: [
      ok: {"Tenant result", "application/json", TenantAPI.Response},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "site:tenants", "read") do
      json(conn, %{
        tenants: Enum.map(Tenants.list(), &tenant_json/1),
        brain_packs: Ankole.Brain.SchemaPacks.industry_packs()
      })
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "site:tenants", "update"),
         {:ok, tenant} <-
           Tenants.create(Map.take(conn.body_params, [:slug, :display_name, :brain_packs])) do
      conn
      |> put_status(:created)
      |> json(%{tenant: tenant_json(tenant)})
    end
  end

  def update(conn, params) do
    with {:ok, tenant} <- fetch_authorized(conn, params, "update"),
         {:ok, tenant} <-
           Tenants.update(tenant, Map.take(conn.body_params, [:slug, :display_name])) do
      json(conn, %{tenant: tenant_json(tenant)})
    end
  end

  def delete(conn, params) do
    with {:ok, tenant} <- fetch_authorized(conn, params, "delete"),
         {:ok, tenant} <- Tenants.delete(tenant) do
      conn |> put_status(:accepted) |> json(%{tenant: tenant_json(tenant)})
    end
  end

  def suspend(conn, params) do
    with {:ok, tenant} <- fetch_authorized(conn, params, "update"),
         {:ok, tenant} <- Tenants.suspend(tenant) do
      json(conn, %{tenant: tenant_json(tenant)})
    end
  end

  def resume(conn, params) do
    with {:ok, tenant} <- fetch_authorized(conn, params, "update"),
         {:ok, tenant} <- Tenants.resume(tenant) do
      json(conn, %{tenant: tenant_json(tenant)})
    end
  end

  def privileged(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "site:privileged_tenant", "read"),
         {:ok, tenant} <- Tenants.privileged() do
      json(conn, %{tenant: tenant_json(tenant)})
    end
  end

  def transfer(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "site:privileged_tenant", "update"),
         {:ok, tenant} <- Tenants.get(conn.body_params[:tenant_id]),
         {:ok, tenant} <-
           Tenants.transfer_site_administration(tenant, conn.body_params[:site_admin_uid]) do
      json(conn, %{tenant: tenant_json(tenant)})
    end
  end

  defp fetch_authorized(conn, params, action) do
    id = params.tenant_id
    with :ok <- ConsolePolicy.authorize(conn, "site:tenant:#{id}", action), do: Tenants.get(id)
  end

  defp tenant_json(tenant),
    do:
      tenant
      |> Map.take([
        :id,
        :slug,
        :display_name,
        :suspended_at,
        :deleting_at,
        :inserted_at,
        :updated_at
      ])
      |> Ankole.JSON.plain()

  defp fallback(conn, {:error, :forbidden}), do: ConsoleErrors.forbidden(conn, "Access denied")

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found),
    do: ConsoleErrors.not_found(conn, "Tenant not found")

  defp error(conn, %module{} = changeset) when module in [Ash.Changeset, Ash.Error.Invalid],
    do: ConsoleErrors.changeset(conn, changeset, "The tenant request is invalid")

  defp error(conn, reason) when is_atom(reason),
    do:
      ConsoleErrors.render(conn, 409, Atom.to_string(reason), "The tenant operation was refused")

  defp error(conn, _reason),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "The tenant request is invalid")
end
