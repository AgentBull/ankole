defmodule AnkoleWeb.ConsoleErrors do
  @moduledoc """
  Renders the `%{error: %{code, message, details}}` JSON envelope for browser
  HTTP routes outside AshJsonApi.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  @doc "Renders a missing resource with its owning controller's message."
  def not_found(conn, message), do: render(conn, 404, "not_found", message)

  @doc """
  Renders the `%{error: %{code, message, details}}` envelope.
  """
  def render(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end

  @doc "Renders a missing required field."
  def required_field(conn, key),
    do: render(conn, 422, "validation_failed", "#{key} is required")

  @doc """
  Renders an unlisted error reason without leaking internal terms.

  An unlisted reason is a server-side gap: the error log carries the failure
  class for the operator, and the response stays generic. `log_event` names
  the owning API, for example `"files.agent_file_api.unexpected_error"`.
  A controller can keep its own code and message for the response.
  """
  def unexpected(
        conn,
        log_event,
        reason,
        code \\ "internal_error",
        message \\ "the request failed for an unexpected reason; check the server log"
      ) do
    Ankole.Logging.error(
      log_event,
      "console API request failed for an unhandled reason",
      Ankole.Logging.failure_fields(:error, reason, [])
    )

    render(conn, 500, code, message)
  end
end
