defmodule AnkoleWeb.CloudEventController do
  @moduledoc "Capability-authenticated structured JSON CloudEvents ingress."
  use AnkoleWeb, :controller

  alias Ankole.Signals.Webhooks
  alias AnkoleWeb.Plugs.WebhookCallbackBodyReader

  def create(conn, %{"token" => token}) do
    with [content_type | _] <- get_req_header(conn, "content-type"),
         "application/cloudevents+json" <-
           content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase(),
         {:ok, event} <- decode(WebhookCallbackBodyReader.body(conn)),
         {:ok, result} <- Webhooks.receive_cloudevent(token, event) do
      conn
      |> put_status(202)
      |> json(%{
        status: result.status,
        signal_ids: Enum.map(Map.get(result, :signals, []), & &1.id)
      })
    else
      {:error, :webhook_endpoint_not_found} -> send_resp(conn, 404, "")
      {:error, :invalid_json} -> error(conn, 400, "invalid_json")
      {:error, reason} -> error(conn, 422, reason)
      _ -> error(conn, 415, "structured_cloudevents_json_required")
    end
  end

  defp decode(body) do
    case Ankole.JSON.decode(body) do
      {:ok, event} -> {:ok, event}
      _ -> {:error, :invalid_json}
    end
  end

  defp error(conn, status, reason) do
    code = if is_atom(reason) or is_binary(reason), do: to_string(reason), else: "routing_failed"
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
