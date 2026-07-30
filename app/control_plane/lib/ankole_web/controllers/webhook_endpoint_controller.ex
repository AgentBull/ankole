defmodule AnkoleWeb.WebhookEndpointController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for webhook endpoint inspection and cancellation.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SignalsGateway.Webhooks
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointResponse

  @actor_parameters [
    agent_uid: [in: :path, type: :string, required: true],
    session_id: [in: :path, type: :string, required: true]
  ]

  tags(["Webhooks"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List webhook endpoints for one agent session",
    parameters: @actor_parameters,
    responses: [
      ok: {"Webhook endpoints", "application/json", WebhookEndpointListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Cancel one webhook endpoint",
    parameters:
      @actor_parameters ++
        [
          webhook_endpoint_id: [
            in: :path,
            schema: %OpenAPISpex.Schema{type: :string, format: :uuid},
            required: true
          ]
        ],
    responses: [
      ok: {"Webhook endpoint", "application/json", WebhookEndpointResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, webhook_resource(actor.agent_uid), "read") do
      endpoints =
        actor.agent_uid
        |> Webhooks.list_endpoints(actor.session_id, active_only: false)
        |> Enum.map(&Webhooks.console_projection/1)

      json(conn, %{webhook_endpoints: endpoints})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, webhook_resource(actor.agent_uid), "delete"),
         {:ok, endpoint_id} <- uuid_param(params, "webhook_endpoint_id"),
         {:ok, %{webhook_endpoint: endpoint}} <-
           Webhooks.cancel_endpoint(actor.agent_uid, actor.session_id, endpoint_id) do
      json(conn, %{webhook_endpoint: Webhooks.console_projection(endpoint)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp actor_params(params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, session_id} <- text_param(params, "session_id") do
      {:ok, %{agent_uid: String.downcase(agent_uid), session_id: session_id}}
    end
  end

  defp uuid_param(params, key) do
    with {:ok, value} <- text_param(params, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _reason -> {:error, {:invalid_uuid, key}}
    end
  end

  defp text_param(params, key) do
    value = Map.get(params, key) || Map.get(params, param_atom(key))

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp param_atom("agent_uid"), do: :agent_uid
  defp param_atom("session_id"), do: :session_id
  defp param_atom("webhook_endpoint_id"), do: :webhook_endpoint_id

  defp webhook_resource(agent_uid), do: "agent:#{agent_uid}:webhooks"

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :webhook_endpoint_not_found),
    do: error(conn, 404, "not_found", "webhook endpoint was not found")

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, {:invalid_uuid, key}) do
    error(conn, 422, "validation_failed", "#{key} must be a UUID")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_webhook_endpoint", "webhook endpoint request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
