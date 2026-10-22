defmodule AnkoleWeb.WebhookEndpointController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for webhook endpoint inspection and cancellation.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Signals.Webhooks
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.CloudEventEndpointCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.CloudEventEndpointCreateResponse

  @agent_parameters [agent_uid: [in: :path, type: :string, required: true]]

  tags(["Webhooks"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List webhook endpoints",
    parameters: [agent: [in: :query, type: :string, required: false]],
    responses: [
      ok: {"Webhook endpoints", "application/json", WebhookEndpointListResponse},
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create one authenticated CloudEvents endpoint",
    request_body:
      {"CloudEvents endpoint", "application/json", CloudEventEndpointCreateRequest,
       required: true},
    responses: [
      created:
        {"Endpoint and one-time credential", "application/json", CloudEventEndpointCreateResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:cancel,
    summary: "Cancel one CloudEvents endpoint",
    parameters: [webhook_endpoint_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Webhook endpoint", "application/json", WebhookEndpointResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "webhooks", "update"),
         {:ok, label} <- ConsoleParams.text(conn.body_params, :label),
         {:ok, expires_at} <- expiry(conn.body_params),
         {:ok, result} <-
           Webhooks.create_endpoint(%{
             label: label,
             expires_at: expires_at,
             mode: "standing",
             event_format: "cloudevents",
             source_provenance: %{"kind" => "operator_api"}
           }) do
      conn
      |> put_status(201)
      |> json(%{
        webhook_endpoint: Webhooks.console_projection(result.webhook_endpoint),
        token: result.token
      })
    end
  end

  def cancel(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "webhooks", "delete"),
         {:ok, id} <- uuid_param(params, :webhook_endpoint_id),
         {:ok, %{webhook_endpoint: endpoint}} <- Webhooks.cancel_endpoint(nil, nil, id) do
      json(conn, %{webhook_endpoint: Webhooks.console_projection(endpoint)})
    end
  end

  defp expiry(%{expires_at: %DateTime{} = expires_at}), do: {:ok, expires_at}
  defp expiry(_params), do: {:error, :invalid_webhook_expiry}

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "webhooks", "read") do
      endpoints =
        params
        |> ConsoleParams.agent_filter_param()
        |> Webhooks.list_endpoints(nil, active_only: false)
        |> Enum.map(&Webhooks.console_projection/1)

      json(conn, %{webhook_endpoints: endpoints})
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, webhook_resource(agent_uid), "delete"),
         {:ok, endpoint_id} <- uuid_param(params, :webhook_endpoint_id),
         {:ok, %{webhook_endpoint: endpoint}} <-
           Webhooks.cancel_endpoint(agent_uid, nil, endpoint_id) do
      json(conn, %{webhook_endpoint: Webhooks.console_projection(endpoint)})
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

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :webhook_endpoint_not_found),
    do: ConsoleErrors.not_found(conn, "webhook endpoint was not found")

  defp error(conn, {:missing, key}) do
    ConsoleErrors.required_field(conn, key)
  end

  defp error(conn, {:invalid_uuid, key}) do
    ConsoleErrors.render(conn, 422, "validation_failed", "#{key} must be a UUID")
  end

  defp error(conn, %module{} = error) when module in [Ash.Changeset, Ash.Error.Invalid] do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_webhook_endpoint",
      "webhook endpoint request is invalid",
      Ankole.Ash.validation_details(error)
    )
  end

  defp error(conn, reason) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_webhook_endpoint",
      "webhook endpoint request is invalid",
      [
        %{reason: inspect(reason)}
      ]
    )
  end
end
