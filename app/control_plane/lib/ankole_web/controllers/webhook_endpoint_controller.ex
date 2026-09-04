defmodule AnkoleWeb.WebhookEndpointController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for webhook endpoint inspection and cancellation.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.SignalsGateway.Webhooks
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointResponse

  @agent_parameters [agent_uid: [in: :path, type: :string, required: true]]

  tags(["Webhooks"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List webhook endpoints",
    parameters: [agent: [in: :query, type: :string, required: false]],
    responses: [
      ok: {"Webhook endpoints", "application/json", WebhookEndpointListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Cancel one webhook endpoint",
    parameters:
      @agent_parameters ++
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
    with :ok <- ConsolePolicy.authorize(conn, "webhooks", "read") do
      endpoints =
        params
        |> ConsoleParams.agent_filter_param()
        |> Webhooks.list_endpoints(nil, active_only: false)
        |> Enum.map(&Webhooks.console_projection/1)

      json(conn, %{webhook_endpoints: endpoints})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, webhook_resource(agent_uid), "delete"),
         {:ok, endpoint_id} <- uuid_param(params, :webhook_endpoint_id),
         {:ok, %{webhook_endpoint: endpoint}} <-
           Webhooks.cancel_endpoint(agent_uid, nil, endpoint_id) do
      json(conn, %{webhook_endpoint: Webhooks.console_projection(endpoint)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp agent_uid_param(params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid) do
      {:ok, String.downcase(agent_uid)}
    end
  end

  defp uuid_param(params, key) do
    with {:ok, value} <- ConsoleParams.text(params, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _reason -> {:error, {:invalid_uuid, key}}
    end
  end

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
