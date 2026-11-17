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
    auth_ref =
      case AnkoleWeb.Session.authentication_reference(conn) do
        %{} = ref -> Ankole.BrowserSessions.encode_reference(ref)
        _ -> nil
      end

    oidc_session_id =
      case conn.assigns[:oidc_session] do
        %Ankole.OIDC.Session{id: sid} -> sid
        _ -> nil
      end

    with {:ok, revision} <- revision(conn),
         {:ok, idempotency_key} <-
           Applets.Idempotency.parse_header(get_req_header(conn, "idempotency-key")),
         {:ok, request} <- route_request(conn) do
      run = fn conn ->
        with {:ok, task} <-
               Applets.start(conn.assigns.authz_actor, id, request,
                 revision: revision,
                 authentication_ref: auth_ref,
                 oidc_session_id: oidc_session_id
               ) do
          AnkoleWeb.AppletRequest.await(conn, task)
        else
          error -> {conn, error}
        end
      end

      timeout_ms =
        case Ankole.Pod.Config.applet_limits() do
          {:ok, limits} -> Keyword.get(limits, :timeout_ms)
          _ -> nil
        end

      {conn, result} =
        Applets.Idempotency.execute_conn_route(
          conn,
          conn.assigns.authz_actor,
          id,
          request,
          idempotency_key,
          run,
          timeout_ms: timeout_ms
        )

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
    end
  end

  defp revision(conn) do
    with [value] <- get_req_header(conn, "x-ankole-applet-revision"),
         {:ok, revision} <- Applets.Revisions.parse_ref(value),
         do: {:ok, revision},
         else: (_ -> {:error, :invalid_request})
  end

  @doc false
  def route_request(conn) do
    with {:ok, body} <- conn.private[:applet_route_body] || {:ok, :absent},
         {:ok, query} <- decode_query(conn.query_string),
         [_, path] <- String.split(conn.request_path, "/routes", parts: 2) do
      request = %{
        "method" => conn.method,
        "path" => if(path == "", do: "/", else: path),
        "query" => query
      }

      {:ok, if(body == :absent, do: request, else: Map.put(request, "body", body))}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp decode_query(query_string) do
    query =
      URI.query_decoder(query_string)
      |> Enum.reduce(%{}, fn {key, value}, result ->
        Map.update(result, key, value, fn previous -> List.wrap(previous) ++ [value] end)
      end)

    {:ok, query}
  rescue
    ArgumentError -> {:error, :invalid_request}
  end
end
