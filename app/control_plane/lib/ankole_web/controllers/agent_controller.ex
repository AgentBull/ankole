defmodule AnkoleWeb.AgentController do
  alias Ankole.Attrs
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed agent principals.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Principals
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfileResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfileWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfilesResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedWriteRequest

  tags(["Agents"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List agents, including disabled agents",
    responses: [
      ok: {"Agents", "application/json", AgentListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create one agent",
    request_body: {"Agent", "application/json", AgentCreateRequest, required: true},
    responses: [
      ok: {"Agent", "application/json", AgentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid agent", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", AgentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body: {"Agent", "application/json", AgentUpdateRequest, required: true},
    responses: [
      ok: {"Agent", "application/json", AgentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid agent", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Disable an active agent, or delete an agent that is already disabled",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", AgentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:enable,
    summary: "Re-enable one disabled agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", AgentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:index_model_profiles,
    summary: "Read all model profiles for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Model profiles", "application/json", ModelProfilesResponse},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_provider_hosted,
    summary: "Set which capabilities an agent leaves to its language-model provider",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Provider hosted capabilities", "application/json", ProviderHostedWriteRequest,
       required: true},
    responses: [
      ok: {"Provider hosted capabilities", "application/json", ProviderHostedResponse},
      unprocessable_entity: {"Invalid capability", "application/json", ErrorEnvelope}
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
      unprocessable_entity: {"Profile cannot be cleared", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agents", "read") do
      json(conn, %{agents: Enum.map(Principals.list_agents(), &agent_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agents", "update"),
         {:ok, attrs} <- create_attrs(conn.body_params, conn.assigns.current_principal_uid),
         {:ok, result} <- Principals.create_agent(attrs) do
      json(conn, %{agent: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "read"),
         {:ok, result} <- Principals.get_agent(agent_uid) do
      json(conn, %{agent: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "update"),
         {:ok, attrs} <- update_attrs(conn.body_params),
         {:ok, result} <- Principals.update_agent(agent_uid, attrs) do
      json(conn, %{agent: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "delete"),
         {:ok, %{agent: agent}} <- Principals.get_agent(agent_uid),
         {:ok, %Principal{} = principal} <- Principals.delete_agent(agent_uid) do
      json(conn, %{agent: agent_json(%{principal: principal, agent: agent})})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def enable(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "update"),
         {:ok, %{agent: agent}} <- Principals.get_agent(agent_uid),
         {:ok, %Principal{} = principal} <- Principals.enable_agent(agent_uid) do
      json(conn, %{agent: agent_json(%{principal: principal, agent: agent})})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_model_profiles(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "read"),
         {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      json(conn, %{
        model_profiles: profiles,
        provider_hosted: provider_hosted_payload(agent_uid)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_provider_hosted(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "update"),
         {:ok, capabilities} <-
           ModelProfiles.put_provider_hosted_capabilities(agent_uid, conn.body_params) do
      json(conn, %{provider_hosted: normalized_provider_hosted(capabilities)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp provider_hosted_payload(agent_uid) do
    case ModelProfiles.provider_hosted_capabilities(agent_uid) do
      {:ok, capabilities} -> normalized_provider_hosted(capabilities)
      {:error, _reason} -> normalized_provider_hosted(%{})
    end
  end

  # Always answer with every capability so a client never has to know the
  # default. An unset capability belongs to the Provider.
  defp normalized_provider_hosted(capabilities) do
    %{
      web_search: ModelProfiles.provider_hosted?(capabilities, "web_search"),
      image_generate: ModelProfiles.provider_hosted?(capabilities, "image_generate")
    }
  end

  def put_model_profile(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, profile} <- profile_param(params),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "update"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, conn.body_params) do
      json(conn, %{model_profile: model_profile_payload(profile, profile_attrs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete_model_profile(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, profile} <- profile_param(params),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "delete"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, nil) do
      json(conn, %{model_profile: model_profile_payload(profile, profile_attrs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp create_attrs(attrs, current_principal_uid) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, display_name} <- required_text(attrs, "display_name") do
      {:ok,
       attrs
       |> Map.put("display_name", display_name)
       |> Map.put("created_by_principal_uid", current_principal_uid)}
    end
  end

  defp create_attrs(_attrs, _current_principal_uid), do: {:error, :invalid_agent}

  defp update_attrs(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_external_attrs()
      |> Map.drop(["uid", "created_by_principal_uid"])

    normalize_optional_display_name(attrs)
  end

  defp update_attrs(_attrs), do: {:error, :invalid_agent}

  defp required_text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp normalize_optional_display_name(attrs) do
    if Map.has_key?(attrs, "display_name") do
      with {:ok, display_name} <- required_text(attrs, "display_name") do
        {:ok, Map.put(attrs, "display_name", display_name)}
      end
    else
      {:ok, attrs}
    end
  end

  defp agent_uid_param(params) do
    case Map.get(params, :agent_uid, Map.get(params, "agent_uid")) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, "agent_uid"}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, "agent_uid"}}
    end
  end

  defp profile_param(params) do
    case Map.get(params, :profile, Map.get(params, "profile")) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "profile"}}
    end
  end

  defp model_profile_payload(profile, nil), do: %{"profile" => profile, "configured" => false}

  defp model_profile_payload(profile, attrs) do
    attrs
    |> Attrs.normalize_external_attrs()
    |> Map.put("profile", profile)
    |> Map.put("configured", true)
  end

  defp agent_json(%{principal: %Principal{} = principal, agent: %Agent{} = agent}) do
    %{
      uid: principal.uid,
      status: Atom.to_string(principal.status),
      display_name: principal.display_name,
      avatar_url: principal.avatar_url,
      type: Atom.to_string(agent.type),
      role: agent.role,
      options: agent.options || %{},
      owner_principal_uid: agent.owner_principal_uid,
      group_memory_disclosure_mode: Atom.to_string(agent.group_memory_disclosure_mode),
      created_by_principal_uid: agent.created_by_principal_uid,
      inserted_at: DateTime.to_iso8601(agent.inserted_at),
      updated_at: DateTime.to_iso8601(agent.updated_at)
    }
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "agent was not found")
  defp error(conn, :not_agent), do: error(conn, 404, "not_found", "agent was not found")

  defp error(conn, :image_model_unavailable) do
    error(
      conn,
      422,
      "image_model_unavailable",
      "selected image model has no usable image-generation endpoint"
    )
  end

  defp error(conn, :image_model_catalog_unavailable) do
    error(
      conn,
      422,
      "image_model_catalog_unavailable",
      "image model availability could not be verified; try again later"
    )
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

  defp error(conn, reason) do
    error(conn, 422, "invalid_agent", "agent configuration is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
