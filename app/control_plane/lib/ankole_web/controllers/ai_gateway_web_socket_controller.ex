defmodule AnkoleWeb.AIGatewayWebSocketController do
  @moduledoc """
  Raw WebSocket upgrade endpoint for AIGateway Responses.
  """

  use AnkoleWeb, :controller

  alias Ankole.Sessions.CodexModelBinding
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.UniversalAIRequest

  def responses(conn, _params) do
    with :ok <- WebSockAdapter.UpgradeValidation.validate_upgrade(conn),
         {:ok, binding} <- codex_model_binding(conn) do
      socket_state =
        %{
          subject_uid: conn.assigns.current_ai_gateway_subject_uid,
          tenant_id: Ankole.Repo.tenant_id!(),
          subject_type: conn.assigns.current_ai_gateway_subject_type,
          oidc_grant: conn.assigns[:oidc_grant],
          runner_claims: runner_claims(conn.assigns[:ai_gateway_token_claims]),
          request_context:
            CodexModelBinding.request_context(
              binding,
              RequestContext.from_headers(conn.req_headers, "websocket")
            )
        }
        |> maybe_put_model_binding(binding)

      conn
      |> maybe_select_application_protocol()
      |> WebSockAdapter.upgrade(
        AnkoleWeb.AIGatewayResponsesSocket,
        socket_state,
        # The idle timeout counts only client frames, and Codex sends none
        # while it waits for a response. It therefore limits one complete
        # response and must not end it before the upstream model budget.
        timeout: UniversalAIRequest.model_request_timeout_ms(),
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

  defp runner_claims(%{"runner_worker" => _} = claims),
    do: Map.take(claims, ["exp", "sub", "runner_worker"])

  defp runner_claims(_claims), do: nil

  defp codex_model_binding(conn) do
    CodexModelBinding.from_headers(
      get_req_header(conn, CodexModelBinding.header_name()),
      conn.assigns[:ai_gateway_token_claims]
    )
  end

  defp maybe_put_model_binding(state, nil), do: state
  defp maybe_put_model_binding(state, binding), do: Map.put(state, :codex_model_binding, binding)

  defp maybe_select_application_protocol(conn) do
    case conn.assigns[:ai_gateway_websocket_protocol] do
      protocol when is_binary(protocol) ->
        put_resp_header(conn, "sec-websocket-protocol", protocol)

      _missing ->
        conn
    end
  end
end
