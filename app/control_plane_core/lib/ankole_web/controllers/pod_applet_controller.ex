defmodule AnkoleWeb.PodAppletController do
  @moduledoc "Caller-authorized JSON routes from a revision-pinned Applet publication."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias Ankole.Pod.Applets
  alias AnkoleWeb.PodResponse
  alias AnkoleWeb.Schemas.PodDatabase.Value
  alias AnkoleWeb.Schemas.PodContent.ErrorEnvelope

  tags(["Pod content"])

  @route_parameters [
    id: [in: :path, type: :string, required: true],
    path: [in: :path, type: :string, required: true],
    "x-ankole-applet-revision": [in: :header, type: :integer, required: true]
  ]
  @route_responses %{
    200 => {"JSON result", "application/json", Value},
    204 => {"No content", "application/json", Value},
    400 => {"Error", "application/json", ErrorEnvelope},
    401 => {"Error", "application/json", ErrorEnvelope},
    403 => {"Error", "application/json", ErrorEnvelope},
    404 => {"Error", "application/json", ErrorEnvelope},
    405 => {"Error", "application/json", ErrorEnvelope},
    409 => {"Error", "application/json", ErrorEnvelope},
    422 => {"Error", "application/json", ErrorEnvelope},
    500 => {"Error", "application/json", ErrorEnvelope},
    502 => {"Error", "application/json", ErrorEnvelope},
    504 => {"Error", "application/json", ErrorEnvelope}
  }

  operation(:get,
    operation_id: "podAppletRouteGet",
    summary: "Invoke a published Applet route",
    parameters: @route_parameters,
    responses: @route_responses
  )

  def get(conn, params), do: invoke(conn, params)

  operation(:post,
    operation_id: "podAppletRoutePost",
    summary: "Invoke a published Applet route",
    parameters: @route_parameters,
    request_body: {"JSON request", "application/json", Value, required: false},
    responses: @route_responses
  )

  def post(conn, params), do: invoke(conn, params)

  operation(:put,
    operation_id: "podAppletRoutePut",
    summary: "Invoke a published Applet route",
    parameters: @route_parameters,
    request_body: {"JSON request", "application/json", Value, required: false},
    responses: @route_responses
  )

  def put(conn, params), do: invoke(conn, params)

  operation(:patch,
    operation_id: "podAppletRoutePatch",
    summary: "Invoke a published Applet route",
    parameters: @route_parameters,
    request_body: {"JSON request", "application/json", Value, required: false},
    responses: @route_responses
  )

  def patch(conn, params), do: invoke(conn, params)

  operation(:delete,
    operation_id: "podAppletRouteDelete",
    summary: "Invoke a published Applet route",
    parameters: @route_parameters,
    request_body: {"JSON request", "application/json", Value, required: false},
    responses: @route_responses
  )

  def delete(conn, params), do: invoke(conn, params)

  defp invoke(conn, %{"id" => id}) do
    with {:ok, revision} <- revision(conn),
         {:ok, request} <- request(conn),
         {:ok, task} <-
           Applets.start(conn.assigns.current_principal_uid, id, request, revision: revision) do
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
