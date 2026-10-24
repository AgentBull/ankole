defmodule AnkoleWeb.PodAPI do
  @moduledoc "HTTP helpers for exercising the browser's Ash JSON:API contract."
  import Plug.Conn

  for method <- [:get, :post, :put, :patch, :delete] do
    def unquote(:"api_#{method}")(conn, path, params \\ nil) do
      request(conn, unquote(method), path, params)
    end
  end

  def request(conn, method, path, params) do
    body =
      cond do
        method in [:get, :delete] -> params
        is_binary(params) -> params
        true -> Ankole.JSON.encode!(%{data: params || %{}})
      end

    conn
    |> Phoenix.ConnTest.ensure_recycled()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> Phoenix.ConnTest.dispatch(AnkoleWeb.Endpoint, method, path, body)
  end

  def api_error(conn, status), do: api_response(conn, status) |> Map.fetch!("errors") |> hd()

  # Generic POST actions return 201. Other successful action routes return 200.
  def api_response(conn, 200),
    do: Phoenix.ConnTest.json_response(conn, if(conn.method == "POST", do: 201, else: 200))

  def api_response(conn, status), do: Phoenix.ConnTest.json_response(conn, status)
end
