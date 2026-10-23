defmodule AnkoleWeb.AIGatewayProviderController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the AIGateway model catalog, the provider kinds, and the
  credential pool of a provider. The site JSON:API
  (`Ankole.AIGateway.ProviderConfigs`) serves the provider records.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.ProviderConfigs
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTBrowserLoginRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTEnterpriseCredentialRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginPollRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginStartRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialStrategyWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayModelCatalogResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderKindListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["AIGateway"])
  security([%{"consoleSession" => []}])

  plug(OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer
  )

  operation(:models,
    summary: "List the Console model catalog",
    responses: [
      ok: {"Model catalog", "application/json", AIGatewayModelCatalogResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:provider_kinds,
    summary: "List AIGateway provider kinds",
    responses: [
      ok: {"Provider kinds", "application/json", AIGatewayProviderKindListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:add_credential,
    summary: "Add one credential-pool member",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Credential", "application/json", AIGatewayCredentialWriteRequest, required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_credential,
    summary: "Update one credential-pool member",
    parameters: [
      provider_id: [in: :path, type: :string, required: true],
      credential_id: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Credential", "application/json", AIGatewayCredentialWriteRequest, required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_credential,
    summary: "Delete one credential-pool member",
    parameters: [
      provider_id: [in: :path, type: :string, required: true],
      credential_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_credential_strategy,
    summary: "Set the provider credential-pool selection strategy",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Credential strategy", "application/json", AIGatewayCredentialStrategyWriteRequest,
       required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:start_chatgpt_login,
    summary: "Start a ChatGPT device or browser-paste login",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Credential metadata", "application/json", AIGatewayChatGPTLoginStartRequest,
       required: true},
    responses: [
      ok: {"ChatGPT login", "application/json", AIGatewayChatGPTLoginResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:poll_chatgpt_login,
    summary: "Poll one ChatGPT device login once",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Login context", "application/json", AIGatewayChatGPTLoginPollRequest, required: true},
    responses: [
      ok: {"ChatGPT login", "application/json", AIGatewayChatGPTLoginResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:complete_chatgpt_browser_login,
    summary: "Complete a ChatGPT browser-paste login",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Browser callback", "application/json", AIGatewayChatGPTBrowserLoginRequest,
       required: true},
    responses: [
      ok: {"ChatGPT login", "application/json", AIGatewayChatGPTLoginResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:add_chatgpt_enterprise_credential,
    summary: "Add a ChatGPT enterprise access token",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Enterprise credential", "application/json", AIGatewayChatGPTEnterpriseCredentialRequest,
       required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def models(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_providers", "read") do
      json(conn, %{models: Models.console_catalog()})
    end
  end

  def provider_kinds(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider_kinds", "read") do
      json(conn, %{provider_kinds: ProviderConfigs.list_provider_kinds()})
    end
  end

  def add_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.add_credential(
             provider_id,
             conn.body_params
           ) do
      render_provider(conn, provider)
    end
  end

  def put_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, credential_id} <- ConsoleParams.text(params, :credential_id),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.update_credential(
             provider_id,
             credential_id,
             conn.body_params
           ) do
      render_provider(conn, provider)
    end
  end

  def delete_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, credential_id} <- ConsoleParams.text(params, :credential_id),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <- ProviderConfigs.delete_credential(provider_id, credential_id) do
      render_provider(conn, provider)
    end
  end

  def put_credential_strategy(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.update_credential_strategy(provider_id, conn.body_params.strategy) do
      render_provider(conn, provider)
    end
  end

  def start_chatgpt_login(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <-
           ChatGPTAuth.start_login(provider_id, conn.body_params) do
      json(conn, login)
    end
  end

  def poll_chatgpt_login(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <- ChatGPTAuth.poll_login(provider_id, conn.body_params.login_context) do
      json(conn, login)
    end
  end

  def complete_chatgpt_browser_login(conn, params) do
    %{login_context: login_context, callback_url: callback_url} = conn.body_params

    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <-
           ChatGPTAuth.complete_browser_login(provider_id, login_context, callback_url) do
      json(conn, login)
    end
  end

  def add_chatgpt_enterprise_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ChatGPTAuth.add_enterprise_credential(
             provider_id,
             conn.body_params
           ) do
      render_provider(conn, provider)
    end
  end

  defp provider_id_param(%{provider_id: provider_id}), do: normalize_provider_id(provider_id)

  defp normalize_provider_id(value) when is_binary(value) do
    # Provider ids are treated as case- and whitespace-insensitive, so they are
    # trimmed and lowercased before use as identity and inside authz resource
    # strings (an empty id is rejected).
    case Ankole.AIGateway.ProviderConfigs.Provider.normalize_id(value) do
      "" -> {:error, :blank_id}
      value -> {:ok, value}
    end
  end

  defp normalize_provider_id(_value), do: {:error, :blank_id}

  defp render_provider(conn, provider) do
    json(conn, %{ai_gateway_provider: ProviderConfigs.projection(provider)})
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "resource was not found")

  defp error(conn, :credential_not_found),
    do: ConsoleErrors.not_found(conn, "credential was not found")

  defp error(conn, :agent_not_found), do: ConsoleErrors.not_found(conn, "agent was not found")

  defp error(conn, {:missing, key}) do
    ConsoleErrors.required_field(conn, key)
  end

  # ChatGPT sign-in and refresh failures carry the real upstream response, so
  # the operator sees the actual rejection instead of a configuration message.
  defp error(conn, {:device_login_failed, status, code}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_rejected",
      "ChatGPT sign-in was rejected by the sign-in service (#{upstream_label(status, code)})",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, {:token_exchange_failed, status, code}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_rejected",
      "ChatGPT token exchange was rejected by the sign-in service (#{upstream_label(status, code)})",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, :invalid_device_login_response) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_rejected",
      "the ChatGPT sign-in service returned an unexpected device-login response"
    )
  end

  defp error(conn, {:request_failed, reason}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_unreachable",
      "the ChatGPT sign-in service was unreachable (#{transport_label(reason)})",
      [%{transport: transport_label(reason)}]
    )
  end

  defp error(conn, {:oauth_denied, code}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_denied",
      "the ChatGPT account denied the sign-in request",
      [
        %{upstream_code: code}
      ]
    )
  end

  defp error(conn, :login_expired) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_expired",
      "the ChatGPT sign-in expired; start it again"
    )
  end

  defp error(conn, :oauth_state_mismatch) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_invalid",
      "the pasted callback URL belongs to a different sign-in attempt"
    )
  end

  defp error(conn, :invalid_device_pkce) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_invalid",
      "the device sign-in context failed verification"
    )
  end

  defp error(conn, :invalid_callback_url) do
    ConsoleErrors.render(conn, 422, "validation_failed", "callback_url is not a valid URL")
  end

  defp error(conn, :invalid_login_context) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "login_context is invalid; start the sign-in again"
    )
  end

  defp error(conn, :credential_not_refreshable) do
    ConsoleErrors.render(
      conn,
      422,
      "credential_not_refreshable",
      "this credential holds no refresh token; sign in again to replace it"
    )
  end

  defp error(conn, {:chatgpt_refresh_permanent, code}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_refresh_failed",
      "ChatGPT credential refresh was rejected (#{code}); sign in again",
      [%{upstream_code: code}]
    )
  end

  defp error(conn, {:chatgpt_refresh_transient, status, _headers, code}) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_refresh_failed",
      "ChatGPT credential refresh failed (#{upstream_label(status, code)}); retry later",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, :provider_not_chatgpt_subscription) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "this provider is not a ChatGPT subscription provider"
    )
  end

  defp error(conn, :login_issuer_changed) do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_invalid",
      "the provider's sign-in issuer changed; start the sign-in again"
    )
  end

  defp error(conn, reason) when reason in [:invalid_jwt, :invalid_jwt_expiration] do
    ConsoleErrors.render(
      conn,
      422,
      "chatgpt_login_rejected",
      "the ChatGPT sign-in service returned an invalid token"
    )
  end

  defp error(conn, :invalid_device_poll_interval) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "login_context is invalid; start the sign-in again"
    )
  end

  defp error(conn, :blank_id) do
    ConsoleErrors.render(conn, 422, "validation_failed", "provider_id is required")
  end

  defp error(conn, {:invalid_credential_entry, credential_id}) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_value",
      "a stored credential entry is invalid; sign in again to replace it",
      [
        %{credential_id: credential_id}
      ]
    )
  end

  defp error(conn, {:invalid_credential_payload, credential_id}) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_value",
      "a stored credential cannot be read; sign in again to replace it",
      [
        %{credential_id: credential_id}
      ]
    )
  end

  defp error(conn, {:credential_decrypt_failed, credential_id, _reason}) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_value",
      "a stored credential cannot be decrypted; sign in again to replace it",
      [
        %{credential_id: credential_id}
      ]
    )
  end

  # Known configuration reasons keep the established envelope but name the
  # rejected rule; anything unlisted logs as a server-side gap.
  defp error(conn, reason) do
    case ProviderConfigs.rejection(reason) do
      nil ->
        ConsoleErrors.unexpected(conn, "ai_gateway.provider_api.unexpected_error", reason)

      {message, _details} ->
        ConsoleErrors.render(conn, 422, "invalid_value", message)
    end
  end

  defp upstream_label(nil, code), do: "#{code || "unknown error"}"
  defp upstream_label(status, nil), do: "HTTP #{status}"
  defp upstream_label(status, code), do: "HTTP #{status}, #{code}"

  defp transport_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_label(reason) when is_binary(reason), do: reason
  defp transport_label(_reason), do: "transport_error"
end
