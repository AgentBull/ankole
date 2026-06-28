defmodule AnkoleWeb.AIGatewayWebSocketController do
  @moduledoc """
  Raw WebSocket upgrade endpoint for AIGateway Responses.
  """

  use AnkoleWeb, :controller

  def responses(conn, _params) do
    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok ->
        conn
        |> WebSockAdapter.upgrade(
          AnkoleWeb.AIGatewayResponsesSocket,
          %{
            subject_uid: conn.assigns.current_ai_gateway_subject_uid,
            subject_type: conn.assigns.current_ai_gateway_subject_type
          },
          timeout: 300_000,
          compress: true,
          max_frame_size: 1_048_576,
          validate_utf8: true,
          early_validate_upgrade: false
        )
        |> halt()

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{
          error: %{
            code: "websocket_upgrade_required",
            message: reason
          }
        })
    end
  end
end
