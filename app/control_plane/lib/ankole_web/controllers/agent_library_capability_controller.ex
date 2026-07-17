defmodule AnkoleWeb.AgentLibraryCapabilityController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for global defaults and sparse per-Agent capability overrides.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryCapabilitiesResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryAgentOverrideWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryGlobalDefaultWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  @standard_responses [
    ok: {"Agent Library capabilities", "application/json", AgentLibraryCapabilitiesResponse},
    unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
    forbidden: {"Forbidden", "application/json", ErrorEnvelope},
    not_found: {"Not found", "application/json", ErrorEnvelope},
    unprocessable_entity: {"Invalid capability", "application/json", ErrorEnvelope}
  ]

  tags(["Agent Library"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:global_index,
    summary: "Read global Agent Plugin and standalone Skill defaults",
    responses: @standard_responses
  )

  operation(:put_global_agent_plugin,
    summary: "Set one global Agent Plugin default",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Agent Plugin default", "application/json", AgentLibraryGlobalDefaultWriteRequest,
       required: true},
    responses: @standard_responses
  )

  operation(:put_global_skill,
    summary: "Set one global Skill default",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Skill default", "application/json", AgentLibraryGlobalDefaultWriteRequest, required: true},
    responses: @standard_responses
  )

  operation(:agent_index,
    summary: "Read resolved Agent Library capabilities for one Agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: @standard_responses
  )

  operation(:put_agent_plugin_override,
    summary: "Set or clear one Agent Plugin override",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Agent Plugin override", "application/json", AgentLibraryAgentOverrideWriteRequest,
       required: true},
    responses: @standard_responses
  )

  operation(:put_agent_skill_override,
    summary: "Set or clear one Agent Skill override",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Agent Skill override", "application/json", AgentLibraryAgentOverrideWriteRequest,
       required: true},
    responses: @standard_responses
  )

  def global_index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "agent_library", "read"),
         {:ok, capabilities} <- Library.global_capabilities() do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_global_agent_plugin(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "agent_library", "update"),
         {:ok, id} <- path_text(params, :id),
         {:ok, enabled} <- body_enabled(conn.body_params, false),
         {:ok, _value} <- AgentPlugins.set_global_default(id, enabled),
         {:ok, capabilities} <- Library.global_capabilities() do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_global_skill(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "agent_library", "update"),
         {:ok, id} <- path_text(params, :id),
         {:ok, enabled} <- body_enabled(conn.body_params, false),
         {:ok, _value} <- Library.set_global_skill_default(id, enabled),
         {:ok, capabilities} <- Library.global_capabilities() do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def agent_index(conn, params) do
    with {:ok, agent_uid} <- path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read"),
         {:ok, capabilities} <- Library.capabilities_for_agent(agent_uid) do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_agent_plugin_override(conn, params) do
    with {:ok, agent_uid} <- path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, id} <- path_text(params, :id),
         {:ok, enabled} <- body_enabled(conn.body_params, true),
         {:ok, _override} <- AgentPlugins.set_agent_override(agent_uid, id, enabled),
         {:ok, capabilities} <- Library.capabilities_for_agent(agent_uid) do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_agent_skill_override(conn, params) do
    with {:ok, agent_uid} <- path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, id} <- path_text(params, :id),
         {:ok, enabled} <- body_enabled(conn.body_params, true),
         {:ok, _skill} <- Library.set_agent_skill_override(agent_uid, id, enabled),
         {:ok, capabilities} <- Library.capabilities_for_agent(agent_uid) do
      json(conn, capabilities)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp path_text(params, key) do
    case Map.get(params, key, Map.get(params, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_capability_id}
    end
  end

  defp body_enabled(params, nullable?) when is_map(params) do
    value = Map.get(params, :enabled, Map.get(params, "enabled", :missing))

    cond do
      is_boolean(value) -> {:ok, value}
      nullable? and is_nil(value) -> {:ok, nil}
      true -> {:error, :invalid_enabled}
    end
  end

  defp body_enabled(_params, _nullable?), do: {:error, :invalid_enabled}

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: ConsoleErrors.render(conn, 404, "not_found", "agent was not found")

  defp error(conn, reason)
       when reason in [:agent_plugin_not_found, :skill_not_found] do
    ConsoleErrors.render(conn, 404, "not_found", "Agent Library capability was not found")
  end

  defp error(conn, reason) do
    ConsoleErrors.render(conn, 422, "validation_failed", "Agent Library capability is invalid", [
      %{reason: inspect(reason)}
    ])
  end
end
