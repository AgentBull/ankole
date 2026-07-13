defmodule AnkoleWeb.SignalWebhookController do
  @moduledoc """
  Provider webhook front door for `signals_gateway.webhook_handler` plugins.

  The controller only routes: it resolves the declared handler, enforces the
  declared kind whitelist, and renders the handler's response instruction.
  Provider authentication and payload semantics belong to the handler module.
  Unknown handlers and undeclared kinds return 404 without echoing payloads.
  """

  use AnkoleWeb, :controller

  alias Ankole.Logging
  alias Ankole.SignalsGateway.WebhookHandlers

  def handle(conn, %{"handler_id" => handler_id, "instance_id" => instance_id, "kind" => kind}) do
    conn = Plug.Conn.fetch_query_params(conn)

    request = %{
      handler_id: handler_id,
      instance_id: instance_id,
      kind: kind,
      query_params: conn.query_params,
      body_params: normalized_body_params(conn),
      headers: request_headers(conn)
    }

    case WebhookHandlers.dispatch(request) do
      {:ok, response} ->
        render_response(conn, response)

      {:error, {:webhook_handler_not_found, _handler_id}} ->
        not_found(conn)

      {:error, {:webhook_kind_not_declared, _handler_id, _kind}} ->
        not_found(conn)

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.webhook.dispatch_failed",
          "provider webhook dispatch failed",
          %{handler_id: handler_id, kind: kind, reason: inspect(reason)}
        )

        conn
        |> put_status(500)
        |> json(%{"error" => "webhook dispatch failed"})
    end
  end

  defp render_response(conn, %{status: status} = response) do
    case Map.get(response, :body) do
      body when is_map(body) ->
        conn
        |> put_status(status)
        |> json(body)

      body when is_binary(body) ->
        conn
        |> put_resp_content_type(Map.get(response, :content_type) || "text/plain")
        |> send_resp(status, body)

      nil ->
        send_resp(conn, status, "")
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{"error" => "unknown webhook"})
  end

  # Bodies the JSON parser does not claim (e.g. Graph's text/plain validation
  # POST) leave body_params unfetched; handlers see an empty map instead.
  defp normalized_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp normalized_body_params(%Plug.Conn{body_params: body_params}), do: body_params

  defp request_headers(conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      Map.put_new(acc, name, value)
    end)
  end
end
