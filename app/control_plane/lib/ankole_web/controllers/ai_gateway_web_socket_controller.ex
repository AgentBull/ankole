defmodule AnkoleWeb.AIGatewayWebSocketController do
  @moduledoc """
  Raw WebSocket upgrade endpoint for AIGateway Responses.
  """

  use AnkoleWeb, :controller

  alias Ankole.AIGateway.CodexModelBinding

  def responses(conn, _params) do
    with :ok <- WebSockAdapter.UpgradeValidation.validate_upgrade(conn),
         {:ok, binding} <- codex_model_binding(conn) do
      socket_state =
        %{
          subject_uid: conn.assigns.current_ai_gateway_subject_uid,
          subject_type: conn.assigns.current_ai_gateway_subject_type
        }
        |> maybe_put_model_binding(binding)

      conn
      |> WebSockAdapter.upgrade(
        AnkoleWeb.AIGatewayResponsesSocket,
        socket_state,
        timeout: 300_000,
        compress: true,
        max_frame_size: 128 * 1024 * 1024,
        validate_utf8: true,
        early_validate_upgrade: false
      )
      |> halt()
    else
      {:error, :invalid_codex_model_binding} ->
        conn
        |> put_status(400)
        |> json(%{
          error: %{
            code: "invalid_codex_model_binding",
            message: "Codex model binding is invalid"
          }
        })

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

  defp codex_model_binding(conn) do
    case get_req_header(conn, CodexModelBinding.header_name()) do
      [] -> {:ok, nil}
      [encoded] -> CodexModelBinding.decode(encoded)
      _values -> {:error, :invalid_codex_model_binding}
    end
  end

  defp maybe_put_model_binding(state, nil), do: state
  defp maybe_put_model_binding(state, binding), do: Map.put(state, :codex_model_binding, binding)
end
