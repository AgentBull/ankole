defmodule AnkoleWeb.AIGatewayProviderController do
  alias Ankole.Attrs
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed AIGateway providers.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.ProviderConfigs
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTBrowserLoginRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTEnterpriseCredentialRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginPollRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginStartRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialStrategyWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderKindListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["AIGateway"])
  security([%{"consoleBearer" => []}])

  plug(OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer
  )

  operation(:provider_kinds,
    summary: "List AIGateway provider kinds",
    responses: [
      ok: {"Provider kinds", "application/json", AIGatewayProviderKindListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index,
    summary: "List configured AIGateway providers",
    responses: [
      ok: {"AIGateway providers", "application/json", AIGatewayProviderListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_provider,
    summary: "Create or update one AIGateway provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"AIGateway provider", "application/json", AIGatewayProviderWriteRequest, required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid provider", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Get one AIGateway provider and its credential-pool status",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:add_credential,
    summary: "Add one credential-pool member",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Credential", "application/json", AIGatewayCredentialWriteRequest, required: true},
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid credential", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid credential", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid strategy", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Login failed", "application/json", ErrorEnvelope}
    ]
  )

  operation(:poll_chatgpt_login,
    summary: "Poll one ChatGPT device login once",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Login context", "application/json", AIGatewayChatGPTLoginPollRequest, required: true},
    responses: [
      ok: {"ChatGPT login", "application/json", AIGatewayChatGPTLoginResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Login failed", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Login failed", "application/json", ErrorEnvelope}
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
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid credential", "application/json", ErrorEnvelope}
    ]
  )

  operation(:enable_provider,
    summary: "Re-enable one disabled AIGateway provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid provider configuration", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_provider,
    summary: "Disable or delete one AIGateway provider",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"AIGateway provider", "application/json", AIGatewayProviderResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Provider in use", "application/json", ErrorEnvelope}
    ]
  )

  def provider_kinds(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider_kinds", "read") do
      json(conn, %{provider_kinds: ProviderConfigs.list_provider_kinds()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_providers", "read") do
      json(conn, %{ai_gateway_providers: ProviderConfigs.list_providers()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "read"),
         {:ok, provider} <- ProviderConfigs.get_provider(provider_id) do
      json(conn, %{ai_gateway_provider: provider})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, attrs} <- provider_attrs(provider_id, conn.body_params),
         {:ok, provider} <- put_provider_row(provider_id, attrs) do
      json(conn, %{ai_gateway_provider: ProviderConfigs.projection(provider)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "delete"),
         {:ok, provider} <- ProviderConfigs.delete_provider(provider_id) do
      json(conn, %{ai_gateway_provider: ProviderConfigs.projection(provider)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def enable_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <- ProviderConfigs.enable_provider(provider_id) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def add_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.add_credential(
             provider_id,
             Attrs.normalize_external_attrs(conn.body_params)
           ) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, credential_id} <- credential_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.update_credential(
             provider_id,
             credential_id,
             Attrs.normalize_external_attrs(conn.body_params)
           ) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, credential_id} <- credential_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <- ProviderConfigs.delete_credential(provider_id, credential_id) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_credential_strategy(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, strategy} <- body_param(conn.body_params, "strategy"),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ProviderConfigs.update_credential_strategy(provider_id, strategy) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def start_chatgpt_login(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <-
           ChatGPTAuth.start_login(provider_id, Attrs.normalize_external_attrs(conn.body_params)) do
      json(conn, login)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def poll_chatgpt_login(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, login_context} <- body_param(conn.body_params, "login_context"),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <- ChatGPTAuth.poll_login(provider_id, login_context) do
      json(conn, login)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def complete_chatgpt_browser_login(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         {:ok, login_context} <- body_param(conn.body_params, "login_context"),
         {:ok, callback_url} <- body_param(conn.body_params, "callback_url"),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, login} <-
           ChatGPTAuth.complete_browser_login(provider_id, login_context, callback_url) do
      json(conn, login)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def add_chatgpt_enterprise_credential(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, provider} <-
           ChatGPTAuth.add_enterprise_credential(
             provider_id,
             Attrs.normalize_external_attrs(conn.body_params)
           ) do
      render_provider(conn, provider)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Upserts by existence check rather than a DB on_conflict clause: the
  # provider_id is operator-supplied through the URL (not a generated key), so a
  # plain "fetch, then update or create" expresses the PUT-create-or-replace
  # contract clearly.
  defp put_provider_row(provider_id, attrs) do
    case ProviderConfigs.fetch_provider(provider_id) do
      {:ok, _provider} -> ProviderConfigs.update_provider(provider_id, attrs)
      {:error, :not_found} -> ProviderConfigs.create_provider(attrs)
    end
  end

  # Reconciles the provider_id from the URL path with an optional provider_id in
  # the request body: a missing body id is filled in from the path, but a body id
  # that disagrees with the path is rejected, so a PUT can never silently target a
  # different provider than the one named in its URL.
  defp provider_attrs(provider_id, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    case Map.get(attrs, "provider_id") do
      nil ->
        {:ok, Map.put(attrs, "provider_id", provider_id)}

      body_provider_id ->
        with {:ok, body_provider_id} <- normalize_provider_id(body_provider_id) do
          case body_provider_id == provider_id do
            true -> {:ok, Map.put(attrs, "provider_id", provider_id)}
            false -> {:error, :provider_id_mismatch}
          end
        end
    end
  end

  defp provider_attrs(_provider_id, _attrs), do: {:error, :invalid_provider}

  defp provider_id_param(params) do
    with {:ok, provider_id} <- fetch_param(params, "provider_id") do
      normalize_provider_id(provider_id)
    end
  end

  defp credential_id_param(params) do
    with {:ok, credential_id} <- fetch_param(params, "credential_id"),
         credential_id when is_binary(credential_id) <- credential_id,
         credential_id when credential_id != "" <- String.trim(credential_id) do
      {:ok, credential_id}
    else
      _value -> {:error, {:missing, "credential_id"}}
    end
  end

  defp body_param(params, key) when is_map(params) do
    fetch_param(params, key)
  end

  defp body_param(_params, key), do: {:error, {:missing, key}}

  # Console params arrive with string keys from the raw request body, but with
  # atom keys once OpenAPISpex has cast the declared path parameters, so both
  # spellings of the same key are accepted.
  defp fetch_param(params, key) do
    atom_key = param_atom(key)

    cond do
      Map.has_key?(params, key) -> {:ok, Map.fetch!(params, key)}
      Map.has_key?(params, atom_key) -> {:ok, Map.fetch!(params, atom_key)}
      true -> {:error, {:missing, key}}
    end
  end

  # Fixed key -> atom mapping. Request data must never reach String.to_atom/1
  # (an attacker could otherwise exhaust the global atom table), so only these
  # known parameter names are allowed to become atoms.
  defp param_atom("provider_id"), do: :provider_id
  defp param_atom("credential_id"), do: :credential_id
  defp param_atom("strategy"), do: :strategy
  defp param_atom("login_context"), do: :login_context
  defp param_atom("callback_url"), do: :callback_url

  defp normalize_provider_id(value) when is_binary(value) do
    # Provider ids are treated as case- and whitespace-insensitive, so they are
    # trimmed and lowercased before use as identity and inside authz resource
    # strings (an empty id is rejected).
    case value |> String.trim() |> String.downcase() do
      "" -> {:error, :blank_id}
      value -> {:ok, value}
    end
  end

  defp normalize_provider_id(_value), do: {:error, :blank_id}

  defp render_provider(conn, provider) do
    json(conn, %{ai_gateway_provider: ProviderConfigs.projection(provider)})
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "resource was not found")

  defp error(conn, :credential_not_found),
    do: error(conn, 404, "not_found", "credential was not found")

  defp error(conn, :agent_not_found), do: error(conn, 404, "not_found", "agent was not found")

  defp error(conn, {:provider_in_use, references}) do
    error(conn, 422, "provider_in_use", "provider is referenced by active model profiles", [
      %{references: references}
    ])
  end

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
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

  defp error(conn, :provider_id_mismatch) do
    error(conn, 422, "provider_id_mismatch", "body provider_id must match the path provider_id")
  end

  # ChatGPT sign-in and refresh failures carry the real upstream response, so
  # the operator sees the actual rejection instead of a configuration message.
  defp error(conn, {:device_login_failed, status, code}) do
    error(
      conn,
      422,
      "chatgpt_login_rejected",
      "ChatGPT sign-in was rejected by the sign-in service (#{upstream_label(status, code)})",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, {:token_exchange_failed, status, code}) do
    error(
      conn,
      422,
      "chatgpt_login_rejected",
      "ChatGPT token exchange was rejected by the sign-in service (#{upstream_label(status, code)})",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, :invalid_device_login_response) do
    error(
      conn,
      422,
      "chatgpt_login_rejected",
      "the ChatGPT sign-in service returned an unexpected device-login response"
    )
  end

  defp error(conn, {:request_failed, reason}) do
    error(
      conn,
      422,
      "chatgpt_login_unreachable",
      "the ChatGPT sign-in service was unreachable (#{transport_label(reason)})",
      [%{transport: transport_label(reason)}]
    )
  end

  defp error(conn, {:oauth_denied, code}) do
    error(conn, 422, "chatgpt_login_denied", "the ChatGPT account denied the sign-in request", [
      %{upstream_code: code}
    ])
  end

  defp error(conn, :login_expired) do
    error(conn, 422, "chatgpt_login_expired", "the ChatGPT sign-in expired; start it again")
  end

  defp error(conn, :oauth_state_mismatch) do
    error(
      conn,
      422,
      "chatgpt_login_invalid",
      "the pasted callback URL belongs to a different sign-in attempt"
    )
  end

  defp error(conn, :invalid_device_pkce) do
    error(conn, 422, "chatgpt_login_invalid", "the device sign-in context failed verification")
  end

  defp error(conn, :invalid_callback_url) do
    error(conn, 422, "validation_failed", "callback_url is not a valid URL")
  end

  defp error(conn, :invalid_login_context) do
    error(conn, 422, "validation_failed", "login_context is invalid; start the sign-in again")
  end

  defp error(conn, :credential_not_refreshable) do
    error(
      conn,
      422,
      "credential_not_refreshable",
      "this credential holds no refresh token; sign in again to replace it"
    )
  end

  defp error(conn, {:chatgpt_refresh_permanent, code}) do
    error(
      conn,
      422,
      "chatgpt_refresh_failed",
      "ChatGPT credential refresh was rejected (#{code}); sign in again",
      [%{upstream_code: code}]
    )
  end

  defp error(conn, {:chatgpt_refresh_transient, status, _headers, code}) do
    error(
      conn,
      422,
      "chatgpt_refresh_failed",
      "ChatGPT credential refresh failed (#{upstream_label(status, code)}); retry later",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp error(conn, :provider_not_chatgpt_subscription) do
    error(
      conn,
      422,
      "validation_failed",
      "this provider is not a ChatGPT subscription provider"
    )
  end

  defp error(conn, :login_issuer_changed) do
    error(
      conn,
      422,
      "chatgpt_login_invalid",
      "the provider's sign-in issuer changed; start the sign-in again"
    )
  end

  defp error(conn, reason) when reason in [:invalid_jwt, :invalid_jwt_expiration] do
    error(
      conn,
      422,
      "chatgpt_login_rejected",
      "the ChatGPT sign-in service returned an invalid token"
    )
  end

  defp error(conn, :invalid_device_poll_interval) do
    error(conn, 422, "validation_failed", "login_context is invalid; start the sign-in again")
  end

  defp error(conn, :blank_id) do
    error(conn, 422, "validation_failed", "provider_id is required")
  end

  defp error(conn, {:invalid_credential_entry, credential_id}) do
    error(conn, 422, "invalid_value", "a stored credential entry is invalid; sign in again to replace it", [
      %{credential_id: credential_id}
    ])
  end

  defp error(conn, {:invalid_credential_payload, credential_id}) do
    error(conn, 422, "invalid_value", "a stored credential cannot be read; sign in again to replace it", [
      %{credential_id: credential_id}
    ])
  end

  defp error(conn, {:credential_decrypt_failed, credential_id, _reason}) do
    error(conn, 422, "invalid_value", "a stored credential cannot be decrypted; sign in again to replace it", [
      %{credential_id: credential_id}
    ])
  end

  # Known configuration reasons keep the established envelope but name the
  # rejected rule; anything unlisted logs as a server-side gap.
  defp error(conn, reason) do
    case config_reason_label(reason) do
      nil ->
        ConsoleErrors.unexpected(conn, "ai_gateway.provider_api.unexpected_error", reason)

      label ->
        error(conn, 422, "invalid_value", "AIGateway provider configuration is invalid: #{label}")
    end
  end

  defp upstream_label(nil, code), do: "#{code || "unknown error"}"
  defp upstream_label(status, nil), do: "HTTP #{status}"
  defp upstream_label(status, code), do: "HTTP #{status}, #{code}"

  defp transport_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_label(reason) when is_binary(reason), do: reason
  defp transport_label(_reason), do: "transport_error"

  @config_reason_labels %{
    unknown_ai_gateway_provider: "the provider kind is unknown",
    provider_disabled: "the provider is disabled",
    invalid_provider_id: "provider_id is invalid",
    invalid_auth_issuer: "the configured auth issuer is not a valid URL",
    provider_id_immutable: "provider_id cannot change after creation",
    invalid_credential_pool: "the credential pool is invalid",
    invalid_credential_pool_strategy: "the credential selection strategy is unknown",
    invalid_credential_entry: "a credential entry is invalid",
    invalid_credential_update: "the credential update is invalid",
    invalid_credential_disabled_at: "disabled_at is not a valid timestamp",
    duplicate_credential_id: "a credential with this id already exists",
    credential_id_immutable: "a credential id cannot change",
    credential_field_removed: "a stored credential field cannot be removed",
    credential_fields_required: "the credential is missing required fields",
    missing_base_url: "the provider has no base URL"
  }

  defp config_reason_label(reason) when is_atom(reason),
    do: Map.get(@config_reason_labels, reason)

  defp config_reason_label({:credential_entry_unknown_keys, keys}),
    do: "a credential entry carries unknown keys: #{Enum.join(keys, ", ")}"

  defp config_reason_label(_reason), do: nil

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
