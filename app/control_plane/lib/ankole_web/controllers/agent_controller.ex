defmodule AnkoleWeb.AgentController do
  @moduledoc """
  Console REST API for operator-managed agent principals.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.Principals
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.AgentCreateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.AgentListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AgentResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AgentUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfileResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfileWriteRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ModelProfilesResponse

  tags(["Agents"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  operation(:index,
    summary: "List active agents",
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
    summary: "Disable one agent",
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
      json(conn, %{data: Enum.map(Principals.list_active_agents(), &agent_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agents", "update"),
         {:ok, attrs} <- create_attrs(conn.body_params, conn.assigns.current_principal_uid),
         {:ok, result} <- Principals.create_agent(attrs) do
      json(conn, %{data: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "read"),
         {:ok, result} <- Principals.get_agent(agent_uid) do
      json(conn, %{data: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "update"),
         {:ok, attrs} <- update_attrs(conn.body_params),
         {:ok, result} <- Principals.update_agent(agent_uid, attrs) do
      json(conn, %{data: agent_json(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}", "delete"),
         {:ok, %{agent: agent}} <- Principals.get_agent(agent_uid),
         {:ok, %Principal{} = principal} <- Principals.disable_principal(agent_uid) do
      json(conn, %{data: agent_json(%{principal: principal, agent: agent})})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_model_profiles(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "read"),
         {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      json(conn, %{data: profiles})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_model_profile(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         {:ok, profile} <- profile_param(params),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "update"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, conn.body_params) do
      json(conn, %{data: model_profile_payload(profile, profile_attrs)})
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
      json(conn, %{data: model_profile_payload(profile, profile_attrs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp create_attrs(attrs, current_principal_uid) when is_map(attrs) do
    {:ok,
     attrs
     |> normalize_external_attrs()
     |> Map.put("created_by_principal_uid", current_principal_uid)}
  end

  defp create_attrs(_attrs, _current_principal_uid), do: {:error, :invalid_agent}

  defp update_attrs(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_external_attrs()
      |> Map.drop(["uid", "created_by_principal_uid"])

    {:ok, attrs}
  end

  defp update_attrs(_attrs), do: {:error, :invalid_agent}

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
    |> normalize_external_attrs()
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
      created_by_principal_uid: agent.created_by_principal_uid,
      inserted_at: DateTime.to_iso8601(agent.inserted_at),
      updated_at: DateTime.to_iso8601(agent.updated_at)
    }
  end

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "agent was not found")
  defp error(conn, :not_agent), do: error(conn, 404, "not_found", "agent was not found")

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
