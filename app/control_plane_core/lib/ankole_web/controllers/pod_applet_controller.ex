defmodule AnkoleWeb.PodAppletController do
  @moduledoc "Caller-authorized JSON routes from a revision-pinned Applet publication."
  use AnkoleWeb, :controller
  alias Ankole.Pod.Applets
  alias AnkoleWeb.PodResponse

  def get(conn, params), do: invoke(conn, params)

  def post(conn, params), do: invoke(conn, params)

  def put(conn, params), do: invoke(conn, params)

  def patch(conn, params), do: invoke(conn, params)

  def delete(conn, params), do: invoke(conn, params)

  defp invoke(conn, %{"id" => id}) do
    with {:ok, revision} <- revision(conn),
         {:ok, request} <- request(conn),
         {:ok, task} <-
           Applets.start(conn.assigns.authz_actor, id, request, revision: revision) do
      {conn, result} = AnkoleWeb.AppletRequest.await(conn, task)

      case result do
        {:ok, %{"status" => 204}} -> send_resp(conn, 204, "")
        {:ok, outcome} -> conn |> put_status(outcome["status"]) |> json(outcome["body"])
        {:error, reason} -> PodResponse.error(conn, reason)
      end
    else
      {:error, :invalid_request} ->
        conn
        |> put_status(400)
        |> json(%{error: Ankole.Pod.Serialization.error(:invalid_request)})

      {:error, reason} ->
        PodResponse.error(conn, reason)
    end
  end

  defp revision(conn) do
    with [value] <- get_req_header(conn, "x-ankole-applet-revision"),
         {number, ""} when number >= 0 <- Integer.parse(value),
         do: {:ok, number},
         else: (_ -> {:error, :invalid_request})
  end

  defp request(conn) do
    with {:ok, body} <- conn.private[:applet_route_body] || {:ok, :absent} do
      query =
        URI.query_decoder(conn.query_string)
        |> Enum.reduce(%{}, fn {key, value}, result ->
          Map.update(result, key, value, fn previous -> List.wrap(previous) ++ [value] end)
        end)

      [_, path] = String.split(conn.request_path, "/routes", parts: 2)

      request = %{
        "method" => conn.method,
        "path" => if(path == "", do: "/", else: path),
        "query" => query
      }

      {:ok, if(body == :absent, do: request, else: Map.put(request, "body", body))}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end
end
