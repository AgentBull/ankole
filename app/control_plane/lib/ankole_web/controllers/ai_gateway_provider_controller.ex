defmodule AnkoleWeb.AIGatewayProviderController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed AIGateway providers.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway.ProviderConfigs
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
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

  operation(:delete_provider,
    summary: "Disable one AIGateway provider",
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
    attrs = normalize_external_attrs(attrs)

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

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "resource was not found")
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

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "AIGateway provider configuration is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
