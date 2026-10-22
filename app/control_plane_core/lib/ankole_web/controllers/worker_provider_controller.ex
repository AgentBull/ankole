defmodule AnkoleWeb.WorkerProviderController do
  @moduledoc "Console access to Worker provider configuration and one-time Agent assignment."

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers
  alias AnkoleWeb.{ConsoleErrors, ConsoleParams, ConsolePolicy}
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.WorkerProviderAPI

  tags(["Worker providers"])
  security([%{"consoleSession" => []}])
  plug OpenApiSpex.Plug.CastAndValidate, render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List Worker providers",
    responses: [
      ok: {"Worker providers", "application/json", WorkerProviderAPI.ListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:kinds,
    summary: "List Worker provider kinds and YAML examples",
    responses: [
      ok: {"Worker provider kinds", "application/json", WorkerProviderAPI.KindsResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create a Worker provider",
    request_body:
      {"Worker provider", "application/json", WorkerProviderAPI.CreateRequest, required: true},
    responses: [
      created: {"Worker provider", "application/json", WorkerProviderAPI.ProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update a Worker provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Worker provider", "application/json", WorkerProviderAPI.UpdateRequest, required: true},
    responses: [
      ok: {"Worker provider", "application/json", WorkerProviderAPI.ProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:check,
    summary: "Check a Worker provider connection and permissions",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Provider available", "application/json", WorkerProviderAPI.CheckResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete an unused Worker provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:assign,
    summary: "Assign a provider to an Agent migrated without one",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Provider selection", "application/json", WorkerProviderAPI.AssignRequest, required: true},
    responses: [
      ok: {"Provider assigned", "application/json", WorkerProviderAPI.AssignResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "worker_providers", "read") do
      json(conn, %{worker_providers: Providers.list_projections()})
    end
  end

  def kinds(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "worker_providers", "read") do
      kinds =
        Enum.map(ProviderKind.all(), fn kind ->
          kind.definition()
          |> Map.take([:kind, :example, :credentials])
        end)

      json(conn, %{worker_provider_kinds: kinds})
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "worker_providers", "update"),
         {:ok, provider} <- Providers.create(conn.body_params) do
      conn |> put_status(:created) |> json(%{worker_provider: Providers.projection(provider)})
    end
  end

  def update(conn, params) do
    with {:ok, id} <- ConsoleParams.text(params, :provider_id),
         :ok <- ConsolePolicy.authorize(conn, "worker_provider:#{id}", "update"),
         {:ok, provider} <- Providers.update(id, conn.body_params) do
      json(conn, %{worker_provider: Providers.projection(provider)})
    end
  end

  def check(conn, params) do
    with {:ok, id} <- ConsoleParams.text(params, :provider_id),
         :ok <- ConsolePolicy.authorize(conn, "worker_provider:#{id}", "read"),
         :ok <- Providers.check(id) do
      json(conn, %{available: true})
    end
  end

  def delete(conn, params) do
    with {:ok, id} <- ConsoleParams.text(params, :provider_id),
         :ok <- ConsolePolicy.authorize(conn, "worker_provider:#{id}", "delete"),
         {:ok, _provider} <- Providers.delete(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def assign(conn, params) do
    with {:ok, uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{uid}", "update"),
         {:ok, id} <- ConsoleParams.text(conn.body_params, :provider_id),
         {:ok, worker} <- Providers.assign(uid, id) do
      json(conn, %{agent_uid: worker.agent_uid, provider_id: worker.provider_id})
    end
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, {:missing, key}), do: ConsoleErrors.required_field(conn, key)

  defp error(conn, :worker_provider_not_found),
    do:
      ConsoleErrors.render(
        conn,
        404,
        "worker_provider_not_found",
        "Worker provider was not found"
      )

  defp error(conn, :agent_not_found),
    do: ConsoleErrors.render(conn, 404, "agent_not_found", "Agent was not found")

  defp error(conn, :worker_provider_in_use),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "worker_provider_in_use",
        "Agents still use this provider, including Agents being deleted"
      )

  defp error(conn, :worker_provider_immutable),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "worker_provider_immutable",
        "This Agent already has a provider"
      )

  defp error(conn, :agent_uid_pending_deletion),
    do:
      ConsoleErrors.render(conn, 409, "agent_uid_pending_deletion", "This Agent is being deleted")

  defp error(conn, reason),
    do: render_provider_error(conn, Providers.Errors.describe(reason), reason)

  defp render_provider_error(conn, {:invalid, message, details}, _reason),
    do: ConsoleErrors.render(conn, 422, "invalid_worker_provider", message, details)

  defp render_provider_error(conn, {:conflict, message, details}, _reason),
    do: ConsoleErrors.render(conn, 409, "worker_provider_plugin_in_use", message, details)

  defp render_provider_error(conn, :unknown, reason),
    do: ConsoleErrors.unexpected(conn, "worker_provider.api_failed", reason)
end
