defmodule AnkoleWeb.WorkerProviderController do
  @moduledoc """
  Console access to Worker provider kinds, provider checks, and one-time Agent
  assignment. The site JSON:API (`Ankole.AgentWorkers.Providers`) serves the
  provider records.
  """

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

  operation(:kinds,
    summary: "List Worker provider kinds and YAML examples",
    responses: [
      ok: {"Worker provider kinds", "application/json", WorkerProviderAPI.KindsResponse},
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

  def check(conn, params) do
    with {:ok, id} <- ConsoleParams.text(params, :provider_id),
         :ok <- ConsolePolicy.authorize(conn, "worker_provider:#{id}", "read"),
         :ok <- Providers.check(id) do
      json(conn, %{available: true})
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
