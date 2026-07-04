defmodule AnkoleWeb.AgentController do
  @moduledoc """
  Console REST API for operator-managed agent principals.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.AgentCreateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.AgentListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AgentResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AgentUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope

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
      changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_agent", "agent configuration is invalid", [
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
