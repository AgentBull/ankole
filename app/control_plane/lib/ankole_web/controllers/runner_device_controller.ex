defmodule AnkoleWeb.RunnerDeviceController do
  @moduledoc "The device daemon's enrollment and launch configuration endpoints."

  use AnkoleWeb, :controller

  alias Ankole.AgentWorkers

  def pair(conn, %{"code" => code}) do
    with true <- site?(conn),
         {:ok, result} <- AgentWorkers.pair_runner_device(code) do
      conn |> put_resp_header("cache-control", "no-store") |> json(result)
    else
      _ -> unauthorized(conn)
    end
  end

  def pair(conn, _), do: unauthorized(conn)

  def bindings(conn, _) do
    with true <- site?(conn),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, bindings} <-
           AgentWorkers.bootstrap_runner_device(token, AnkoleWeb.PodURL.site_origin(conn)) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{bindings: bindings})
    else
      {:error, :worker_runtime_not_configured} ->
        conn |> put_status(503) |> json(%{error: %{code: "worker_runtime_not_configured"}})

      _ ->
        unauthorized(conn)
    end
  end

  defp site?(conn),
    do: AnkoleWeb.Plugs.RequestHost.worker_allowed?(URI.parse(Plug.Conn.request_url(conn)))

  defp unauthorized(conn),
    do: conn |> put_status(401) |> json(%{error: %{code: "invalid_runner_credential"}})
end
