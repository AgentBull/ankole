defmodule BullXWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness and readiness endpoints for operators.

  Liveness reports process availability; readiness returns service dependency
  checks and maps failure to HTTP 503 for probes.
  """

  use BullXWeb, :controller

  alias BullX.Health

  def livez(conn, _params) do
    json(conn, Health.live())
  end

  def readyz(conn, _params) do
    case Health.ready() do
      {:ok, report} ->
        json(conn, report)

      {:error, report} ->
        conn
        |> put_status(:service_unavailable)
        |> json(report)
    end
  end
end
