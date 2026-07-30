defmodule AnkoleWeb.WebhookCallbackController do
  @moduledoc """
  Capability URL ingress for external task receipts.
  """

  use AnkoleWeb, :controller

  alias Ankole.SignalsGateway.Webhooks
  alias AnkoleWeb.Plugs.WebhookCallbackBodyReader

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, %{"token" => token}) do
    case Webhooks.receive(
           token,
           conn.req_headers,
           WebhookCallbackBodyReader.body(conn)
         ) do
      {:ok, %{status: status}} when status in [:accepted, :ignored] ->
        send_resp(conn, 204, "")

      {:error, :webhook_endpoint_not_found} ->
        send_resp(conn, 404, "")

      {:error, _reason} ->
        send_resp(conn, 500, "")
    end
  end
end
