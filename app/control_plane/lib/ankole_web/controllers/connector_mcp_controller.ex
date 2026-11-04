defmodule AnkoleWeb.ConnectorMCPController do
  use AnkoleWeb, :controller
  alias Ankole.Connectors.{Access, Gateway, Tokens}

  def toolkit(conn, %{"toolkit" => toolkit}), do: dispatch(conn, {:toolkit, toolkit})

  def skill(conn, %{"skill" => skill, "server" => server}),
    do: dispatch(conn, {:skill, skill, server})

  def git_credentials(conn, params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{"kind" => "worker"} = claims} <- Tokens.verify(token) do
      Ankole.Repo.with_tenant(claims["tenant_id"], fn ->
        with {:ok, context} <- Access.authorize(claims),
             {:ok, credentials} <- Ankole.Connectors.GitCredentials.resolve(context, params),
             do: conn |> put_resp_header("cache-control", "no-store") |> json(credentials),
             else: ({:error, reason} -> conn |> put_status(403) |> json(%{error: error(reason)}))
      end)
    else
      _ -> conn |> put_status(401) |> json(%{error: %{code: "unauthorized"}})
    end
  end

  defp request_context(method, _claims) when method in ["server/discover", "initialize", "ping"],
    do: {:ok, %{}}

  defp request_context(_method, claims), do: Access.authorize(claims)

  defp dispatch(conn, target) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Tokens.verify(token) do
      Ankole.Repo.with_tenant(claims["tenant_id"], fn ->
        with {:ok, context} <- request_context(conn.body_params["method"], claims),
             do:
               respond(
                 conn,
                 Gateway.request(target, conn.body_params, context, conn.query_params)
               ),
             else: ({:error, reason} ->
                      respond(conn, {:error, Map.put(error(reason), :request_sent, false)}))
      end)
    else
      _ -> conn |> put_status(401) |> json(%{error: %{code: "unauthorized"}})
    end
  end

  defp respond(conn, :accepted), do: send_resp(conn, 202, "")

  defp respond(%{body_params: %{"method" => method} = params} = conn, _)
       when is_binary(method) and not is_map_key(params, "id"),
       do: send_resp(conn, 202, "")

  defp respond(conn, {:ok, result}) do
    result = Map.put(result, "resultType", "complete")
    json(conn, %{jsonrpc: "2.0", id: conn.body_params["id"], result: result})
  end

  defp respond(conn, {:error, reason}) do
    error = error(reason)

    if conn.body_params["method"] == "tools/call" do
      respond(
        conn,
        {:ok,
         %{
           isError: true,
           structuredContent: %{error: error},
           content: [%{type: "text", text: Torque.encode!(error)}]
         }}
      )
    else
      json(conn, %{
        jsonrpc: "2.0",
        id: conn.body_params["id"],
        error: %{code: -32603, message: error.message, data: error}
      })
    end
  end

  defp error(%{code: code} = error),
    do: error |> Map.put(:code, to_string(code)) |> Map.put_new(:message, to_string(code))

  defp error(reason) when is_atom(reason),
    do: %{code: Atom.to_string(reason), message: Atom.to_string(reason), retryable: false}

  defp error({:mcp_protocol, status, _}),
    do: %{
      code: "upstream_mcp_error",
      message: "Upstream MCP request failed",
      status: status,
      retryable: status in [429, 502, 503, 504]
    }

  defp error(reason) when is_binary(reason),
    do: %{code: "invalid_request", message: reason, retryable: false}

  defp error(_),
    do: %{code: "connector_call_failed", message: "Connector call failed", retryable: false}
end
