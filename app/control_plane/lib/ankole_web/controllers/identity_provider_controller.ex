defmodule AnkoleWeb.IdentityProviderController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed identity providers.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.IdentityProviders
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderAdapterListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderSyncRunResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderWriteRequest

  tags(["Identity Providers"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:adapters,
    summary: "List identity-provider adapters",
    responses: [
      ok: {"Identity-provider adapters", "application/json", IdentityProviderAdapterListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index,
    summary: "List configured identity providers",
    responses: [
      ok: {"Identity providers", "application/json", IdentityProviderListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_provider,
    summary: "Create or update one identity provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Identity provider", "application/json", IdentityProviderWriteRequest, required: true},
    responses: [
      ok: {"Identity provider", "application/json", IdentityProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid provider", "application/json", ErrorEnvelope}
    ]
  )

  operation(:run_sync,
    summary: "Enqueue one identity-provider full directory sync",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Identity-provider sync run", "application/json", IdentityProviderSyncRunResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Sync disabled", "application/json", ErrorEnvelope}
    ]
  )

  def adapters(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_provider_adapters", "read") do
      json(conn, %{
        identity_provider_adapters: Enum.map(IdentityProviders.list_adapters(), &adapter_json/1)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_providers", "read"),
         {:ok, providers} <- IdentityProviders.list_configured_providers() do
      json(conn, %{identity_providers: providers})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "identity_provider:#{provider_id}", "update"),
         {:ok, attrs} <- provider_attrs(conn.body_params),
         {:ok, _provider} <-
           IdentityProviders.save_provider(
             provider_id,
             attrs.adapter_id,
             attrs.config,
             attrs.enabled,
             source: "console"
           ),
         {:ok, provider} <- IdentityProviders.fetch_configured_provider(provider_id) do
      json(conn, %{identity_provider: provider})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def run_sync(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "identity_provider:#{provider_id}", "sync"),
         {:ok, job} <-
           IdentityProviders.enqueue_sync(provider_id, reason: "manual", source: "console") do
      json(conn, %{
        sync_run: %{
          provider_id: provider_id,
          status: "enqueued",
          job_id: job.id
        }
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp provider_attrs(params) when is_map(params) do
    adapter_id = params[:adapter_id] || params["adapter_id"]

    config = Map.get(params, :config, Map.get(params, "config", %{}))
    enabled = Map.get(params, :enabled, Map.get(params, "enabled", true))

    with {:ok, adapter_id} <- non_empty_string(adapter_id, :adapter_id),
         true <- is_map(config) || {:error, :invalid_config},
         true <- is_boolean(enabled) || {:error, :invalid_enabled} do
      {:ok, %{adapter_id: adapter_id, config: config, enabled: enabled}}
    end
  end

  defp provider_attrs(_params), do: {:error, :invalid_request_body}

  defp provider_id_param(params) do
    params
    |> Map.get(:provider_id, Map.get(params, "provider_id"))
    |> non_empty_string(:provider_id)
  end

  defp non_empty_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:missing_param, field}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_empty_string(_value, field), do: {:error, {:missing_param, field}}

  defp adapter_json(adapter) do
    %{
      adapter_id: adapter.adapter_id,
      plugin_id: adapter.plugin_id,
      display_name: adapter.display_name,
      capabilities: adapter.capabilities,
      fields: adapter.fields,
      default_provider_id: adapter.default_provider_id
    }
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, {:unknown_identity_provider, _provider_id}) do
    error(conn, 404, "not_found", "identity provider was not found or is disabled")
  end

  defp error(conn, {:unknown_identity_provider_adapter, _adapter_id}) do
    error(conn, 404, "not_found", "identity provider adapter was not found")
  end

  defp error(conn, :sync_disabled) do
    error(conn, 422, "sync_disabled", "directory sync is disabled for this identity provider")
  end

  defp error(conn, :sync_unsupported) do
    error(
      conn,
      422,
      "sync_unsupported",
      "directory sync is not supported by this identity provider"
    )
  end

  defp error(conn, {:missing_param, field}) do
    error(conn, 422, "validation_failed", "#{field} is required")
  end

  defp error(conn, :invalid_config) do
    error(conn, 422, "validation_failed", "config must be an object")
  end

  defp error(conn, :invalid_enabled) do
    error(conn, 422, "validation_failed", "enabled must be a boolean")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "identity provider configuration is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
