defmodule AnkoleWeb.PodStreamController do
  @moduledoc "The native SSE transport for a human's conversation."
  use AnkoleWeb, :controller

  def events(conn, %{"id" => id}) do
    with {:ok, detail} <- Ankole.Conversations.get(conn.assigns.authz_actor, id),
         {:ok, conn} <- AnkoleWeb.PodStream.open(conn, detail) do
      conn
    else
      {:error, reason} ->
        error = Ankole.Pod.APIError.public_error(reason)
        AnkoleWeb.ConsoleErrors.render(conn, error.status, error.code, error.message)
    end
  end
end
