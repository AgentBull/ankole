defmodule AnkoleWeb.AIGatewayProviderController do
  @moduledoc """
  Console REST API for operator-managed AIGateway providers and agent model profiles.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.AIGatewayProviderKindListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AIGatewayProviderListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AIGatewayProviderResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AIGatewayProviderWriteRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfileResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfileWriteRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfilesResponse

  tags(["AIGateway"])
  security([%{"consoleBearer" => []}])

  plug(OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer
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

  operation(:index_model_profiles,
    summary: "Read all model profiles for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Model profiles", "application/json", ModelProfilesResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_model_profile,
    summary: "Create or update one model profile for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      profile: [in: :path, type: :string, required: true]
    ],
    request_body: {"Model profile", "application/json", ModelProfileWriteRequest, required: true},
    responses: [
      ok: {"Model profile", "application/json", ModelProfileResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid model profile", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_model_profile,
    summary: "Clear one optional model profile for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      profile: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Model profile", "application/json", ModelProfileResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Profile cannot be cleared", "application/json", ErrorEnvelope}
    ]
  )

  def provider_kinds(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider_kinds", "read") do
      json(conn, %{data: ProviderConfigs.list_provider_kinds()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_providers", "read") do
      json(conn, %{data: ProviderConfigs.list_providers()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "update"),
         {:ok, attrs} <- provider_attrs(provider_id, conn.body_params),
         {:ok, provider} <- put_provider_row(provider_id, attrs) do
      json(conn, %{data: ProviderConfigs.projection(provider)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete_provider(conn, params) do
    with {:ok, provider_id} <- provider_id_param(params),
         :ok <- ConsolePolicy.authorize(conn, "ai_gateway_provider:#{provider_id}", "delete"),
         {:ok, provider} <- ProviderConfigs.delete_provider(provider_id) do
      json(conn, %{data: ProviderConfigs.projection(provider)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_model_profiles(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "read"),
         {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      json(conn, %{data: profiles})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_model_profile(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, profile} <- text_param(params, "profile"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "update"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, conn.body_params) do
      json(conn, %{data: model_profile_payload(profile, profile_attrs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Clearing an optional model profile is modeled as writing `nil` through the
  # same put path, so the rules for which profiles may be cleared live in one
  # place (ModelProfiles) instead of being duplicated here.
  def delete_model_profile(conn, params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, profile} <- text_param(params, "profile"),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "delete"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, nil) do
      json(conn, %{data: model_profile_payload(profile, profile_attrs)})
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

  defp text_param(params, key) do
    with {:ok, value} <- fetch_param(params, key) do
      normalize_text(value)
    end
  end

  # Console params arrive with string keys from the raw request body, but with
  # atom keys once OpenApiSpex has cast the declared path parameters, so both
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
  defp param_atom("agent_uid"), do: :agent_uid
  defp param_atom("profile"), do: :profile

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

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank_id}
      value -> {:ok, value}
    end
  end

  defp normalize_text(_value), do: {:error, :blank_id}

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp model_profile_payload(profile, nil) do
    %{"profile" => profile, "configured" => false}
  end

  defp model_profile_payload(profile, attrs) when is_map(attrs) do
    attrs
    |> normalize_external_attrs()
    |> Map.put("profile", profile)
    |> Map.put("configured", true)
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
      changeset_details(changeset)
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

  defp changeset_details(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_changeset_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{path: to_string(field), message: &1})
    end)
  end

  defp format_changeset_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", to_string(value))
    end)
  end

  defp error(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
