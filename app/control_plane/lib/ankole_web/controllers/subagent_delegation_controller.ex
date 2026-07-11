defmodule AnkoleWeb.SubagentDelegationController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Installation-wide console API for observing and cancelling subagent work.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.SubagentDelegationListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.SubagentDelegationResponse
  alias OpenAPISpex.Schema

  @statuses Delegation.statuses()

  tags(["Subagent Delegations"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List subagent delegations",
    parameters: [
      status: [in: :query, schema: %Schema{type: :string, enum: @statuses}, required: false],
      agent: [in: :query, type: :string, required: false],
      cursor: [in: :query, type: :string, required: false],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ]
    ],
    responses: [
      ok: {"Delegations", "application/json", SubagentDelegationListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one subagent delegation and its event timeline",
    parameters: [delegation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Delegation", "application/json", SubagentDelegationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:cancel,
    summary: "Cancel one queued or active subagent delegation",
    parameters: [delegation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Delegation", "application/json", SubagentDelegationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "subagent_delegations", "read"),
         {:ok, page} <-
           SubagentDelegations.list_for_console(
             status: param(params, "status"),
             agent_uid: param(params, "agent"),
             cursor: param(params, "cursor"),
             limit: integer_param(params, "limit", 50)
           ) do
      json(conn, %{
        delegations: Enum.map(page.delegations, &SubagentDelegations.console_projection/1),
        next_cursor: page.next_cursor
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "subagent_delegations", "read"),
         %Delegation{} = delegation <- delegation(params) do
      json(conn, %{delegation: detail_projection(delegation)})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  def cancel(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "subagent_delegations", "delete"),
         %Delegation{} = delegation <- delegation(params),
         {:ok, %{delegation: cancelled}} <-
           SubagentDelegations.request_stop(delegation.id, %{
             "agent_uid" => delegation.agent_uid,
             "cancel_requested_by" => "operator:#{conn.assigns.current_principal_uid}",
             "reason" => "Cancelled from the operator console"
           }) do
      json(conn, %{delegation: detail_projection(cancelled)})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp delegation(params) do
    params
    |> param("delegation_id")
    |> case do
      id when is_binary(id) -> SubagentDelegations.get_delegation(id)
      _value -> nil
    end
  end

  defp detail_projection(delegation) do
    delegation
    |> SubagentDelegations.console_projection()
    |> Map.put(
      :events,
      delegation.id
      |> SubagentDelegations.list_events()
      |> Enum.map(&SubagentDelegations.console_event_projection/1)
    )
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, param_atom(key))

  defp param_atom("status"), do: :status
  defp param_atom("agent"), do: :agent
  defp param_atom("cursor"), do: :cursor
  defp param_atom("limit"), do: :limit
  defp param_atom("delegation_id"), do: :delegation_id

  defp integer_param(params, key, default) do
    case param(params, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _value -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> default
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "delegation was not found")

  defp error(conn, reason) do
    error(conn, 422, "invalid_delegation_request", "delegation request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
